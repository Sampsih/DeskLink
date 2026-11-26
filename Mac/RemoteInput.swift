import AppKit
import CoreGraphics

final class RemoteInput {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var holdingMouse = false
    private var lastPoint = CGPoint.zero
    private var heldKeys: [UInt16: CGEventFlags] = [:]

    func pointer(_ input: Pointer) {
        guard input.point.x.isFinite, input.point.y.isFinite else { return }
        let bounds = CGDisplayBounds(input.display)
        let point = CGPoint(
            x: bounds.minX + min(max(0, input.point.x), 1) * max(0, bounds.width - 1),
            y: bounds.minY + min(max(0, input.point.y), 1) * max(0, bounds.height - 1)
        )
        lastPoint = point
        switch input.action {
        case .move:
            mouse(holdingMouse ? .leftMouseDragged : .mouseMoved, at: point)
        case .click:
            mouse(.leftMouseDown, at: point, click: 1)
            mouse(.leftMouseUp, at: point, click: 1)
        case .doubleClick:
            for count in 1...2 {
                mouse(.leftMouseDown, at: point, click: Int64(count))
                mouse(.leftMouseUp, at: point, click: Int64(count))
            }
        case .rightClick:
            mouse(.rightMouseDown, at: point, button: .right, click: 1)
            mouse(.rightMouseUp, at: point, button: .right, click: 1)
        case .down:
            holdingMouse = true
            mouse(.leftMouseDown, at: point, click: 1)
        case .up:
            holdingMouse = false
            mouse(.leftMouseUp, at: point, click: 1)
        }
    }

    func scroll(_ delta: RemotePoint) {
        guard delta.x.isFinite, delta.y.isFinite else { return }
        let vertical = Int32(max(-500, min(500, delta.y)).rounded())
        let horizontal = Int32(max(-500, min(500, delta.x)).rounded())
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: vertical, wheel2: horizontal, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    func key(_ input: RemoteKey) {
        guard input.code <= 127 else { return }
        var flags: CGEventFlags = []
        if input.modifiers & RemoteKey.command != 0 { flags.insert(.maskCommand) }
        if input.modifiers & RemoteKey.shift != 0 { flags.insert(.maskShift) }
        if input.modifiers & RemoteKey.option != 0 { flags.insert(.maskAlternate) }
        if input.modifiers & RemoteKey.control != 0 { flags.insert(.maskControl) }
        if let down = input.down {
            heldKeys[input.code] = down ? flags : nil
            postKey(input.code, flags: flags, down: down)
        } else {
            postKey(input.code, flags: flags, down: true)
            postKey(input.code, flags: flags, down: false)
        }
    }

    func text(_ text: String) {
        guard text.utf16.count <= 16_384 else { return }
        // Preserve surrogate pairs while staying within Quartz's Unicode event limit.
        var units: [UInt16] = []
        for scalar in text.unicodeScalars {
            let next = Array(String(scalar).utf16)
            if units.count + next.count > 20 {
                postText(units)
                units.removeAll(keepingCapacity: true)
            }
            units.append(contentsOf: next)
        }
        if !units.isEmpty { postText(units) }
    }

    func release() {
        if holdingMouse { mouse(.leftMouseUp, at: lastPoint, click: 1) }
        holdingMouse = false
        for (code, flags) in heldKeys { postKey(code, flags: flags, down: false) }
        heldKeys.removeAll()
    }

    private func postKey(_ code: UInt16, flags: CGEventFlags, down: Bool) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func postText(_ text: [UInt16]) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.flags = []
            event?.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
            event?.post(tap: .cghidEventTap)
        }
    }

    private func mouse(_ kind: CGEventType, at point: CGPoint, button: CGMouseButton = .left, click: Int64 = 0) {
        let event = CGEvent(mouseEventSource: source, mouseType: kind, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: click)
        event?.post(tap: .cghidEventTap)
    }
}
