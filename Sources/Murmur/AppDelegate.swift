import AVFoundation
import Cocoa
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DictationController()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var engineStatus = "Loading speech model…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.ensureDictionaryFile()
        setUpStatusItem()
        controller.onStateChange = { [weak self] _ in self?.updateIcon() }

        let firstLaunch = !Settings.hasLaunchedBefore
        if firstLaunch {
            Settings.hasLaunchedBefore = true
            try? SMAppService.mainApp.register()
        }

        requestMicrophone()
        startHotkeysWhenTrusted(prompt: true)
        loadSpeechEngine(announce: firstLaunch)
    }

    // MARK: Setup

    private func loadSpeechEngine(announce: Bool) {
        Task { @MainActor in
            do {
                controller.engine = try await SpeechEngine.prepare { [weak self] status in
                    Task { @MainActor in self?.engineStatus = status }
                }
                controller.engineError = nil
                updateIcon()
                if announce, controller.isReady {
                    controller.overlay.flash(.hint("Murmur is ready. Hold fn and speak"), for: 4)
                }
            } catch {
                controller.engineError = "Speech model failed to load: \(error.localizedDescription)"
                engineStatus = controller.engineError!
                updateIcon()
            }
        }
    }

    private func requestMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.updateIcon() }
        }
    }

    /// The event tap can only be created once Accessibility access is granted,
    /// so poll until it is (granting doesn't require a relaunch).
    private func startHotkeysWhenTrusted(prompt: Bool) {
        if AXIsProcessTrusted(), controller.hotkeys.start() {
            updateIcon()
            return
        }
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), self.controller.hotkeys.start() else { return }
                timer.invalidate()
                self.updateIcon()
                if self.controller.isReady {
                    self.controller.overlay.flash(.hint("All set. Hold fn and speak"), for: 3)
                }
            }
        }
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    private func updateIcon() {
        let symbol: String
        switch controller.state {
        case .recording: symbol = "waveform.circle.fill"
        case .processing: symbol = "ellipsis.circle"
        case .idle: symbol = controller.isReady ? "waveform" : "waveform.slash"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Status and anything that needs fixing
        menu.addItem(disabled(statusLine))
        if !controller.micAuthorized {
            menu.addItem(action("Grant Microphone Access…", #selector(openMicrophoneSettings)))
        }
        if !AXIsProcessTrusted() || !controller.hotkeys.isRunning {
            menu.addItem(action("Grant Accessibility Access…", #selector(openAccessibilitySettings)))
        }
        if fnKeyDoesSomethingElse {
            menu.addItem(action("Set 🌐 key to “Do Nothing”…", #selector(openKeyboardSettings)))
        }
        if isWisprFlowRunning {
            menu.addItem(action("Quit Wispr Flow (it also uses fn)", #selector(quitWisprFlow)))
        }

        menu.addItem(.separator())
        menu.addItem(disabled("Hold fn: dictate, release to paste"))
        menu.addItem(disabled("fn + Space: hands-free, fn to finish"))
        menu.addItem(disabled("Esc: cancel"))

        menu.addItem(.separator())
        let recent = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let history = Settings.history
        if history.isEmpty {
            recentMenu.addItem(disabled("Nothing yet"))
        } else {
            for (index, text) in history.enumerated() {
                let item = action(preview(text), #selector(copyHistoryItem(_:)))
                item.tag = index
                item.toolTip = text
                recentMenu.addItem(item)
            }
            recentMenu.addItem(.separator())
            recentMenu.addItem(disabled("Click to copy"))
        }
        recent.submenu = recentMenu
        menu.addItem(recent)

        menu.addItem(.separator())
        let ai = toggle("AI Cleanup (on-device)", Settings.aiCleanup && AICleaner.isAvailable, #selector(toggleAI))
        if let reason = AICleaner.unavailableReason {
            ai.isEnabled = false
            ai.toolTip = reason
            ai.title = "AI Cleanup: \(reason)"
        }
        menu.addItem(ai)
        menu.addItem(toggle("Sounds", Settings.sounds, #selector(toggleSounds)))
        menu.addItem(toggle("Add Space After Text", Settings.trailingSpace, #selector(toggleTrailingSpace)))
        menu.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(action("Edit Personal Dictionary…", #selector(editDictionary)))

        menu.addItem(.separator())
        let quit = action("Quit Murmur", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private var statusLine: String {
        if let error = controller.engineError { return error }
        if controller.engine == nil { return engineStatus }
        if !controller.micAuthorized || !controller.hotkeys.isRunning { return "Needs permission to work" }
        switch controller.state {
        case .recording: return "Listening…"
        case .processing: return "Polishing…"
        case .idle: return "Ready"
        }
    }

    private var fnKeyDoesSomethingElse: Bool {
        // 0 = "Do Nothing". Anything else (emoji picker, dictation, input source) fires on fn taps.
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return value != nil && value != 0
    }

    private var isWisprFlowRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.electron.wispr-flow").isEmpty
    }

    private func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }

    // MARK: Menu item helpers

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ selector: Selector) -> NSMenuItem {
        let item = action(title, selector)
        item.state = on ? .on : .off
        return item
    }

    // MARK: Actions

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        let history = Settings.history
        guard history.indices.contains(sender.tag) else { return }
        Paster.copy(history[sender.tag])
    }

    @objc private func toggleAI() { Settings.aiCleanup.toggle() }
    @objc private func toggleSounds() { Settings.sounds.toggle() }
    @objc private func toggleTrailingSpace() { Settings.trailingSpace.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            controller.overlay.flash(.error("Couldn't change login item: \(error.localizedDescription)"), for: 3)
        }
    }

    @objc private func editDictionary() {
        Settings.ensureDictionaryFile()
        NSWorkspace.shared.open(Settings.dictionaryURL)
    }

    @objc private func openMicrophoneSettings() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            requestMicrophone()
        } else {
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    @objc private func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        startHotkeysWhenTrusted(prompt: false)
    }

    @objc private func openKeyboardSettings() {
        openSettings("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    @objc private func quitWisprFlow() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.electron.wispr-flow").forEach { $0.terminate() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func openSettings(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
