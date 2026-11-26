import AppKit
import ApplicationServices
import Foundation
import Network
import Observation
import ScreenCaptureKit
import SystemConfiguration

@MainActor @Observable
final class Host {
    static let port: UInt16 = 49169
    private(set) var status = "Доступ выключен"
    private(set) var error: String?
    private(set) var pairing: Pairing?
    private(set) var screenAllowed = false
    private(set) var inputAllowed = false
    private(set) var listening = false
    private(set) var active = false
    var address = (SCDynamicStoreCopyLocalHostName(nil) as String? ?? "Mac") + ".local" {
        didSet { updatePairing() }
    }

    private var identity: HostIdentity?
    private var listener: NWListener?
    private var candidates: [UUID: Wire] = [:]
    private var sessionID: UUID?
    private var stream: ScreenStream?
    private var captureTask: Task<Void, Never>?
    private var displays: [SCDisplay] = []
    private var selected: UInt32?
    private var audioEnabled = true
    private let input = RemoteInput()

    func refreshPermissions() {
        screenAllowed = CGPreflightScreenCaptureAccess()
        inputAllowed = AXIsProcessTrusted()
    }

    func requestScreen() {
        _ = CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
        refreshPermissions()
    }

    func requestInput() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
        refreshPermissions()
    }

    func start() {
        guard listener == nil else { return }
        refreshPermissions()
        guard screenAllowed, inputAllowed else {
            error = "Разрешите запись экрана и управление Mac, затем включите доступ."
            return
        }
        do {
            let identity = try self.identity ?? HostIdentity()
            self.identity = identity
            let listener = try NWListener(using: identity.parameters(), on: NWEndpoint.Port(rawValue: Self.port)!)
            self.listener = listener
            error = nil
            status = "Запуск"
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                DispatchQueue.main.async {
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.listening = true
                        self.status = "Готов к подключению"
                        self.updatePairing()
                    case .failed(let error):
                        self.stop()
                        self.error = error.localizedDescription
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                DispatchQueue.main.async {
                    guard let self, let listener, self.listener === listener else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }
            listener.start(queue: DispatchQueue(label: "DeskLink.listener"))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listening = false
        pairing = nil
        for wire in candidates.values { wire.cancel() }
        candidates.removeAll()
        endSession()
        status = "Доступ выключен"
        error = nil
    }

    func rotate() {
        guard identity != nil else { return }
        do {
            try identity?.rotateToken()
            for wire in candidates.values { wire.cancel() }
            candidates.removeAll()
            endSession()
            updatePairing()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func updatePairing() {
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard listening, let identity else { return }
        let newPairing = Pairing(name: HostName.display, host: host, port: Self.port,
                                 fingerprint: identity.fingerprint, token: identity.token)
        pairing = newPairing.isValid ? newPairing : nil
    }

    private func accept(_ connection: NWConnection) {
        guard candidates.count < 8 else {
            connection.cancel()
            return
        }
        let id = UUID()
        let wire = Wire(connection)
        candidates[id] = wire
        wire.start(onPacket: { [weak self] type, data in
            let command = type == .control ? try? JSONDecoder().decode(Command.self, from: data) : nil
            DispatchQueue.main.async { self?.handle(command, from: id) }
        }, onClose: { [weak self] _ in
            DispatchQueue.main.async {
                self?.candidates[id] = nil
                if self?.sessionID == id { self?.endSession() }
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.sessionID != id else { return }
            self.candidates.removeValue(forKey: id)?.cancel()
        }
    }

    private func handle(_ command: Command?, from id: UUID) {
        guard let wire = candidates[id] else { return }
        guard let command else { wire.cancel(); return }
        guard sessionID == id else {
            guard case .authenticate(let token) = command, identity?.matches(token) == true else {
                wire.cancel()
                return
            }
            guard sessionID == nil else {
                wire.send(.failure("Mac уже управляется с другого устройства.")) { wire.cancel() }
                return
            }
            sessionID = id
            audioEnabled = true
            active = true
            status = "iPhone подключён"
            error = nil
            startCapture(wire: wire, id: id, displayID: nil)
            return
        }

        switch command {
        case .selectDisplay(let display) where display != selected:
            guard displays.contains(where: { $0.displayID == display }) else { return }
            input.release()
            selected = nil
            startCapture(wire: wire, id: id, displayID: display)
        case .pointer(let pointer) where pointer.display == selected:
            input.pointer(pointer)
        case .scroll(let delta) where selected != nil:
            input.scroll(delta)
        case .key(let key) where selected != nil:
            input.key(key)
        case .text(let text) where selected != nil:
            input.text(text)
        case .writeClipboard(let text):
            guard text.utf8.count <= 100_000 else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .readClipboard:
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            if text.utf8.count <= 100_000 { wire.send(.clipboard(text)) }
        case .audioEnabled(let enabled):
            audioEnabled = enabled
            stream?.setAudio(enabled)
        case .releaseInputs:
            input.release()
        default:
            break
        }
    }

    private func startCapture(wire: Wire, id: UUID, displayID: UInt32?) {
        let previous = captureTask
        previous?.cancel()
        let old = stream
        stream = nil
        captureTask = Task { [weak self] in
            await previous?.value
            await old?.stop()
            guard let self, !Task.isCancelled, self.sessionID == id else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !Task.isCancelled, self.sessionID == id else { return }
                let displays = content.displays
                let target = displayID ?? CGMainDisplayID()
                guard let display = displays.first(where: { $0.displayID == target }) ?? displays.first else {
                    throw DeskError.system("Mac не обнаружил экран для трансляции.")
                }
                let details = displays.enumerated().map { index, screen in
                    let name = NSScreen.screens.first {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                            == screen.displayID
                    }?.localizedName ?? "Экран \(index + 1)"
                    return RemoteDisplay(id: screen.displayID, name: name, width: screen.width, height: screen.height)
                }
                self.displays = displays
                self.selected = display.displayID
                let capture = ScreenStream(wire: wire) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self, self.sessionID == id, self.selected == display.displayID else { return }
                        self.abort(wire: wire, message: error.localizedDescription)
                    }
                }
                self.stream = capture
                wire.send(.desktop(Desktop(displays: details, selected: display.displayID)))
                try await capture.start(display: display, audio: self.audioEnabled)
                capture.setAudio(self.audioEnabled)
                if Task.isCancelled { await capture.stop() }
            } catch {
                if !Task.isCancelled, self.sessionID == id {
                    self.abort(wire: wire, message: "Экран Mac недоступен. \(error.localizedDescription)")
                }
            }
        }
    }

    private func abort(wire: Wire, message: String) {
        error = message
        wire.send(.failure(message)) { wire.cancel() }
    }

    private func endSession() {
        sessionID = nil
        selected = nil
        displays = []
        active = false
        input.release()
        let previous = captureTask
        previous?.cancel()
        let old = stream
        stream = nil
        captureTask = Task {
            await previous?.value
            await old?.stop()
        }
        if listening { status = "Готов к подключению" }
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private enum HostName {
    static var display: String {
        String((Foundation.Host.current().localizedName ?? "Мой Mac").prefix(50))
    }
}
