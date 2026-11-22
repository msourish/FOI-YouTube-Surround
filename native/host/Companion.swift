import AppKit
import SafariServices
import Darwin

private let extensionID = "studio.foi.youtubesurround.Extension"

final class Worker {
    private var task: Process?
    private var writer: FileHandle?
    private var reader: FileHandle?

    func clear() {
        if let task, task.isRunning { task.terminate() }
        try? writer?.close()
        try? reader?.close()
        task = nil
        writer = nil
        reader = nil
    }

    func run(_ command: JSONObject) throws -> JSONObject {
        if task?.isRunning != true {
            clear()
            if command["op"] as? String != "sync" { return reply("stopped", "No 5.1 stream is active.") }
            guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Playback") else { throw BridgeError.io }
            let input = Pipe(), output = Pipe(), process = Process()
            process.executableURL = dir.appendingPathComponent("FOIPlaybackWorker")
            process.arguments = ["--resolver", dir.appendingPathComponent("resolve-audio").path]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            writer = input.fileHandleForWriting
            reader = output.fileHandleForReading
            task = process
        }
        guard let writer, let reader else { throw BridgeError.io }
        let requestID = UUID().uuidString
        var out = command
        out["requestID"] = requestID
        try writer.write(contentsOf: JSONSerialization.data(withJSONObject: out) + Data([10]))
        let deadline = ProcessInfo.processInfo.systemUptime + 1.6
        var bytes = Data()
        var raw = [UInt8](repeating: 0, count: 1024)
        while bytes.count < 8192 {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw BridgeError.io }
            var p = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let immediate = Darwin.poll(&p, 1, Int32(left * 1000))
            if immediate < 0 && errno == EINTR { continue }
            guard immediate > 0 else { throw BridgeError.io }
            let n = Darwin.read(reader.fileDescriptor, &raw, raw.count)
            guard n > 0 else { throw BridgeError.io }
            bytes.append(contentsOf: raw.prefix(n))
            guard bytes.last == 10 else { continue }
            guard var answer = try JSONSerialization.jsonObject(with: bytes) as? JSONObject,
                  answer["requestID"] as? String == requestID,
                  let state = answer["state"] as? String,
                  ["loading", "ready", "playing", "paused", "unavailable", "stopped", "error"].contains(state)
            else { throw BridgeError.invalid }
            answer.removeValue(forKey: "requestID")
            return answer
        }
        throw BridgeError.tooLarge
    }
}

