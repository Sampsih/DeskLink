import Foundation
import Network
import Observation
import UIKit

@MainActor @Observable
final class Session {
    let pairing: Pairing
    let video = VideoPlayback()
    private let audio = AudioPlayback()
    private var wire: Wire?
    private var deadline: Task<Void, Never>?
    private(set) var desktop: Desktop?
    private(set) var hasPicture = false
    private(set) var error: String?
    private(set) var hint: String?
    var sound = true {
        didSet {
            wire?.send(.audioEnabled(sound))
            if !sound { audio.stop() }
        }
    }
    var trackpad = false

    var display: RemoteDisplay? {
        desktop?.displays.first { $0.id == desktop?.selected }
    }

    init(pairing: Pairing) {
        self.pairing = pairing
    }

    func connect() {
        disconnect()
        desktop = nil
        hasPicture = false
        error = nil
        hint = nil
        let address = pairing.host
        guard let port = NWEndpoint.Port(rawValue: pairing.port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: port,
                                      using: clientParameters(pin: pairing.fingerprint))
        let wire = Wire(connection)
        self.wire = wire
        wire.start(onReady: { [weak wire, token = pairing.token] in wire?.send(.authenticate(token)) },
                   onPacket: { [weak self, weak wire] type, data in
            DispatchQueue.main.async {
                guard let self, let wire, self.wire === wire else { return }
                self.receive(type, data)
            }
        }, onClose: { [weak self, weak wire] failure in
            DispatchQueue.main.async {
                guard let self, let wire, self.wire === wire else { return }
                self.error = failure == nil
                    ? "Mac закрыл соединение. Проверьте доступ и при необходимости отсканируйте новый код."
                    : "Не удалось связаться с Mac. Проверьте адрес, Wi-Fi и доступ DeskLink."
                self.disconnect()
            }
        })
        deadline = Task { [weak self, weak wire] in
            try? await Task.sleep(for: .seconds(14))
            guard !Task.isCancelled, let self, let wire, self.wire === wire, !self.hasPicture else { return }
            self.error = "Mac не передал изображение. Проверьте сеть и разрешения DeskLink на Mac."
            self.disconnect()
        }
    }

    func connectIfNeeded() {
        if wire == nil { connect() }
    }

    func disconnect() {
        deadline?.cancel()
        deadline = nil
        let previous = wire
        wire = nil
        previous?.cancel()
        hasPicture = false
        video.clear()
        audio.stop()
    }

    func send(_ command: Command) {
        wire?.send(command)
    }

    func select(_ screen: RemoteDisplay) {
        guard display?.id != screen.id else { return }
        wire?.send(.selectDisplay(screen.id))
    }

    func sendClipboard(_ string: String) {
        guard string.utf8.count <= 100_000 else {
            showHint("Буфер обмена слишком большой")
            return
        }
        send(.writeClipboard(string))
        showHint("Отправлено на Mac")
    }

    private func receive(_ type: PacketType, _ data: Data) {
        switch type {
        case .video:
            guard display != nil else { return }
            if video.show(data), !hasPicture {
                hasPicture = true
                deadline?.cancel()
            }
        case .audio:
            if sound && hasPicture { audio.play(data) }
        case .control:
            guard let command = try? JSONDecoder().decode(Command.self, from: data) else { return }
            switch command {
            case .desktop(let desktop):
                guard desktop.displays.contains(where: { $0.id == desktop.selected && $0.width > 0 && $0.height > 0 })
                else { return }
                self.desktop = desktop
                video.clear()
                hasPicture = false
                send(.audioEnabled(sound))
            case .failure(let message):
                error = message
                disconnect()
            case .clipboard(let text):
                UIPasteboard.general.string = text
                showHint("Скопировано с Mac")
            default:
                break
            }
        }
    }

    private func showHint(_ message: String) {
        hint = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.hint == message { self?.hint = nil }
        }
    }
}
