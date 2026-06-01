import UIKit
import AVFoundation
import AudioToolbox

// CDVPlugin / CDVInvokedUrlCommand / CDVPluginResult resolved via the app's
// Cordova bridging header — do NOT `import Cordova` (project convention).

@objc(JunctionScanner) class JunctionScanner: CDVPlugin {

    private var pendingCallbackId: String?

    // MARK: - isAvailable

    @objc(isAvailable:)
    func isAvailable(command: CDVInvokedUrlCommand) {
        let available = AVCaptureDevice.default(for: .video) != nil
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: available)
        self.commandDelegate.send(result, callbackId: command.callbackId)
    }

    // MARK: - scan

    @objc(scan:)
    func scan(command: CDVInvokedUrlCommand) {
        self.pendingCallbackId = command.callbackId

        let formatsCsv  = (command.arguments.first as? String) ?? "QR_CODE,DATA_MATRIX"
        let torchOn     = (command.arguments.count > 1 ? command.arguments[1] as? Bool : false) ?? false
        let frontCamera = (command.arguments.count > 2 ? command.arguments[2] as? Bool : false) ?? false
        let prompt      = (command.arguments.count > 3 ? command.arguments[3] as? String : "") ?? ""

        // Camera permission: AVFoundation prompts using NSCameraUsageDescription.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.present(formatsCsv, torchOn, frontCamera, prompt)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    granted ? self.present(formatsCsv, torchOn, frontCamera, prompt)
                            : self.sendError("camera_permission_denied")
                }
            }
        default:
            self.sendError("camera_permission_denied")
        }
    }

    private func present(_ formatsCsv: String, _ torchOn: Bool, _ frontCamera: Bool, _ prompt: String) {
        DispatchQueue.main.async {
            let vc = ScannerViewController()
            vc.formatsCsv  = formatsCsv
            vc.startTorch  = torchOn
            vc.useFront    = frontCamera
            vc.promptText  = prompt
            vc.onResult    = { [weak self] text, format in
                self?.sendOk(text: text, format: format, cancelled: false)
            }
            vc.onCancel    = { [weak self] in
                self?.sendOk(text: "", format: "", cancelled: true)
            }
            vc.onError     = { [weak self] msg in
                self?.sendError(msg)
            }
            vc.modalPresentationStyle = .fullScreen
            self.viewController.present(vc, animated: true, completion: nil)
        }
    }

    // MARK: - Result helpers

    private func sendOk(text: String, format: String, cancelled: Bool) {
        guard let cbId = pendingCallbackId else { return }
        let payload: [String: Any] = ["text": text, "format": format, "cancelled": cancelled]
        let result = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: payload)
        self.commandDelegate.send(result, callbackId: cbId)
        pendingCallbackId = nil
    }

    private func sendError(_ message: String) {
        guard let cbId = pendingCallbackId else { return }
        let result = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: message)
        self.commandDelegate.send(result, callbackId: cbId)
        pendingCallbackId = nil
    }
}

// MARK: - ScannerViewController

