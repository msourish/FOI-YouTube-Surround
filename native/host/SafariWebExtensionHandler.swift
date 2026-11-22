import AppKit
import SafariServices

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        guard let object = item?.userInfo?[SFExtensionMessageKey] as? JSONObject,
              let command = Wire.validate(object) else {
            finish(context, reply("error", "Invalid playback request."))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                self.finish(context, try Wire.request(command))
            } catch BridgeError.disconnected {
                guard command["op"] as? String == "sync" else {
                    self.finish(context, reply("stopped", "The companion is closed."))
                    return
                }
                self.startCompanion(command, context)
            } catch {
                self.finish(context, reply("error", error.localizedDescription))
            }
        }
    }

    private func startCompanion(_ command: JSONObject, _ context: NSExtensionContext) {
        // Open only this extension's own container, never a caller-provided URL.
        let extensionURL = Bundle(for: Self.self).bundleURL
        let appURL = extensionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appURL.pathExtension == "app", Bundle(url: appURL)?.bundleIdentifier == "studio.foi.youtubesurround" else {
            finish(context, reply("error", "Open FOI YouTube Surround and try again."))
            return
        }
        DispatchQueue.main.async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = false
            configuration.addsToRecentItems = false
            configuration.arguments = ["--from-safari"]
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                guard error == nil else {
                    self.finish(context, reply("error", "Open FOI YouTube Surround and try again."))
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    for _ in 0..<10 {
                        if let answer = try? Wire.request(command) {
                            self.finish(context, answer)
                            return
                        }
                        Thread.sleep(forTimeInterval: 0.12)
                    }
                    self.finish(context, reply("error", "Open FOI YouTube Surround and try again."))
                }
            }
        }
    }

    private func finish(_ context: NSExtensionContext, _ answer: JSONObject) {
        let result = NSExtensionItem()
        result.userInfo = [SFExtensionMessageKey: answer]
        context.completeRequest(returningItems: [result])
    }
}
