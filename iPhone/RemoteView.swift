import SwiftUI

struct RemoteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var session: Session
    @State private var keyboard = false
    @State private var zoomReset = 0
    @State private var controls = true

    init(pairing: Pairing) {
        _session = State(initialValue: Session(pairing: pairing))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                if controls { toolbar }
                ZStack {
                    RemoteSurface(session: session, display: session.display, trackpad: session.trackpad,
                                  zoomReset: zoomReset, showKeyboard: keyboard)
                        .allowsHitTesting(session.hasPicture)
                        .accessibilityLabel("Удалённый экран Mac")
                        .accessibilityHint("Касайтесь экрана для управления. Два пальца прокручивают страницу.")
                    if let error = session.error {
                        VStack(spacing: 12) {
                            Image(systemName: "wifi.slash").font(.title)
                            Text(error).multilineTextAlignment(.center)
                            Button("Повторить подключение") { session.connect() }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(24)
                    } else if !session.hasPicture {
                        ProgressView("Подключение к Mac…")
                    }
                }
                if keyboard { shortcuts }
            }
            if !controls {
                VStack {
                    Button {
                        controls = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline)
                            .frame(width: 56, height: 34)
                            .background(.regularMaterial, in: .capsule)
                    }
                    .accessibilityLabel("Показать панель управления")
                    Spacer()
                }
            }
            if let hint = session.hint {
                Text(hint)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: .capsule)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!controls)
        .onAppear { session.connect() }
        .onDisappear { session.disconnect() }
        .onChange(of: phase) { _, phase in
            if phase != .active { session.send(.releaseInputs) }
            if phase == .background {
                keyboard = false
                session.disconnect()
            } else if phase == .active && !session.hasPicture && session.error == nil {
                session.connectIfNeeded()
            }
        }
        .onChange(of: session.error) { _, error in
            if error != nil {
                keyboard = false
                controls = true
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 7) {
            Button {
                keyboard = false
                session.disconnect()
                dismiss()
            } label: {
                icon("xmark", label: "Завершить сеанс")
            }
            Spacer(minLength: 0)
            Text(session.pairing.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                session.trackpad.toggle()
            } label: {
                icon(session.trackpad ? "trackpad.fill" : "hand.tap", label: session.trackpad ? "Режим трекпада" : "Прямое касание")
            }
            .disabled(!session.hasPicture)
            Button {
                keyboard.toggle()
            } label: {
                icon(keyboard ? "keyboard.chevron.compact.down" : "keyboard", label: keyboard ? "Скрыть клавиатуру" : "Показать клавиатуру")
            }
            .disabled(!session.hasPicture)
            Menu {
                if let desktop = session.desktop, desktop.displays.count > 1 {
                    Menu("Экран Mac", systemImage: "display.2") {
                        ForEach(desktop.displays) { display in
                            Button {
                                session.select(display)
                            } label: {
                                Label(display.name, systemImage: display.id == desktop.selected ? "checkmark" : "display")
                            }
                        }
                    }
                }
                Button(session.sound ? "Выключить звук" : "Включить звук",
                       systemImage: session.sound ? "speaker.slash" : "speaker.wave.2") {
                    session.sound.toggle()
                }
                Button("Скопировать текст с Mac", systemImage: "document.on.document") {
                    session.send(.readClipboard)
                }
                PasteButton(payloadType: String.self) { strings in
                    if let string = strings.first { session.sendClipboard(string) }
                }
                .labelStyle(.titleAndIcon)
                Button("Сбросить масштаб", systemImage: "arrow.down.right.and.arrow.up.left") {
                    zoomReset += 1
                }
                Button("Скрыть панель", systemImage: "arrow.up.to.line") {
                    keyboard = false
                    controls = false
                }
            } label: {
                icon("ellipsis.circle", label: "Параметры сеанса")
            }
            .disabled(!session.hasPicture)
        }
        .padding(.horizontal, 10)
        .background(.bar)
    }

    private var shortcuts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                shortcut("Esc", 53)
                shortcut("Tab", 48)
                shortcut("←", 123)
                shortcut("↑", 126)
                shortcut("↓", 125)
                shortcut("→", 124)
                shortcut("⌘A", 0, RemoteKey.command)
                shortcut("⌘C", 8, RemoteKey.command)
                shortcut("⌘V", 9, RemoteKey.command)
                shortcut("⌘Z", 6, RemoteKey.command)
                shortcut("⌘Tab", 48, RemoteKey.command)
                shortcut("⌘␣", 49, RemoteKey.command)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func shortcut(_ title: String, _ code: UInt16, _ modifiers: UInt8 = 0) -> some View {
        Button(title) { session.send(.key(RemoteKey(code: code, modifiers: modifiers))) }
            .font(.system(.footnote, design: .monospaced).weight(.semibold))
            .frame(minWidth: 44, minHeight: 34)
            .padding(.horizontal, 4)
            .background(.white.opacity(0.13), in: .rect(cornerRadius: 8))
    }

    private func icon(_ symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 42, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }
}
