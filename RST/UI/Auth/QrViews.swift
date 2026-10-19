import AVFoundation
import CoreImage.CIFilterBuiltins
import CryptoKit
import SwiftUI
import UIKit

extension QrLogin.Link: Identifiable {
    var id: String { session }
}

/// Картинка QR-кода.
struct QrCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(Theme.muted)
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Новое устройство: показать код и ждать

/// Вход без пароля: код сканируют на телефоне, где уже вошли; приватный
/// ключ приходит оттуда зашифрованным одноразовым общим ключом.
struct QrLoginSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var link: String?
    @State private var status = "Готовим код…"
    @State private var failed = false
    @State private var expired = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.white)
                    if let link {
                        QrCodeImage(text: link).padding(14).opacity(expired ? 0.25 : 1)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 250, height: 250)
                Text(status)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(failed ? Theme.danger : Theme.onSurface)
                    .multilineTextAlignment(.center)
                Text("Откройте RST там, где вы уже вошли: «Настройки → Устройства → Подтвердить вход по QR-коду» — и наведите камеру на этот код.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                if failed || expired {
                    Button("Новый код") { attempt += 1 }.buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding(24)
            .background(AppBackground())
            .navigationTitle("Вход по QR-коду")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .task(id: attempt) { await run() }
        }
    }

    private func run() async {
        link = nil
        failed = false
        expired = false
        status = "Готовим код…"
        let pair = P256.KeyAgreement.PrivateKey()
        let pub = QrLogin.rawPublic(pair.publicKey)
        let start: QrStartResponse
        do {
            start = try await services.api.qrStart(pub: pub)
        } catch {
            status = errorText(error)
            failed = true
            return
        }
        link = QrLogin.link(base: services.api.baseURL, session: start.session, pub: pub)
        status = "Ждём подтверждения на телефоне…"
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            let poll: QrPollResponse
            do {
                poll = try await services.api.qrPoll(session: start.session, secret: start.secret)
            } catch let error as ApiError where error.code == 410 {
                status = "Код устарел"
                expired = true
                return
            } catch {
                continue   // сеть мигнула — ещё раз
            }
            switch poll.status {
            case "pending":
                continue
            case "denied":
                status = "Вход отклонён на телефоне"
                failed = true
                return
            default:
                status = "Вход подтверждён, открываю…"
                do {
                    guard let approver = poll.approverPub, let payload = poll.payload else { throw CryptoError("Пришёл неполный ответ") }
                    let jwk = try QrLogin.open(mine: pair, approverPub: approver, payload: payload)
                    try services.auth.finishQrLogin(poll, privateJwk: jwk)
                    dismiss()
                    app.enterApp()
                } catch {
                    status = errorText(error)
                    failed = true
                }
                return
            }
        }
    }
}

// MARK: - Вошедшее устройство: сканировать и подтвердить

/// Сканер QR-кода камерой.
struct QrScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var reported = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !reported, let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            reported = true
            onCode?(code)
        }
    }
}

/// Подтверждение входа: сканер (если код ещё не известен), затем окно с
/// устройством, адресом и предупреждением о мошенниках.
struct QrApproveSheet: View {
    @State var link: QrLogin.Link?
    @Environment(Services.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var info: QrInfoResponse?
    @State private var error: String?
    @State private var done: String?
    @State private var busy = false
    @State private var cameraAllowed: Bool?

    var body: some View {
        NavigationStack {
            Group {
                if let done {
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Theme.success)
                        Text(done).multilineTextAlignment(.center)
                        Button("Готово") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                } else if let link {
                    confirm(link)
                } else if cameraAllowed == false {
                    Text("Нет доступа к камере. Разрешите её в Настройках → RST.")
                        .foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(24)
                } else {
                    ZStack(alignment: .bottom) {
                        QrScannerView { code in
                            if let parsed = QrLogin.parse(code) {
                                link = parsed
                            } else {
                                error = "Это не код входа в RST"
                            }
                        }
                        .ignoresSafeArea()
                        Text(error ?? "Наведите камеру на QR-код на экране нового устройства")
                            .font(.system(size: 14)).foregroundStyle(.white)
                            .padding(12).background(Capsule().fill(Color.black.opacity(0.6)))
                            .padding(.bottom, 30)
                    }
                }
            }
            .navigationTitle("Вход на другом устройстве")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .task {
                if link == nil { cameraAllowed = await AVCaptureDevice.requestAccess(for: .video) }
            }
            .task(id: link?.session) {
                guard let link else { return }
                do {
                    info = try await services.api.qrInfo(session: link.session)
                } catch {
                    self.error = errorText(error)
                }
            }
        }
    }

    private func confirm(_ link: QrLogin.Link) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "exclamationmark.shield.fill").font(.system(size: 40)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                if let info {
                    Text("Войти на другом устройстве?").font(.system(size: 20, weight: .bold))
                    Text("\(info.device ?? "Устройство") · адрес \(info.ip ?? "неизвестен")")
                        .font(.system(size: 15, weight: .medium))
                    Text("Новое устройство получит доступ ко всей переписке. Подтверждайте, только если вы сами сейчас входите и видите этот код на его экране. Если код вам прислали или попросили отсканировать — это мошенники.")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    Button {
                        approve(link)
                    } label: {
                        Text("Подтвердить вход").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    Button(role: .destructive) {
                        Task { try? await services.api.qrDeny(session: link.session) }
                        dismiss()
                    } label: {
                        Text("Отклонить").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else if let error {
                    Text(error).foregroundStyle(Theme.danger)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    private func approve(_ link: QrLogin.Link) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await services.auth.approveQrLogin(link)
                done = "Вход подтверждён: \(info?.device ?? "устройство")"
            } catch {
                self.error = errorText(error)
                info = nil
            }
        }
    }
}