final class CompanionBridge {
    private let acceptQueue = DispatchQueue(label: "studio.foi.youtubesurround.accept")
    private let commandQueue = DispatchQueue(label: "studio.foi.youtubesurround.commands")
    private let clients = DispatchSemaphore(value: 8)
    private var listener: DispatchSourceRead?
    private var nonces: [String: Double] = [:]
    private let worker = Worker()
    private var healthChecked = -Double.infinity
    private var monitorReady = false
    var announce: ((String) -> Void)?
    private var lastDescription = ""

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.io }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        guard Wire.withAddress({ Darwin.bind(fd, $0, $1) }) == 0, listen(fd, 16) == 0 else {
            close(fd); throw BridgeError.io
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                guard self.clients.wait(timeout: .now()) == .success else { close(client); continue }
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { close(client); self.clients.signal() }
                    do {
                        try Wire.configure(client)
                        let (object, nonce) = try Wire.decode(Wire.readFrame(client), direction: "request")
                        let answer = self.commandQueue.sync { self.handle(object, nonce: nonce) }
                        try Wire.writeFrame(client, Wire.encode(answer, direction: "reply", nonce: nonce))
                    } catch { return }
                }
            }
        }
        listener = source
        source.resume()
    }

    private func isMonitorReady() -> Bool {
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - healthChecked < 0.8 { return monitorReady }
        healthChecked = uptime
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        monitorReady = Self.hasRunningMonitor(in: support)
        return monitorReady
    }

    static func hasRunningMonitor(in support: URL) -> Bool {
        // The public monitor and the studio build keep independent session histories.
        ["FOI Surround Monitor", "Fairlight 5.1 Monitor"].contains { monitor in
            let root = support.appendingPathComponent(monitor, isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let newest = folders.filter { $0.lastPathComponent.hasPrefix("session-") }
                .max { $0.lastPathComponent < $1.lastPathComponent }
            guard let url = newest?.appendingPathComponent("status.json"),
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  (-1.0..<8.0).contains(Date().timeIntervalSince(date)),
                  let data = try? Data(contentsOf: url),
                  let health = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
                  health["state"] as? String == "running",
                  let input = health["input"] as? JSONObject,
                  input["uid"] as? String == "BlackHole16ch_UID", input["channels"] as? Int == 6,
                  let output = health["output"] as? JSONObject, output["started"] as? Bool == true
            else { return false }
            return true
        }
    }

    private func handle(_ object: JSONObject, nonce: String) -> JSONObject {
        let now = Date().timeIntervalSince1970
        nonces = nonces.filter { $0.value > now - 30 }
        guard nonces[nonce] == nil, let command = Wire.validate(object) else { return reply("error", "Invalid playback request.") }
        nonces[nonce] = now
        let answer: JSONObject
        do {
            if command["op"] as? String == "sync" && !isMonitorReady() {
                _ = try? worker.run(["op": "stop", "session": command["session"]!])
                answer = reply("unavailable", "Start FOI Surround Monitor, then try 5.1 again.")
            } else {
                answer = try worker.run(command)
            }
        } catch {
            worker.clear()
            answer = reply("error", "The 5.1 playback helper did not respond. Try 5.1 again.")
        }
        let status = (answer["message"] as? String) ?? (answer["state"] as? String)?.capitalized ?? ""
        if status != lastDescription {
            lastDescription = status
            DispatchQueue.main.async { [weak self] in self?.announce?(status) }
        }
        return answer
    }

    func stop() {
        listener?.cancel()
        commandQueue.sync { worker.clear() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let server = CompanionBridge()
    private var window: NSWindow!
    private let extensionStatus = NSTextField(wrappingLabelWithString: "Checking Safari…")
    private let playback = NSTextField(wrappingLabelWithString: "Ready for a YouTube tab.")
    private let backgroundLaunch = CommandLine.arguments.contains("--from-safari")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = NSView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 230),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "FOI YouTube Surround"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        let intro = NSTextField(wrappingLabelWithString: "Start FOI Surround Monitor. On a YouTube watch page in Safari, select the 5.1 control.")
        intro.font = .systemFont(ofSize: 14)
        playback.textColor = .secondaryLabelColor
        extensionStatus.font = .boldSystemFont(ofSize: 15)
        let settings = NSButton(title: "Open Safari Extensions…", target: self, action: #selector(openSettings))
        settings.bezelStyle = .rounded
        let stack = NSStackView(views: [extensionStatus, intro, playback, settings])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit FOI YouTube Surround", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu
        server.announce = { [weak self] in self?.playback.stringValue = $0 }
        do { try server.start() } catch { playback.stringValue = "The companion could not start. Quit any other copy and reopen this app." }
        refresh()
        if !backgroundLaunch { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }

    private func refresh() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionID) { [weak self] state, _ in
            DispatchQueue.main.async {
                self?.extensionStatus.stringValue = state?.isEnabled == true ? "Safari extension enabled" : "Enable the extension in Safari"
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { if window != nil { refresh() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }; refresh(); return true
    }
    func applicationWillTerminate(_ notification: Notification) { server.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func openSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionID) { [weak self] error in
            DispatchQueue.main.async { if error != nil { self?.extensionStatus.stringValue = "Open Safari → Settings → Extensions." } }
        }
    }
}

@main
enum CompanionMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--probe") {
            // Command-line diagnostics exercise the same authenticated transport used by Safari.
            while let line = readLine() {
                let result: JSONObject
                do {
                    guard line.utf8.count <= 4096,
                          let raw = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSONObject,
                          let command = Wire.validate(raw) else { throw BridgeError.invalid }
                    result = try Wire.request(command)
                } catch {
                    result = reply("error", error.localizedDescription)
                }
                if let data = try? JSONSerialization.data(withJSONObject: result) {
                    try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
                }
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
