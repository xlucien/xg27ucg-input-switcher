import AppKit
import Carbon

private var m1ddcPath: String {
    if let bundled = Bundle.main.path(forResource: "m1ddc", ofType: nil, inDirectory: "bin"),
       FileManager.default.isExecutableFile(atPath: bundled) {
        return bundled
    }
    return "/opt/homebrew/bin/m1ddc"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var inputItems: [NSMenuItem] = []
    private var hotKeys: [EventHotKeyRef?] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "XG27UCG 输入切换")
        statusItem.button?.toolTip = "XG27UCG 输入切换"
        buildMenu()
        registerGlobalHotKeys()
    }

    private func buildMenu() {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "XG27UCG 输入切换", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        inputItems = [
            makeInputItem("DisplayPort", value: 15, key: "1", icon: "display"),
            makeInputItem("HDMI", value: 17, key: "2", icon: "cable.connector"),
            makeInputItem("USB-C", value: 27, key: "3", icon: "cable.connector.horizontal")
        ]
        inputItems.forEach(menu.addItem)

        menu.addItem(.separator())
        statusMenuItem = NSMenuItem(title: "就绪 · 全局热键 ⌃⌥1 / 2 / 3", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func makeInputItem(_ title: String, value: Int, key: String, icon: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(switchInput(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = [.control, .option]
        item.target = self
        item.tag = value
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        return item
    }

    private func registerGlobalHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.triggerHotKey(id: hotKeyID.id) }
            return noErr
        }, 1, &eventType, selfPointer, nil)

        let modifiers = UInt32(controlKey | optionKey)
        let definitions: [(UInt32, UInt32)] = [(1, 18), (2, 19), (3, 20)]
        for (id, keyCode) in definitions {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: fourCharCode("XG27"), id: id)
            RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }

    private func fourCharCode(_ text: String) -> OSType {
        text.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }

    private func triggerHotKey(id: UInt32) {
        guard let item = inputItems.first(where: { item in
            (id == 1 && item.tag == 15) || (id == 2 && item.tag == 17) || (id == 3 && item.tag == 27)
        }) else { return }
        switchInput(item)
    }

    @objc private func switchInput(_ sender: NSMenuItem) {
        let value = sender.tag
        let inputName = sender.title
        setBusy(true, message: "正在切换到 \(inputName)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.runM1DDC(value: value)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.inputItems.forEach { $0.state = ($0.tag == value ? .on : .off) }
                    self.setBusy(false, message: "已发送：\(inputName)")
                case .failure(let message): self.setBusy(false, message: "失败：\(message)")
                case .none: self.setBusy(false, message: "切换失败")
                }
            }
        }
    }

    private enum SwitchResult { case success; case failure(String) }

    private func runM1DDC(value: Int) -> SwitchResult {
        guard FileManager.default.isExecutableFile(atPath: m1ddcPath) else { return .failure("未找到 m1ddc") }
        guard let monitorID = findXG27UCG() else { return .failure("未找到 XG27UCG") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: m1ddcPath)
        process.arguments = ["display", monitorID, "set", "input", String(value)]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return .success }
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(detail?.isEmpty == false ? detail! : "请检查 DDC/CI")
        } catch { return .failure(error.localizedDescription) }
    }

    private func findXG27UCG() -> String? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: m1ddcPath)
        process.arguments = ["display", "list"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            for line in output.components(separatedBy: .newlines) where line.localizedCaseInsensitiveContains("XG27UCG") {
                if let start = line.lastIndex(of: "("), let end = line.lastIndex(of: ")"), start < end {
                    return String(line[line.index(after: start)..<end])
                }
            }
        } catch { return nil }
        return nil
    }

    private func setBusy(_ busy: Bool, message: String) {
        inputItems.forEach { $0.isEnabled = !busy }
        statusMenuItem.title = message
        statusItem.button?.image = NSImage(systemSymbolName: busy ? "display.trianglebadge.exclamationmark" : "display", accessibilityDescription: "XG27UCG 输入切换")
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
