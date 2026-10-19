import AppKit
import Carbon
import CoreAudio
import IOKit.hid

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
    private var k70WasPresent = false
    private var hidManager: IOHIDManager?
    private var hidEvaluationWorkItem: DispatchWorkItem?
    private var retryWorkItems: [DispatchWorkItem] = []
    private var isSwitching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "XG27UCG 输入切换")
        statusItem.button?.toolTip = "XG27UCG 输入切换"
        buildMenu()
        registerGlobalHotKeys()
        startAudioDeviceDetection()
        startKeyboardDetection()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        retryWorkItems.forEach { $0.cancel() }
        hidEvaluationWorkItem?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let audioDeviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &audioDeviceAddress,
                DispatchQueue.main,
                audioDeviceListener
            )
        }
        if let hidManager {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
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
            makeInputItem("USB-C", value: 26, key: "\u{F705}", icon: "cable.connector.horizontal"),
            makeInputItem("HDMI", value: 17, key: "\u{F706}", icon: "cable.connector")
        ]
        inputItems.forEach(menu.addItem)

        menu.addItem(.separator())
        statusMenuItem = NSMenuItem(title: "热键：Ctrl + F1/F2/F3 或 Ctrl + Alt + 1/2/3", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        autoSwitchMenuItem = NSMenuItem(title: "自动切换：等待 MEIZU HiFi 或 K70", action: nil, keyEquivalent: "")
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
            ((id == 2 || id == 12) && item.tag == 26) ||
            ((id == 3 || id == 13) && item.tag == 17)
        }) else { return }
        switchInput(item)
    }

    @objc private func switchInput(_ sender: NSMenuItem) {
        performSwitch(value: sender.tag, inputName: sender.title)
    }

    private func performSwitch(value: Int, inputName: String, completion: ((Bool) -> Void)? = nil) {
        guard !isSwitching else {
            completion?(false)
            return
        }
        setBusy(true, message: "正在切换到 \(inputName)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.runM1DDC(value: value)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.inputItems.forEach { $0.state = ($0.tag == value ? .on : .off) }
                    self.setBusy(false, message: "已发送：\(inputName)")
                    completion?(true)
                case .failure(let message):
                    self.setBusy(false, message: "失败：\(message)")
                    completion?(false)
                case .none:
                    self.setBusy(false, message: "切换失败")
                    completion?(false)
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
            if process.terminationStatus == 0 {
                Thread.sleep(forTimeInterval: 0.15)
                if let actualValue = readCurrentInput(monitorID: monitorID), actualValue != value {
                    return .failure("显示器未接受输入值 \(value)，当前值为 \(actualValue)")
                }
                return .success
            }
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(detail?.isEmpty == false ? detail! : "请检查 DDC/CI")
        } catch { return .failure(error.localizedDescription) }
    }

    private func readCurrentInput(monitorID: String) -> Int? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: m1ddcPath)
        process.arguments = ["display", monitorID, "get", "input"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return nil
        }
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
        evaluateAutoSwitch()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.evaluateAutoSwitch()
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

    private func evaluateAutoSwitch(force: Bool = false) {
        let matchingName = audioDeviceNames().first { name in
            let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let isMeizu = normalized.contains("meizu") || normalized.contains("魅族")
            return isMeizu && normalized.contains("hifi")
        }
        let meizuPresent = matchingName != nil
        let k70Name = connectedK70Name()
        let k70Present = k70Name != nil
        let newlyDetected = (meizuPresent && !meizuHiFiWasPresent) || (k70Present && !k70WasPresent)

        if let matchingName {
            autoSwitchMenuItem.title = "已检测：\(matchingName) → USB-C"
        } else if let k70Name {
            autoSwitchMenuItem.title = "已检测：\(k70Name) → USB-C"
        } else {
            autoSwitchMenuItem.title = "自动切换：等待 MEIZU HiFi 或 K70"
        }
        meizuHiFiWasPresent = meizuPresent
        k70WasPresent = k70Present

        if (newlyDetected || force) && (meizuPresent || k70Present) {
            beginUSBCSwitchRetries()
        }
    }

    private func startKeyboardDetection() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
        IOHIDManagerSetDeviceMatching(manager, nil)
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let callback: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.scheduleHIDEvaluation() }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, callback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        evaluateAutoSwitch()
    }

    private func scheduleHIDEvaluation() {
        hidEvaluationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.evaluateAutoSwitch()
        }
        hidEvaluationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func connectedK70Name() -> String? {
        guard let hidManager, let deviceSet = IOHIDManagerCopyDevices(hidManager) else { return nil }
        for case let device as IOHIDDevice in (deviceSet as NSSet) {
            guard let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String else { continue }
            if name.localizedCaseInsensitiveContains("K70") { return name.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    private func beginUSBCSwitchRetries() {
        retryWorkItems.forEach { $0.cancel() }
        retryWorkItems.removeAll()
        attemptUSBCSwitch(delays: [0, 3, 8, 15], index: 0)
    }

    private func attemptUSBCSwitch(delays: [TimeInterval], index: Int) {
        guard index < delays.count else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isSwitching {
                self.attemptUSBCSwitch(delays: delays, index: index + 1)
                return
            }
            self.performSwitch(value: 26, inputName: "USB-C") { success in
                if !success { self.attemptUSBCSwitch(delays: delays, index: index + 1) }
            }
        }
        retryWorkItems.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[index], execute: workItem)
    }

    @objc private func handleWake() {
        meizuHiFiWasPresent = false
        k70WasPresent = false
        let workItem = DispatchWorkItem { [weak self] in self?.evaluateAutoSwitch(force: true) }
        retryWorkItems.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
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
