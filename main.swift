import AppKit
import Carbon
import ServiceManagement

final class Switcher {
    private struct Key {
        let code: UInt16
        let flags: CGEventFlags
    }

    private let marker: Int64 = 0x6B657973
    private let source = CGEventSource(stateID: .privateState)
    private var tap: CFMachPort?
    private var word: [Key] = []
    private var spaces = 0
    private var optionDownAt: TimeInterval?

    func start() {
        source?.userData = marker
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reset()
        }

        installTap()
    }

    private func installTap() {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue },
            callback: { _, type, event, switcher in
                Unmanaged<Switcher>.fromOpaque(switcher!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.installTap() }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == marker { return }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        switch type {
        case .flagsChanged:
            let held = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
            let now = ProcessInfo.processInfo.systemUptime

            if code == kVK_Option && held == .maskAlternate {
                optionDownAt = now
            } else if code == kVK_Option, held.isEmpty, let downAt = optionDownAt, now - downAt < 0.5 {
                optionDownAt = nil
                DispatchQueue.main.async { self.convert() }
            } else {
                optionDownAt = nil
            }

        case .keyDown:
            optionDownAt = nil
            guard flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty else { return reset() }

            switch code {
            case kVK_Delete:
                if spaces > 0 { spaces -= 1 } else if !word.isEmpty { word.removeLast() }
            case kVK_Space:
                if !word.isEmpty { spaces += 1 }
            default:
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
                guard length == 1, chars[0] >= 0x20, chars[0] != 0x7F else { return reset() }

                if spaces > 0 { reset() }
                word.append(Key(code: UInt16(code), flags: flags.intersection([.maskShift, .maskAlphaShift])))
            }

        default:
            optionDownAt = nil
            reset()
        }
    }

    private func convert() {
        func id(_ layout: TISInputSource) -> String {
            Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(layout, kTISPropertyInputSourceID)).takeUnretainedValue() as String
        }

        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        let layouts = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
        let current = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let other = layouts.first(where: { id($0) != id(current) }) else { return }

        if !word.isEmpty {
            let strokes: [(Key, String)] = word.map { ($0, translate($0, in: other)) }
                + Array(repeating: (Key(code: UInt16(kVK_Space), flags: []), " "), count: spaces)
            return replace(erasing: word.count + spaces, with: strokes, in: other, reselect: false)
        }

        var focused: CFTypeRef?
        var selected: CFTypeRef?
        var editable: DarwinBoolean = false
        AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused)
        if let focused {
            AXUIElementIsAttributeSettable(focused as! AXUIElement, kAXValueAttribute as CFString, &editable)
            AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected)
        }
        guard editable.boolValue, let selection = selected as? String, !selection.isEmpty else {
            TISSelectInputSource(other)
            return
        }

        let inCurrent = keymap(current)
        let inOther = keymap(other)
        let fromOther = selection.filter { inOther[String($0)] != nil && inCurrent[String($0)] == nil }.count
        let fromCurrent = selection.filter { inCurrent[String($0)] != nil && inOther[String($0)] == nil }.count
        let (keys, target) = fromOther > fromCurrent ? (inOther, current) : (inCurrent, other)

        let strokes: [(Key, String)] = selection.map { char in
            keys[String(char)].map { ($0, translate($0, in: target)) } ?? (Key(code: 0, flags: []), String(char))
        }
        replace(erasing: 0, with: strokes, in: target, reselect: true)
    }

    private func replace(erasing count: Int, with strokes: [(Key, String)], in target: TISInputSource, reselect: Bool) {
        for _ in 0..<count { press(UInt16(kVK_Delete)) }
        TISSelectInputSource(target)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for (key, text) in strokes { self.press(key.code, flags: key.flags, text: text) }
            if reselect {
                for _ in strokes { self.press(UInt16(kVK_LeftArrow), flags: .maskShift) }
            }
        }
    }

    private func keymap(_ layout: TISInputSource) -> [String: Key] {
        var keys: [String: Key] = [:]
        for flags in [CGEventFlags(), .maskShift] {
            for code in UInt16(0)..<128 {
                let key = Key(code: code, flags: flags)
                let text = translate(key, in: layout)
                if keys[text] == nil, !text.isEmpty, text.rangeOfCharacter(from: .controlCharacters) == nil {
                    keys[text] = key
                }
            }
        }
        return keys
    }

    private func translate(_ key: Key, in layout: TISInputSource) -> String {
        let data = Unmanaged<CFData>.fromOpaque(TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData)).takeUnretainedValue()
        let keyboard = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)

        var modifiers: UInt32 = 0
        if key.flags.contains(.maskShift) { modifiers |= UInt32(shiftKey >> 8) }
        if key.flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock >> 8) }

        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        UCKeyTranslate(
            keyboard, key.code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, 4, &length, &chars
        )
        return String(utf16CodeUnits: chars, count: length)
    }

    private func press(_ code: UInt16, flags: CGEventFlags = [], text: String? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func reset() {
        word = []
        spaces = 0
    }
}

let switcher = Switcher()
switcher.start()
try? SMAppService.mainApp.register()
NSApplication.shared.run()
