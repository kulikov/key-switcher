import AppKit
import Carbon
import ServiceManagement

final class Switcher {
    private struct Key {
        let code: Int
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
        try? SMAppService.mainApp.register()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.reset()
        }

        installTap()
    }

    private func installTap() {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
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
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            optionDownAt = nil
            reset()
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
            if code == kVK_Function || code == kVK_CapsLock { reset() }

            if code == kVK_Option && held == .maskAlternate {
                optionDownAt = now
            } else if code == kVK_Option, held.isEmpty, let downAt = optionDownAt, now - downAt < 0.5 {
                optionDownAt = nil
                DispatchQueue.main.async { self.convert() }
            } else {
                optionDownAt = nil
            }

        case .scrollWheel:
            optionDownAt = nil

        case .keyDown:
            optionDownAt = nil
            let modified = !flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty
            let synthetic = event.getIntegerValueField(.eventSourceStateID) != Int64(CGEventSourceStateID.hidSystemState.rawValue)
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 && code != kVK_Delete
            guard !modified, !synthetic, !repeated else { return reset() }

            switch code {
            case kVK_Delete:
                if spaces > 0 { spaces -= 1 } else if !word.isEmpty { word.removeLast() }
            case kVK_Space:
                if !word.isEmpty { spaces += 1 }
            default:
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
                guard length <= chars.count, printable(String(utf16CodeUnits: chars, count: length)) else { return reset() }

                if spaces > 0 { reset() }
                word.append(Key(code: code, flags: flags.intersection([.maskShift, .maskAlphaShift])))
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

        let filter: [String: Any] = [
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ]
        let layouts = TISCreateInputSourceList(filter as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
        let current = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let other = layouts.first(where: { id($0) != id(current) }) else { return }

        func switchOnly() {
            reset()
            TISSelectInputSource(other)
        }

        guard !IsSecureEventInputEnabled() else { return switchOnly() }
        let unsupported: [AXError] = [.attributeUnsupported, .parameterizedAttributeUnsupported, .noValue]
        var focused: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused)
        guard focusStatus == .success || unsupported.contains(focusStatus) else { return switchOnly() }
        let element = focused.map { $0 as! AXUIElement }

        if !word.isEmpty {
            let shown = word.map { translate($0, in: current) }.joined() + String(repeating: " ", count: spaces)
            let length = shown.utf16.count

            var caret: CFTypeRef?
            var range = CFRange()
            let caretStatus = element.map { AXUIElementCopyAttributeValue($0, kAXSelectedTextRangeAttribute as CFString, &caret) } ?? .noValue
            if let element, caretStatus == .success {
                guard let caret, CFGetTypeID(caret) == AXValueGetTypeID(), AXValueGetValue(caret as! AXValue, .cfRange, &range),
                      range.length == 0, range.location >= length else { return switchOnly() }

                var span = CFRange(location: range.location - length, length: length)
                var before: CFTypeRef?
                let textStatus = AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString, AXValueCreate(.cfRange, &span)!, &before
                )
                let verified = textStatus == .success ? before as? String == shown : unsupported.contains(textStatus)
                guard verified else { return switchOnly() }
            } else if !unsupported.contains(caretStatus) {
                return switchOnly()
            }

            let strokes = word.map { ($0, translate($0, in: other)) }
                + Array(repeating: (Key(code: kVK_Space, flags: []), " "), count: spaces)
            return replace(erasing: word.count + spaces, with: strokes, in: other, reselect: false)
        }

        var editable: DarwinBoolean = false
        var selected: CFTypeRef?
        if let element {
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &editable)
            AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected)
        }
        guard editable.boolValue, let selection = selected as? String, (1...1000).contains(selection.count) else { return switchOnly() }

        let inCurrent = keymap(current)
        let inOther = keymap(other)
        let fromOther = selection.filter { inOther[String($0)] != nil && inCurrent[String($0)] == nil }.count
        let fromCurrent = selection.filter { inCurrent[String($0)] != nil && inOther[String($0)] == nil }.count
        let (keys, target) = fromOther > fromCurrent ? (inOther, current) : (inCurrent, other)

        let strokes = selection.compactMap { keys[String($0)] }.map { ($0, translate($0, in: target)) }
        guard strokes.count == selection.count, strokes.allSatisfy({ printable($0.1) }) else { return switchOnly() }
        replace(erasing: 1, with: strokes, in: target, reselect: true)
    }

    private func replace(erasing count: Int, with strokes: [(Key, String)], in target: TISInputSource, reselect: Bool) {
        for _ in 0..<count { press(kVK_Delete) }
        TISSelectInputSource(target)

        for (key, text) in strokes { press(key.code, flags: key.flags, text: text) }
        if reselect {
            for _ in strokes { press(kVK_LeftArrow, flags: .maskShift) }
        }
    }

    private func keymap(_ layout: TISInputSource) -> [String: Key] {
        var keys: [String: Key] = [:]
        for flags in [CGEventFlags(), .maskShift] {
            for code in 0..<128 {
                let key = Key(code: code, flags: flags)
                let text = translate(key, in: layout)
                if keys[text] == nil, printable(text) { keys[text] = key }
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
            keyboard, UInt16(key.code), UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, 4, &length, &chars
        )
        return length <= chars.count ? String(utf16CodeUnits: chars, count: length) : ""
    }

    private func printable(_ text: String) -> Bool {
        text.count == 1 && text.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func press(_ code: Int, flags: CGEventFlags = [], text: String? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
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
NSApplication.shared.run()
