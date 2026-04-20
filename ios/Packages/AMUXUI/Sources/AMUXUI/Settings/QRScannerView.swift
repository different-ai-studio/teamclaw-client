import SwiftUI
import AVFoundation

#if os(iOS)

/// Minimal QR-code scanner backed by AVCaptureSession. Calls `onScanned`
/// once when a code is detected (scanning stops after the first match).
/// `onCancel` is invoked when the user taps Cancel.
struct QRScannerView: View {
    let onScanned: (String) -> Void
    let onCancel: () -> Void

    @State private var status: Status = .requestingAccess
    @State private var errorMessage: String?

    private enum Status {
        case requestingAccess
        case ready
        case denied
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch status {
            case .requestingAccess:
                ProgressView().tint(.white)
            case .denied:
                VStack(spacing: 12) {
                    Image(systemName: "camera.slash").font(.system(size: 48))
                    Text("Camera access denied")
                        .font(.headline)
                    Text("Enable the camera for AMUX in Settings to scan QR codes.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .foregroundStyle(.white)
            case .ready:
                QRCaptureRepresentable(onScanned: onScanned, onError: { errorMessage = $0 })
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text("Point the camera at the pairing QR code")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 32)
                }
            }

            VStack {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .padding(.leading, 16)
                    .padding(.top, 16)
                    Spacer()
                }
                Spacer()
            }

            if let errorMessage {
                VStack {
                    Spacer()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(10)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 80)
                }
            }
        }
        .task { await requestAccess() }
    }

    private func requestAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            status = .ready
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            status = granted ? .ready : .denied
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .denied
        }
    }
}

// MARK: - UIKit bridge

private struct QRCaptureRepresentable: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRCaptureViewController {
        let vc = QRCaptureViewController()
        vc.onScanned = onScanned
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ vc: QRCaptureViewController, context: Context) {}
}

private final class QRCaptureViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private nonisolated(unsafe) let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didDeliver = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onError?("Camera unavailable")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?("Unable to configure metadata capture")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didDeliver,
              let first = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = first.stringValue
        else { return }
        didDeliver = true
        session.stopRunning()
        onScanned?(value)
    }
}
#else
struct QRScannerView: View {
    let onScanned: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 40))
            Text("QR scanning is only available on iOS.")
                .font(.headline)
            Button("Close", action: onCancel)
        }
        .padding(24)
    }
}
#endif
