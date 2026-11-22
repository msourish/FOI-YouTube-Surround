import AVFoundation
import CoreAudio
import CoreMedia
import Darwin
import Foundation

private let deviceUID = "BlackHole16ch_UID"
private let startupTimeout = 45.0
private let fallbackTimeout = 180.0
private let heartbeatLimit = 7.0

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct Request: Decodable {
    var requestID: String?
    var op: String
    var session: String?
    var videoId: String?
    var time: Double?
    var playing: Bool?
    var rate: Double?
    var volume: Double?
    var muted: Bool?
    var armed: Bool?
}

private struct Candidate: Codable {
    var videoId: String?
    var url: String?
    var filesize: Int64?
    var codec: String?
    var formatId: String?
    var channels: Int?
    var userAgent: String?
    var error: String?
    var code: String?
}

private struct SourceFormat {
    let codec: String
    let sampleRate: Double
    let channels: Int
}

private func codecName(_ id: FourCharCode) -> String {
    String(bytes: [UInt8(truncatingIfNeeded: id >> 24), UInt8(truncatingIfNeeded: id >> 16),
                   UInt8(truncatingIfNeeded: id >> 8), UInt8(truncatingIfNeeded: id)], encoding: .ascii)?
        .trimmingCharacters(in: .whitespaces) ?? String(id)
}

private func hasSurroundLayout(_ format: CMFormatDescription) -> Bool {
    var size = 0
    guard let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size), size > 0 else { return false }
    var tag = layout.pointee.mChannelLayoutTag
    if tag == kAudioChannelLayoutTag_UseChannelBitmap || tag == kAudioChannelLayoutTag_UseChannelDescriptions {
        var bytes = UInt32(MemoryLayout<AudioChannelLayoutTag>.size)
        guard AudioFormatGetProperty(kAudioFormatProperty_TagForChannelLayout, UInt32(size), layout, &bytes, &tag) == noErr else { return false }
    }
    return [kAudioChannelLayoutTag_MPEG_5_1_A, kAudioChannelLayoutTag_MPEG_5_1_B,
            kAudioChannelLayoutTag_MPEG_5_1_C, kAudioChannelLayoutTag_MPEG_5_1_D,
            kAudioChannelLayoutTag_WAVE_5_1_B].contains(tag)
}

private func sourceFormat(_ asset: AVURLAsset) async throws -> SourceFormat {
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard tracks.count == 1, let track = tracks.first else {
        throw Failure("The selected stream does not contain one independent audio track.")
    }
    let formats = try await track.load(.formatDescriptions)
    guard !formats.isEmpty else { throw Failure("The source has no readable audio format.") }
    var result: SourceFormat?
    for format in formats {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mChannelsPerFrame == 6, asbd.mSampleRate > 0, hasSurroundLayout(format) else {
            throw Failure("The source did not declare an original 5.1 speaker layout.")
        }
        result = SourceFormat(codec: codecName(asbd.mFormatID), sampleRate: asbd.mSampleRate, channels: 6)
    }
    return result!
}

// Look up the named output, even when the system default points elsewhere.
// This code only reads Core Audio properties; the user's default and preferred
// speaker layout are shared with Music and Fairlight.
private func blackHoleAvailable() -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var uid: CFString = deviceUID as CFString
    var id = AudioDeviceID(kAudioObjectUnknown)
    var bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
    let translated = withUnsafePointer(to: &uid) { ptr in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<CFString>.size), ptr, &bytes, &id)
    }
    guard translated == noErr, id != kAudioObjectUnknown else { return false }
    address.mSelector = kAudioDevicePropertyDeviceIsAlive
    var alive: UInt32 = 0
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &alive) == noErr, alive != 0 else { return false }
    address.mSelector = kAudioDevicePropertyStreamConfiguration
    address.mScope = kAudioDevicePropertyScopeOutput
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
          size >= MemoryLayout<AudioBufferList>.size else { return false }
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { pointer.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return false }
    let list = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) } >= 6
}

private func mediaURL(_ text: String?) -> URL? {
    guard let text, let url = URL(string: text), url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(), host.hasSuffix(".googlevideo.com"),
          url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
    return url
}