/// Full-screen AVFoundation scanner with a branded overlay (dimmed mask, reticle
/// corner brackets, animated scan-line) plus torch and close controls.
class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    var formatsCsv = "QR_CODE,DATA_MATRIX"
    var startTorch = false
    var useFront    = false
    var promptText  = ""

    var onResult: ((String, String) -> Void)?
    var onCancel: (() -> Void)?
    var onError:  ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var device: AVCaptureDevice?
    private var delivered = false

    private let accent = UIColor(red: 0x22/255, green: 0xD3/255, blue: 0xA6/255, alpha: 1) // #22D3A6
    private var reticleRect: CGRect = .zero
    private let scanLine = CALayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSession()
        setupOverlay()
        setupControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        layoutOverlay()
    }

    // MARK: Session

    private func setupSession() {
        let position: AVCaptureDevice.Position = useFront ? .front : .back
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: cam) else {
            onError?("camera_unavailable"); dismissSelf(); return
        }
        device = cam

        if session.canAddInput(input) { session.addInput(input) }

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = mapFormats(formatsCsv, available: metadataOutput.availableMetadataObjectTypes)
        } else {
            onError?("metadata_output_unavailable"); dismissSelf(); return
        }

        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)

        if startTorch { setTorch(true) }
    }

    private func mapFormats(_ csv: String, available: [AVMetadataObject.ObjectType]) -> [AVMetadataObject.ObjectType] {
        let lookup: [String: AVMetadataObject.ObjectType] = [
            "QR_CODE": .qr, "DATA_MATRIX": .dataMatrix, "EAN_13": .ean13, "EAN_8": .ean8,
            "CODE_128": .code128, "CODE_39": .code39, "CODE_93": .code93, "ITF": .itf14,
            "UPC_E": .upce, "PDF_417": .pdf417, "AZTEC": .aztec, "CODABAR": .init(rawValue: "org.iso.Codabar")
        ]
        // UPC_A is reported as EAN-13 on iOS; include EAN-13 when UPC_A requested.
        var wanted: [AVMetadataObject.ObjectType] = []
        for token in csv.split(separator: ",") {
            let key = token.trimmingCharacters(in: .whitespaces).uppercased()
            if key == "UPC_A" { wanted.append(.ean13); continue }
            if let t = lookup[key] { wanted.append(t) }
        }
        let filtered = wanted.filter { available.contains($0) }
        return filtered.isEmpty ? available : Array(Set(filtered))
    }

    // MARK: Overlay

    private func setupOverlay() {
        // Dimmed mask with a clear reticle is rendered in layoutOverlay via a mask layer.
        scanLine.backgroundColor = accent.cgColor
        scanLine.cornerRadius = 1.5
        view.layer.addSublayer(scanLine)
    }

    private func layoutOverlay() {
        let side = min(view.bounds.width, view.bounds.height) * 0.70
        let cx = view.bounds.midX
        let cy = view.bounds.height * 0.45
        reticleRect = CGRect(x: cx - side/2, y: cy - side/2, width: side, height: side)

        // Remove previous overlay sublayers (tagged by name) before redraw.
        view.layer.sublayers?.filter { $0.name == "jx-overlay" }.forEach { $0.removeFromSuperlayer() }

        // Dim mask with reticle hole.
        let dim = CAShapeLayer()
        dim.name = "jx-overlay"
        let path = UIBezierPath(rect: view.bounds)
        path.append(UIBezierPath(roundedRect: reticleRect, cornerRadius: 20).reversing())
        dim.path = path.cgPath
        dim.fillColor = UIColor.black.withAlphaComponent(0.6).cgColor
        view.layer.insertSublayer(dim, above: previewLayer)

        // Corner brackets.
        let corners = CAShapeLayer()
        corners.name = "jx-overlay"
        corners.path = cornersPath().cgPath
        corners.strokeColor = accent.cgColor
        corners.fillColor = UIColor.clear.cgColor
        corners.lineWidth = 4
        corners.lineCap = .round
        view.layer.insertSublayer(corners, above: dim)

        // Scan-line animation.
        scanLine.frame = CGRect(x: reticleRect.minX + 6, y: reticleRect.minY + 8,
                                width: reticleRect.width - 12, height: 3)
        addScanAnimation()
    }

    private func cornersPath() -> UIBezierPath {
        let r = reticleRect
        let len: CGFloat = 28
        let rad: CGFloat = 20
        let p = UIBezierPath()
        // Top-left
        p.move(to: CGPoint(x: r.minX, y: r.minY + len))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY), controlPoint: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + len, y: r.minY))
        // Top-right
        p.move(to: CGPoint(x: r.maxX - len, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + rad), controlPoint: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + len))
        // Bottom-right
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - len))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.maxX - rad, y: r.maxY), controlPoint: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - len, y: r.maxY))
        // Bottom-left
        p.move(to: CGPoint(x: r.minX + len, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rad), controlPoint: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - len))
        return p
    }

    private func addScanAnimation() {
        scanLine.removeAnimation(forKey: "sweep")
        let anim = CABasicAnimation(keyPath: "position.y")
        anim.fromValue = reticleRect.minY + 8
        anim.toValue   = reticleRect.maxY - 8
        anim.duration  = 1.8
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        scanLine.add(anim, forKey: "sweep")
    }

    // MARK: Controls

    private func setupControls() {
        let close = UIButton(type: .system)
        close.setTitle("✕", for: .normal)
        close.setTitleColor(.white, for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 26)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(close)

        let torch = UIButton(type: .system)
        torch.setTitle("⚡", for: .normal)
        torch.setTitleColor(.white, for: .normal)
        torch.titleLabel?.font = .systemFont(ofSize: 26)
        torch.translatesAutoresizingMaskIntoConstraints = false
        torch.addTarget(self, action: #selector(torchTapped), for: .touchUpInside)
        view.addSubview(torch)

        let hint = UILabel()
        hint.text = promptText
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 15)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),

            torch.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            torch.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            torch.widthAnchor.constraint(equalToConstant: 44),
            torch.heightAnchor.constraint(equalToConstant: 44),

            hint.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 32),
            hint.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -32),
            hint.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -80),
        ])
    }

    @objc private func closeTapped() {
        stopSession()
        dismiss(animated: true) { [weak self] in self?.onCancel?() }
    }

    @objc private func torchTapped() {
        guard let d = device, d.hasTorch else { return }
        setTorch(d.torchMode == .off)
    }

    private func setTorch(_ on: Bool) {
        guard let d = device, d.hasTorch else { return }
        try? d.lockForConfiguration()
        d.torchMode = on ? .on : .off
        d.unlockForConfiguration()
    }

    // MARK: Metadata delegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !delivered,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue, !value.isEmpty else { return }
        delivered = true
        AudioServicesPlaySystemSound(1057) // brief tick on detection
        stopSession()
        let format = formatName(obj.type)
        dismiss(animated: true) { [weak self] in self?.onResult?(value, format) }
    }

    private func formatName(_ type: AVMetadataObject.ObjectType) -> String {
        switch type {
        case .qr: return "QR_CODE"
        case .dataMatrix: return "DATA_MATRIX"
        case .ean13: return "EAN_13"
        case .ean8: return "EAN_8"
        case .code128: return "CODE_128"
        case .code39: return "CODE_39"
        case .code93: return "CODE_93"
        case .itf14: return "ITF"
        case .upce: return "UPC_E"
        case .pdf417: return "PDF_417"
        case .aztec: return "AZTEC"
        default: return "UNKNOWN"
        }
    }

    // MARK: Teardown

    private func stopSession() {
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
        }
    }

    private func dismissSelf() {
        DispatchQueue.main.async { self.dismiss(animated: true, completion: nil) }
    }
}
