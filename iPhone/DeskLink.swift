import AVFoundation
import SwiftUI

@main
struct DeskLink: App {
    var body: some Scene {
        WindowGroup { ConnectionsView() }
    }
}

private struct ConnectionsView: View {
    @State private var store = ProfileStore()
    @State private var selected: Pairing?
    @State private var editing: Pairing?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if store.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 13) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 63, height: 63)
                            .background(.indigo, in: .rect(cornerRadius: 18))
                            .accessibilityHidden(true)
                        Text("Ваш Mac на iPhone")
                            .font(.title2.bold())
                        Text("Включите доступ в DeskLink на Mac и отсканируйте QR-код.")
                            .foregroundStyle(.secondary)
                        Button("Добавить Mac", systemImage: "qrcode.viewfinder") { adding = true }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                } else {
                    Section("Сохранённые Mac") {
                        ForEach(store.profiles) { pairing in
                            Button {
                                selected = pairing
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.title3.weight(.semibold))
                                        .frame(width: 44, height: 44)
                                        .foregroundStyle(.indigo)
                                        .background(.indigo.opacity(0.12), in: .rect(cornerRadius: 11))
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(pairing.name).font(.headline).foregroundStyle(.primary)
                                        Text(pairing.host).font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Изменить адрес", systemImage: "pencil") { editing = pairing }
                                Button("Удалить Mac", systemImage: "trash", role: .destructive) { store.remove(pairing) }
                            }
                            .swipeActions {
                                Button("Удалить", systemImage: "trash", role: .destructive) { store.remove(pairing) }
                                Button("Адрес", systemImage: "pencil") { editing = pairing }
                            }
                        }
                    }
                }
            }
            .navigationTitle("DeskLink")
            .toolbar {
                if !store.profiles.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Добавить Mac", systemImage: "plus") { adding = true }
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .tint(.indigo)
        .sheet(isPresented: $adding) {
            PairView { pairing in
                guard store.save(pairing) else { return }
                adding = false
            }
        }
        .sheet(item: $editing) { pairing in
            EditAddress(pairing: pairing) { updated in
                if store.save(updated) { editing = nil }
            }
            .presentationDetents([.medium])
        }
        .fullScreenCover(item: $selected) { RemoteView(pairing: $0) }
        .alert("Хранилище подключений", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) {
            Button("ОК") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }
}

private struct EditAddress: View {
    @Environment(\.dismiss) private var dismiss
    @State var pairing: Pairing
    let save: (Pairing) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Имя или IP-адрес Mac", text: $pairing.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityLabel("Адрес Mac")
            }
            .navigationTitle("Адрес Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save(pairing) }.disabled(!pairing.isValid)
                }
            }
        }
    }
}

private struct PairView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var manual = false
    @State private var code = ""
    let add: (Pairing) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if manual {
                    TextEditor(text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 110)
                        .padding(8)
                        .overlay(.quaternary, in: .rect(cornerRadius: 12).stroke(lineWidth: 1))
                        .accessibilityLabel("Код подключения")
                    Button("Добавить Mac") { accept(code) }
                        .buttonStyle(.borderedProminent)
                        .disabled(code.isEmpty)
                } else {
                    Scanner { accept($0) } onFailure: { message in
                        error = message
                        manual = true
                    }
                    .frame(maxHeight: 360)
                    .clipShape(.rect(cornerRadius: 20))
                    .overlay {
                        RoundedRectangle(cornerRadius: 17)
                            .strokeBorder(.white.opacity(0.8), lineWidth: 2)
                            .frame(width: 200, height: 200)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Камера для сканирования")
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button(manual ? "Сканировать QR-код" : "Ввести код вручную") {
                    manual.toggle()
                    error = nil
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Добавить Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }

    private func accept(_ code: String) {
        guard let pairing = Pairing(code: code) else {
            error = "Нужен код подключения из DeskLink на Mac."
            return
        }
        error = nil
        add(pairing)
    }
}

private struct Scanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
        controller.onFailure = onFailure
    }
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let capture = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label: "DeskLink.camera", qos: .userInitiated)
    private var preview: AVCaptureVideoPreviewLayer?
    private var visible = false
    private var lastCode: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        lastCode = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.visible else { return }
                    if allowed { self.start() } else { self.fail() }
                }
            }
        default: fail()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        cameraQueue.async { [capture] in capture.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        if let connection = preview?.connection {
            let angle: CGFloat = switch view.window?.windowScene?.interfaceOrientation {
            case .landscapeLeft: 0
            case .landscapeRight: 180
            case .portraitUpsideDown: 270
            default: 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }

    private func start() {
        if preview == nil {
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera), capture.canAddInput(input) else {
                fail()
                return
            }
            let output = AVCaptureMetadataOutput()
            capture.addInput(input)
            guard capture.canAddOutput(output) else { fail(); return }
            capture.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: capture)
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            self.preview = preview
            view.setNeedsLayout()
        }
        cameraQueue.async { [capture] in capture.startRunning() }
    }

    private func fail() {
        onFailure?("Камера недоступна. Вставьте код из DeskLink на Mac.")
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard visible, let symbol = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = symbol.stringValue, code != lastCode else { return }
        lastCode = code
        onCode?(code)
    }
}
