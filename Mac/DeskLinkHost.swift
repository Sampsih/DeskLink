import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@main
struct DeskLinkHost: App {
    static let windowID = "host"
    @State private var host = Host()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        Window("DeskLink для Mac", id: Self.windowID) {
            HostView(host: host)
                .frame(width: 470)
                .padding(26)
                .onAppear { host.refreshPermissions() }
                .onChange(of: phase) { _, phase in
                    if phase == .active { host.refreshPermissions() }
                }
        }
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentSize)

        MenuBarExtra("DeskLink", systemImage: "display") {
            StatusMenu(host: host)
        }
    }
}

private struct StatusMenu: View {
    @Environment(\.openWindow) private var openWindow
    let host: Host

    var body: some View {
        Text(host.status)
        Button("Показать окно", action: showWindow)
        Divider()
        if host.listening {
            Button("Выключить доступ") { host.stop() }
        } else {
            Button("Включить доступ") {
                host.start()
                if host.error != nil { showWindow() }
            }
        }
        Divider()
        Button("Завершить DeskLink") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        NSApp.activate()
        openWindow(id: DeskLinkHost.windowID)
    }
}

private struct HostView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable var host: Host
    @State private var confirmReset = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "display")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.indigo, in: .rect(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("DeskLink").font(.title.weight(.semibold))
                    Label(host.status, systemImage: "circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(host.listening ? Color.green : Color.secondary)
                }
                Spacer()
                Button(host.listening ? "Выключить доступ" : "Включить доступ") {
                    if host.listening { host.stop() } else { host.start() }
                }
                .buttonStyle(.borderedProminent)
            }
            Divider()
            if !host.screenAllowed || !host.inputAllowed {
                VStack(alignment: .leading, spacing: 10) {
                    permission("Запись экрана и звука", allowed: host.screenAllowed, action: host.requestScreen)
                    permission("Управление мышью и клавиатурой", allowed: host.inputAllowed, action: host.requestInput)
                    Text("После изменения разрешений может потребоваться перезапустить DeskLink.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if host.listening {
                LabeledContent("Адрес Mac") {
                    TextField("Имя или IP-адрес", text: $host.address)
                        .textFieldStyle(.roundedBorder)
                }
                if let code = host.pairing?.code, let qr = qrImage(code) {
                    HStack(alignment: .top, spacing: 18) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 144, height: 144)
                            .padding(8)
                            .background(.white, in: .rect(cornerRadius: 10))
                            .accessibilityLabel("QR-код подключения")
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Подключение iPhone").font(.headline)
                            Text("Откройте DeskLink на iPhone и отсканируйте QR-код. Устройство запомнит Mac.")
                                .foregroundStyle(.secondary)
                            Button(copied ? "Код скопирован" : "Скопировать код") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                                copied = true
                            }
                            .onChange(of: code) { _, _ in copied = false }
                            Button("Сменить ключ доступа") { confirmReset = true }
                        }
                    }
                }
            } else {
                Text("Включите доступ, чтобы подключиться с iPhone по Wi-Fi или через личную VPN.")
                    .foregroundStyle(.secondary)
            }
            if let error = host.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Свернуть в строку меню", systemImage: "arrow.up.to.line") {
                    dismissWindow(id: DeskLinkHost.windowID)
                }
            }
        }
        .alert("Сменить ключ доступа?", isPresented: $confirmReset) {
            Button("Отмена", role: .cancel) {}
            Button("Сменить", role: .destructive) { host.rotate() }
        } message: {
            Text("Текущий сеанс завершится. Все iPhone потребуется подключить заново.")
        }
    }

    private func permission(_ title: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: allowed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(allowed ? Color.green : Color.primary)
            Spacer()
            if !allowed { Button("Разрешить", action: action) }
        }
    }

    private func qrImage(_ code: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        guard let output = filter.outputImage,
              let bitmap = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: bitmap, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