@MainActor
private final class Worker {
    let resolver: URL
    private var player: AVPlayer?
    private var asset: AVURLAsset?
    private var fetch: Process?
    private var selectedSource: Candidate?
    private var probe: Task<Void, Never>?
    private var downloadFolder: URL?
    private var remoteProbeStarted: Double?
    private var generation = 0
    private var seekSerial = 0
    private var seekInFlight = false
    private var state = "stopped"
    private var message = ""
    private var session = ""
    private var videoID = ""
    private var audio: SourceFormat?
    private var latest: Request?
    private var anchorUptime = 0.0
    private var started = 0.0
    private var lastSeek = -20.0
    private var waitingSince: Double?
    private var nextDeviceCheck = 0.0
    private let timeNow = { ProcessInfo.processInfo.systemUptime }

    init(resolver: URL) { self.resolver = resolver }

    private func stopMedia() {
        generation += 1
        seekSerial += 1
        seekInFlight = false
        waitingSince = nil
        probe?.cancel()
        probe = nil
        if let fetch, fetch.isRunning { fetch.terminate() }
        fetch = nil
        player?.isMuted = true
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil)
        player = nil
        asset?.cancelLoading()
        asset = nil
        remoteProbeStarted = nil
        if let downloadFolder { try? FileManager.default.removeItem(at: downloadFolder) }
        downloadFolder = nil
        selectedSource = nil
        audio = nil
        lastSeek = -20.0
    }

    func stop(_ status: String = "stopped", _ reason: String = "") {
        stopMedia()
        state = status
        message = reason
    }

    private func begin(_ command: Request) {
        stopMedia()
        session = command.session ?? ""
        videoID = command.videoId ?? ""
        state = "loading"
        message = "Looking for an original 5.1 track."
        started = timeNow()
        guard blackHoleAvailable() else {
            stop("unavailable", "BlackHole 16ch is unavailable. Check the FOI monitor input.")
            return
        }
        runResolver([videoID]) { [weak self] success, source in
            guard let self else { return }
            guard success, var track = source, track.channels == 6, let url = mediaURL(track.url),
                  track.videoId == nil || track.videoId == self.videoID else {
                self.stop("unavailable", String((source?.error ?? "An original 5.1 track is unavailable.").prefix(240)))
                return
            }
            track.videoId = self.videoID
            self.selectedSource = track
            self.remoteProbeStarted = self.timeNow()
            self.open(url, userAgent: track.userAgent, ticket: self.generation)
        }
    }

    private func runResolver(_ arguments: [String], candidate: Candidate? = nil,
                             completion: @escaping @MainActor (Bool, Candidate?) -> Void) {
        let ticket = generation
        let process = Process()
        let output = Pipe()
        process.executableURL = resolver
        process.arguments = arguments
        let payload = candidate.flatMap { try? JSONEncoder().encode($0) }
        let stdin = payload.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin }
        else { process.standardInput = FileHandle.nullDevice }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            stop("error", "Could not start the YouTube audio reader.")
            return
        }
        fetch = process
        if let stdin, let payload {
            try? stdin.fileHandleForReading.close()
            DispatchQueue.global(qos: .userInitiated).async {
                let writer = stdin.fileHandleForWriting
                try? writer.write(contentsOf: payload)
                try? writer.close()
            }
        }
        let input = output.fileHandleForReading
        // Drain stdout while the process runs. Waiting first could deadlock
        // if a failing resolver wrote more than the pipe capacity.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let data = input.readDataToEndOfFile()
            process.waitUntilExit()
            let success = process.terminationStatus == 0
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == ticket else { return }
                self.fetch = nil
                let source = data.count < 131072 ? try? JSONDecoder().decode(Candidate.self, from: data) : nil
                completion(success, source)
            }
        }
    }

    private func openLocalCopy() {
        // The CDN can serve a valid audio stream but reject the byte-range
        // pattern requested by AVFoundation. Keep the original compressed file.
        let candidate = selectedSource
        stopMedia()
        let now = timeNow()
        started = now
        state = "loading"
        message = "Downloading the original 5.1 audio. YouTube is still playing."
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("foi-surround-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
        } catch {
            stop("error", "Could not create temporary storage for the surround track.")
            return
        }
        downloadFolder = folder
        let file = folder.appendingPathComponent("surround.m4a")
        runResolver([videoID, file.path], candidate: candidate) { [weak self] success, source in
            guard let self else { return }
            guard success, FileManager.default.isReadableFile(atPath: file.path) else {
                self.stop("unavailable", String((source?.error ?? "Could not download the original surround track.").prefix(240)))
                return
            }
            self.open(file, userAgent: nil, ticket: self.generation)
        }
    }

    private func open(_ url: URL, userAgent: String?, ticket: Int) {
        message = "Checking the six-channel stream."
        var options: [String: Any] = [:]
        if let userAgent, !userAgent.contains("\n"), !userAgent.contains("\r"), userAgent.count < 1024 {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        if #available(macOS 14.0, *), !url.isFileURL { options[AVURLAssetOverrideMIMETypeKey] = "audio/mp4" }
        let asset = AVURLAsset(url: url, options: options)
        self.asset = asset
        probe = Task { @MainActor [weak self] in
            do {
                let format = try await sourceFormat(asset)
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                self.audio = format
                let item = AVPlayerItem(asset: asset)
                // Preserve the authored channel layout on the physical 5.1 route.
                if #available(macOS 15.0, *) { item.allowedAudioSpatializationFormats = [] }
                else { item.isAudioSpatializationAllowed = false }
                item.audioTimePitchAlgorithm = .timeDomain
                item.preferredForwardBufferDuration = 2
                let player = AVPlayer()
                // Bind before inserting any playable item or raising its volume.
                player.audioOutputDeviceUniqueID = deviceUID
                player.isMuted = true
                player.automaticallyWaitsToMinimizeStalling = false
                player.allowsExternalPlayback = false
                player.replaceCurrentItem(with: item)
                self.player = player
                self.message = "Preparing BlackHole 16ch."
            } catch {
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                if !url.isFileURL { self.openLocalCopy() }
                else { self.stop("unavailable", "Could not verify six channels in the downloaded audio.") }
            }
        }
    }

    private func position(_ command: Request, now: Double) -> Double {
        let elapsed = command.playing == true ? max(0, now - anchorUptime) * (command.rate ?? 1) : 0
        return max(0, (command.time ?? 0) + elapsed)
    }

    private func seek(_ player: AVPlayer, to seconds: Double, now: Double) {
        seekSerial += 1
        let serial = seekSerial
        let ticket = generation
        lastSeek = now
        seekInFlight = true
        player.isMuted = true
        let tolerance = CMTime(seconds: 0.030, preferredTimescale: 48000)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 48000),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == ticket, self.seekSerial == serial else { return }
                self.seekInFlight = false
            }
        }
    }

    func tick() {
        guard let command = latest, ["loading","ready","playing","paused"].contains(state) else { return }
        let now = timeNow()
        if now - anchorUptime >= heartbeatLimit {
            stop("stopped", "The YouTube tab stopped sending playback updates.")
            return
        }
        if now >= nextDeviceCheck {
            nextDeviceCheck = now + 1
            guard blackHoleAvailable() else {
                stop("unavailable", "BlackHole 16ch disconnected.")
                return
            }
        }
        guard let player, let item = player.currentItem, audio != nil, item.status == .readyToPlay else {
            if player?.currentItem?.status == .failed || player?.status == .failed {
                if downloadFolder == nil { openLocalCopy() }
                else { stop("unavailable", "The original surround stream could not be played.") }
            } else if let remoteProbeStarted, now - remoteProbeStarted > 7 {
                openLocalCopy()
            } else if now - started > (downloadFolder == nil ? startupTimeout : fallbackTimeout) {
                stop("unavailable", "The surround stream timed out.")
            }
            return
        }
        let desired = position(command, now: now)
        let actual = player.currentTime().seconds
        let difference = actual.isFinite ? desired - actual : 0
        let error = actual.isFinite ? abs(difference) : Double.infinity
        let armed = command.armed == true
        let playing = command.playing == true
        let rate = Float(command.rate ?? 1)
        player.volume = Float(command.volume ?? 1)
        let muted = !armed || command.muted == true || player.volume == 0

        // Track the tab silently even during negotiation. This prevents an
        // initial two-player overlap and avoids a moving target while seeking.
        if !playing {
            player.pause()
            player.isMuted = true
            if error > 0.09, !seekInFlight, now - lastSeek > 0.20 { seek(player, to: desired, now: now) }
            state = seekInFlight ? "loading" : (armed ? "paused" : "ready")
            message = seekInFlight ? "Positioning the surround track." : ""
            waitingSince = nil
            return
        }
        if error > 0.22, !seekInFlight, now - lastSeek > 0.85 {
            seek(player, to: desired, now: now)
        }
        if !seekInFlight {
            // Small clock errors converge without repeated audible seek gaps.
            // Larger discontinuities (including user seeks) use the precise seek above.
            let adjustment = error > 0.040 && error <= 0.22 ? max(-0.035, min(0.035, difference * 0.32)) : 0
            let targetRate = rate * Float(1 + adjustment)
            if abs(player.rate - targetRate) > 0.004 { player.playImmediately(atRate: targetRate) }
            player.isMuted = muted
        }
        if player.timeControlStatus != .playing {
            if waitingSince == nil { waitingSince = now }
            if now - (waitingSince ?? now) > 6 {
                if downloadFolder == nil { openLocalCopy() }
                else { stop("unavailable", "The surround stream stalled. YouTube audio was restored.") }
                return
            }
        } else { waitingSince = nil }
        let advancing = !seekInFlight && player.timeControlStatus == .playing
        if advancing {
            state = armed ? "playing" : "ready"
            message = ""
        } else {
            state = armed ? "ready" : "loading"
            message = "Buffering the surround track."
        }
    }

    func handle(_ line: Data) {
        guard line.count <= 32768, let cmd = try? JSONDecoder().decode(Request.self, from: line) else {
            respond(id: nil, state: "error", reason: "Invalid playback command.")
            return
        }
        switch cmd.op {
        case "sync":
            guard let identifier = cmd.session, !identifier.isEmpty, identifier.utf8.count <= 160,
                  let video = cmd.videoId, video.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil,
                  let time = cmd.time, time.isFinite, time >= 0, time <= 1_000_000,
                  let rate = cmd.rate, rate.isFinite, (0.25...4.0).contains(rate),
                  let volume = cmd.volume, volume.isFinite, (0...1).contains(volume) else {
                if cmd.session == session { stop("error", "Unsupported playback settings.") }
                respond(id: cmd.requestID, state: "error", reason: "Unsupported playback settings.")
                return
            }
            let newRequest = session != identifier || videoID != video || state == "stopped"
            latest = cmd
            anchorUptime = timeNow()
            if newRequest { begin(cmd) }
            tick()
        case "stop":
            if cmd.session == nil || cmd.session == session {
                stop()
                latest = nil
            }
        case "status": break
        default:
            respond(id: cmd.requestID, state: "error", reason: "Unknown playback command.")
            return
        }
        respond(id: cmd.requestID, state: state, reason: message)
    }

    private func respond(id: String?, state: String, reason: String) {
        let pos = player?.currentTime().seconds ?? 0
        var data: [String: Any] = ["state":state, "time":pos.isFinite ? pos : 0, "session":session, "videoId":videoID]
        if let id { data["requestID"] = id }
        if !reason.isEmpty { data["message"] = reason }
        if let audio {
            data["channels"] = audio.channels
            data["codec"] = audio.codec
            data["sampleRate"] = audio.sampleRate
            data["deviceUID"] = deviceUID
        }
        if var encoded = try? JSONSerialization.data(withJSONObject: data) {
            encoded.append(10)
            try? FileHandle.standardOutput.write(contentsOf: encoded)
        }
    }
}

