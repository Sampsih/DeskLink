import SwiftUI
import UIKit

struct RemoteSurface: UIViewRepresentable {
    let session: Session
    let display: RemoteDisplay?
    let trackpad: Bool
    let zoomReset: Int
    let showKeyboard: Bool

    func makeUIView(context: Context) -> SurfaceView {
        SurfaceView(session: session)
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        view.update(display: display, trackpad: trackpad, zoomReset: zoomReset)
        if showKeyboard && !view.isFirstResponder {
            DispatchQueue.main.async { [weak view] in _ = view?.becomeFirstResponder() }
        } else if !showKeyboard && view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

final class SurfaceView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    private let session: Session
    private var display: RemoteDisplay?
    private var cursor = RemotePoint(x: 0.5, y: 0.5)
    private var trackpad = false
    private var zoomReset = 0
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var dragging = false
    private var physicalKeys: Set<UIKeyboardHIDUsage> = []

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .black
        layer.addSublayer(session.video.layer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(click(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleClick(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        let right = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        right.numberOfTouchesRequired = 2
        let secondary = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        secondary.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        secondary.buttonMaskRequired = .secondary
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let mouseScroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        mouseScroll.allowedTouchTypes = []
        mouseScroll.allowedScrollTypesMask = .all
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
        drag.minimumPressDuration = 0.38
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        scroll.delegate = self
        pinch.delegate = self
        [tap, double, right, secondary, pan, scroll, mouseScroll, drag, pinch, hover].forEach(addGestureRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none

    func insertText(_ text: String) {
        if text == "\n" {
            session.send(.key(RemoteKey(code: 36)))
        } else if text == "\t" {
            session.send(.key(RemoteKey(code: 48)))
        } else {
            session.send(.text(text))
        }
    }

    func deleteBackward() {
        session.send(.key(RemoteKey(code: 51)))
    }

    func update(display: RemoteDisplay?, trackpad: Bool, zoomReset: Int) {
        if self.display?.id != display?.id || self.zoomReset != zoomReset {
            zoom = 1
            offset = .zero
            cursor = RemotePoint(x: 0.5, y: 0.5)
        }
        self.display = display
        self.trackpad = trackpad
        self.zoomReset = zoomReset
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let display else { return }
        let scale = min(bounds.width / CGFloat(display.width), bounds.height / CGFloat(display.height))
        let size = CGSize(width: CGFloat(display.width) * scale * zoom, height: CGFloat(display.height) * scale * zoom)
        let maxX = max(0, (size.width - bounds.width) / 2)
        let maxY = max(0, (size.height - bounds.height) / 2)
        offset.x = min(max(offset.x, -maxX), maxX)
        offset.y = min(max(offset.y, -maxY), maxY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.video.layer.frame = CGRect(x: bounds.midX - size.width / 2 + offset.x,
                                           y: bounds.midY - size.height / 2 + offset.y,
                                           width: size.width, height: size.height)
        CATransaction.commit()
    }

    private func point(at location: CGPoint) -> RemotePoint? {
        let rect = session.video.layer.frame
        guard rect.width > 0, rect.height > 0 else { return nil }
        return RemotePoint(x: min(1, max(0, (location.x - rect.minX) / rect.width)),
                           y: min(1, max(0, (location.y - rect.minY) / rect.height)))
    }

    private func inside(_ location: CGPoint) -> Bool {
        session.video.layer.frame.contains(location)
    }

    private func send(_ action: PointerAction, at location: CGPoint, absolute: Bool = false) {
        guard let display else { return }
        if !trackpad || absolute {
            guard let position = point(at: location) else { return }
            cursor = position
        }
        session.send(.pointer(Pointer(display: display.id, point: cursor, action: action)))
    }

    private func move(by translation: CGPoint) {
        let frame = session.video.layer.frame
        guard frame.width > 0, frame.height > 0 else { return }
        cursor.x = min(1, max(0, cursor.x + translation.x * 1.45 / frame.width))
        cursor.y = min(1, max(0, cursor.y + translation.y * 1.45 / frame.height))
    }

    @objc private func click(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        if trackpad || inside(location) { send(.click, at: location) }
    }

    @objc private func doubleClick(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        if trackpad || inside(location) { send(.doubleClick, at: location) }
    }

    @objc private func rightClick(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        if trackpad || inside(location) { send(.rightClick, at: location) }
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            if !trackpad {
                let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
                guard inside(start) else { return }
                dragging = true
                send(.down, at: start)
            }
            fallthrough
        case .changed:
            if trackpad {
                move(by: translation)
            }
            if trackpad || dragging { send(.move, at: location) }
        case .ended, .cancelled, .failed:
            if dragging {
                send(.up, at: location)
                dragging = false
            }
        default:
            break
        }
        gesture.setTranslation(.zero, in: self)
    }

    @objc private func hold(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard trackpad || inside(location) else { return }
            dragging = true
            holdLocation = location
            send(.down, at: location)
        case .changed:
            if trackpad {
                move(by: CGPoint(x: location.x - holdLocation.x, y: location.y - holdLocation.y))
                holdLocation = location
            }
            if dragging { send(.move, at: location) }
        case .ended, .cancelled, .failed:
            if dragging {
                send(.up, at: location)
                dragging = false
            }
        default:
            break
        }
    }

    private var holdLocation = CGPoint.zero

    @objc private func scroll(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        let location = gesture.location(in: self)
        guard trackpad || inside(location) else { return }
        if gesture.state == .began && !trackpad { send(.move, at: location) }
        let delta = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        session.send(.scroll(RemotePoint(x: Double(delta.x), y: Double(delta.y))))
    }

    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        let pivot = gesture.location(in: self)
        let old = zoom
        zoom = min(4, max(1, zoom * gesture.scale))
        let ratio = zoom / old
        offset.x = (offset.x + bounds.midX - pivot.x) * ratio - (bounds.midX - pivot.x)
        offset.y = (offset.y + bounds.midY - pivot.y) * ratio - (bounds.midY - pivot.y)
        gesture.scale = 1
        setNeedsLayout()
    }

    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        let location = gesture.location(in: self)
        if inside(location) { send(.move, at: location, absolute: true) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, let code = Self.codes[key.keyCode] else {
                unhandled.insert(press)
                continue
            }
            let flags = modifiers(key.modifierFlags)
            guard flags & (RemoteKey.command | RemoteKey.control) != 0 || Self.special.contains(code) else {
                unhandled.insert(press)
                continue
            }
            physicalKeys.insert(key.keyCode)
            session.send(.key(RemoteKey(code: code, modifiers: flags, down: true)))
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = release(presses)
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = release(presses)
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }

    private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
        Set(presses.filter { press in
            guard let key = press.key, physicalKeys.remove(key.keyCode) != nil,
                  let code = Self.codes[key.keyCode] else { return true }
            session.send(.key(RemoteKey(code: code, modifiers: modifiers(key.modifierFlags), down: false)))
            return false
        })
    }

    private func modifiers(_ flags: UIKeyModifierFlags) -> UInt8 {
        var result: UInt8 = 0
        if flags.contains(.command) { result |= RemoteKey.command }
        if flags.contains(.shift) { result |= RemoteKey.shift }
        if flags.contains(.alternate) { result |= RemoteKey.option }
        if flags.contains(.control) { result |= RemoteKey.control }
        return result
    }

    private static let special: Set<UInt16> = [36, 48, 51, 53, 115, 116, 117, 119, 121, 123, 124, 125, 126]

    private static let codes: [UIKeyboardHIDUsage: UInt16] = [
        .keyboardA: 0, .keyboardB: 11, .keyboardC: 8, .keyboardD: 2, .keyboardE: 14,
        .keyboardF: 3, .keyboardG: 5, .keyboardH: 4, .keyboardI: 34, .keyboardJ: 38,
        .keyboardK: 40, .keyboardL: 37, .keyboardM: 46, .keyboardN: 45, .keyboardO: 31,
        .keyboardP: 35, .keyboardQ: 12, .keyboardR: 15, .keyboardS: 1, .keyboardT: 17,
        .keyboardU: 32, .keyboardV: 9, .keyboardW: 13, .keyboardX: 7, .keyboardY: 16, .keyboardZ: 6,
        .keyboard1: 18, .keyboard2: 19, .keyboard3: 20, .keyboard4: 21, .keyboard5: 23,
        .keyboard6: 22, .keyboard7: 26, .keyboard8: 28, .keyboard9: 25, .keyboard0: 29,
        .keyboardReturnOrEnter: 36, .keyboardTab: 48, .keyboardDeleteOrBackspace: 51,
        .keyboardEscape: 53, .keyboardSpacebar: 49, .keyboardHome: 115, .keyboardPageUp: 116,
        .keyboardDeleteForward: 117, .keyboardEnd: 119, .keyboardPageDown: 121, .keyboardLeftArrow: 123,
        .keyboardRightArrow: 124, .keyboardDownArrow: 125, .keyboardUpArrow: 126
    ]
}
