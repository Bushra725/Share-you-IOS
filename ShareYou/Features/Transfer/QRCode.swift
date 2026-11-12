import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins

/// Renders a QR code (on-device, Core Image).
struct QRCodeView: View {
    let text: String
    var body: some View {
        if let image = QRCodeView.make(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(Text("QR code to connect"))
        } else {
            Color.gray.opacity(0.2)
        }
    }

    static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Camera QR scanner (AVFoundation). Calls `onCode` once per distinct code.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var lastCode: String?
        private let sessionQueue = DispatchQueue(label: "shareyou.camera")

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
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
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let s = session
            sessionQueue.async { if !s.isRunning { s.startRunning() } }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let s = session
            sessionQueue.async { if s.isRunning { s.stopRunning() } }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let code = obj.stringValue, code != lastCode else { return }
            lastCode = code
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(code)
        }
    }
}

/// Camera permission gate around the scanner.
struct ScannerScreen: View {
    let onCode: (String) -> Void
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            switch status {
            case .authorized:
                QRScannerView(onCode: onCode)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24).stroke(Brand.cyan1, lineWidth: 4)
                            .frame(width: 240, height: 240)
                    )
            case .notDetermined:
                ProgressView().task {
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    status = granted ? .authorized : .denied
                }
            default:
                VStack(spacing: 12) {
                    EmptyStateView(icon: "camera.fill", title: "Camera access is off",
                                   message: "Allow the camera in Settings to scan the QR code on the other device.")
                    Button("Open Settings") { UIHelpers.openSettings() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