@main
private struct Main {
    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2 && arguments[0] == "--inspect" {
            do {
                let info = try await sourceFormat(AVURLAsset(url: URL(fileURLWithPath: arguments[1])))
                print("\(info.codec) \(info.channels) channels \(Int(info.sampleRate)) Hz")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let resolver: URL
        if arguments.count == 2, arguments[0] == "--resolver" {
            resolver = URL(fileURLWithPath: arguments[1])
        } else if arguments.isEmpty {
            resolver = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("resolve-audio")
        } else { fputs("Usage: FOIPlaybackWorker [--resolver /path/to/resolve-audio]\n", stderr); exit(2) }
        let worker = Worker(resolver: resolver)
        // When the host quits it both closes stdin and sends SIGTERM. Restore
        // temp space and terminate the extractor on either path. A caught
        // signal resets on exec, so child resolvers still receive termination.
        Darwin.signal(SIGPIPE, { _ in })
        let terminationSignals = [SIGTERM, SIGINT].map { number in
            Darwin.signal(number, { _ in })
            let signalSource = DispatchSource.makeSignalSource(signal: number, queue: .main)
            signalSource.setEventHandler { worker.stop(); exit(0) }
            signalSource.resume()
            return signalSource
        }
        defer { terminationSignals.forEach { $0.cancel() } }
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine(), let data = line.data(using: .utf8) {
                DispatchQueue.main.async { worker.handle(data) }
            }
            DispatchQueue.main.async { worker.stop(); exit(0) }
        }
        while true {
            try? await Task.sleep(nanoseconds: 100_000_000)
            worker.tick()
        }
    }
}
