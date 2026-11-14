import AVFoundation
import SwiftUI
import UIKit

/// Scans the pairing QR code the computer shows (docs/01 US-3).
///
/// The camera is the same one `camera.capture` uses, so the permission text and
/// the refusal path are shared: if the user turned the camera off, this screen
/// says so once and offers Settings instead of asking again.
struct QRScannerView: View {
    /// Called once with the first decoded string; the caller decides what to do.
    let onCode: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var failure: String?

    var body: some View {
        Group {
            switch permission {
            case .authorized:
                scanner
            case .notDetermined:
                ProgressView("正在请求相机权限…")
                    .task { await requestAccess() }
            default:
                refusal
            }
        }
        .navigationTitle("扫一扫")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
        }
    }

    private var scanner: some View {
        ZStack {
            QRCameraView(onCode: handle, onFailure: { failure = $0 })
                .ignoresSafeArea()
            if let failure {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failure)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            } else {
                VStack {
                    Spacer()
                    Text("把电脑上显示的配对二维码放进框里")
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.white.opacity(0.85), lineWidth: 2)
                        .frame(width: 240, height: 240)
                }
            }
        }
    }

    private var refusal: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("相机权限已关闭")
                .font(.headline)
            Text("在「设置 > DSH > 相机」里打开后重试，或者直接粘贴配对链接。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button("打开设置") { UIApplication.shared.open(url) }
                    .buttonStyle(.borderedProminent)
            }
            Button("改用粘贴") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(24)
    }

    private func requestAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        permission = granted ? .authorized : .denied
    }

    private func handle(_ code: String) {
        onCode(code)
        dismiss()
    }
}

/// The camera preview plus the metadata session that decodes QR codes.
private struct QRCameraView: UIViewRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.start(in: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onFailure: onFailure)
    }

    /// Layer-backed view so the preview resizes with the view, not with a frame.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        private let onFailure: (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "io.example.dshmobile.qr")
        /// One code per presentation: a QR in frame would otherwise fire forever.
        private var delivered = false

        init(onCode: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
            self.onCode = onCode
            self.onFailure = onFailure
        }

        func start(in view: PreviewView) {
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill

            queue.async { [weak self] in
                guard let self else { return }
                guard let device = AVCaptureDevice.default(for: .video) else {
                    self.fail("这台设备没有可用的相机")
                    return
                }
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                    } else {
                        self.session.commitConfiguration()
                        self.fail("无法打开相机输入")
                        return
                    }
                    let output = AVCaptureMetadataOutput()
                    if self.session.canAddOutput(output) {
                        self.session.addOutput(output)
                        // Types can only be set after the output is attached.
                        output.setMetadataObjectsDelegate(self, queue: .main)
                        output.metadataObjectTypes = [.qr]
                    } else {
                        self.session.commitConfiguration()
                        self.fail("无法启用二维码识别")
                        return
                    }
                    self.session.commitConfiguration()
                    self.session.startRunning()
                } catch {
                    self.fail("无法启动相机：" + error.localizedDescription)
                }
            }
        }

        func stop() {
            queue.async { [session] in
                if session.isRunning {
                    session.stopRunning()
                }
            }
        }

        private func fail(_ message: String) {
            DispatchQueue.main.async { [onFailure] in
                onFailure(message)
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !delivered else { return }
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue,
                  !value.isEmpty else { return }
            delivered = true
            // Stopping the session blocks; keep it off the main queue.
            queue.async { [session] in session.stopRunning() }
            onCode(value)
        }
    }
}
