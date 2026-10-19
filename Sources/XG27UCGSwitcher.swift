import AppKit
import Carbon
import CoreAudio

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
    private var autoSwitchMenuItem: NSMenuItem!
    private var inputItems: [NSMenuItem] = []
    private var hotKeys: [EventHotKeyRef?] = []
    private var audioDeviceListener: AudioObjectPropertyListenerBlock?
    private var audioDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var meizuHiFiWasPresent = false
    private var isSwitching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "XG27UCG 输入切换")
        statusItem.button?.toolTip = "XG27UCG 输入切换"
        buildMenu()
        registerGlobalHotKeys()
        startAudioDeviceDetection()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let audioDeviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &audioDeviceAddress,
                DispatchQueue.main,
                audioDeviceListener
            )
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "XG27UCG 输入切换", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        inputItems = [
            makeInputItem("DisplayPort", value: 15, key: "\u{F704}", icon: "display"),
            makeInputItem("USB-C", value: 27, key: "\u{F705}", icon: "cable.connector.horizontal"),
            makeInputItem("HDMI", value: 17, key: "\u{F706}", icon: "cable.connector")
        ]
        inputItems.forEach(menu.addItem)

        menu.addItem(.separator())
        statusMenuItem = NSMenuItem(title: "热键：Ctrl + F1/F2/F3 或 Ctrl + Alt + 1/2/3", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        autoSwitchMenuItem = NSMenuItem(title: "自动切换：等待 MEIZU HiFi 声卡", action: nil, keyEquivalent: "")
        autoSwitchMenuItem.isEnabled = false
        menu.addItem(autoSwitchMenuItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func makeInputItem(_ title: String, value: Int, key: String, icon: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(switchInput(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = [.control]
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

        let definitions: [(id: UInt32, keyCode: UInt32, modifiers: UInt32)] = [
            (1, 122, UInt32(controlKey)),
            (2, 120, UInt32(controlKey)),
            (3, 99, UInt32(controlKey)),
            (11, 18, UInt32(controlKey | optionKey)),
            (12, 19, UInt32(controlKey | optionKey)),
            (13, 20, UInt32(controlKey | optionKey))
        ]
        for (id, keyCode, modifiers) in definitions {
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
            ((id == 1 || id == 11) && item.tag == 15) ||
            ((id == 2 || id == 12) && item.tag == 27) ||
            ((id == 3 || id == 13) && item.tag == 17)
        }) else { return }
        switchInput(item)
    }

    @objc private func switchInput(_ sender: NSMenuItem) {
        guard !isSwitching else { return }
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
        isSwitching = busy
        inputItems.forEach { $0.isEnabled = !busy }
        statusMenuItem.title = message
        statusItem.button?.image = NSImage(systemSymbolName: busy ? "display.trianglebadge.exclamationmark" : "display", accessibilityDescription: "XG27UCG 输入切换")
    }

    private func startAudioDeviceDetection() {
        checkForMeizuHiFi()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.checkForMeizuHiFi()
        }
        audioDeviceListener = listener
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &audioDeviceAddress,
            DispatchQueue.main,
            listener
        )
        if status != noErr {
            autoSwitchMenuItem.title = "自动检测启动失败（\(status)）"
        }
    }

    private func checkForMeizuHiFi() {
        let matchingName = audioDeviceNames().first { name in
            let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let isMeizu = normalized.contains("meizu") || normalized.contains("魅族")
            return isMeizu && normalized.contains("hifi")
        }
        let isPresent = matchingName != nil

        if let matchingName {
            autoSwitchMenuItem.title = "已检测：\(matchingName) → USB-C"
            if !meizuHiFiWasPresent, !isSwitching,
               let usbCItem = inputItems.first(where: { $0.tag == 27 }) {
                switchInput(usbCItem)
            }
        } else {
            autoSwitchMenuItem.title = "自动切换：等待 MEIZU HiFi 声卡"
        }
        meizuHiFiWasPresent = isPresent
    }

    private func audioDeviceNames() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices) == noErr else {
            return []
        }

        return devices.compactMap { deviceID in
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var unmanagedName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &unmanagedName) == noErr,
                  let name = unmanagedName?.takeUnretainedValue() else {
                return nil
            }
            return name as String
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
