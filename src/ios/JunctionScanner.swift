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

    // Brand palette
    private let navyBg   = UIColor(red: 10/255,  green: 15/255,  blue: 30/255,  alpha: 1)  // #0A0F1E
    private let accent   = UIColor(red: 34/255,  green: 211/255, blue: 166/255, alpha: 1)  // #22D3A6
    private let glassReg = UIColor(white: 1, alpha: 0.10)
    private let glassBdr = UIColor(white: 1, alpha: 0.18)

    private var reticleRect: CGRect = .zero
    private let scanLine   = CALayer()
    private let glowLine   = CALayer()
    private var torchBtn: UIButton?
    private var torchOn = false

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = navyBg
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

        torchOn = startTorch
        if startTorch { setTorch(true) }
    }

    private func mapFormats(_ csv: String, available: [AVMetadataObject.ObjectType]) -> [AVMetadataObject.ObjectType] {
        let lookup: [String: AVMetadataObject.ObjectType] = [
            "QR_CODE": .qr, "DATA_MATRIX": .dataMatrix, "EAN_13": .ean13, "EAN_8": .ean8,
            "CODE_128": .code128, "CODE_39": .code39, "CODE_93": .code93, "ITF": .itf14,
            "UPC_E": .upce, "PDF_417": .pdf417, "AZTEC": .aztec,
            "CODABAR": .init(rawValue: "org.iso.Codabar")
        ]
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
        // Glow layer sits behind the visible scan-line, wider and more diffuse.
        glowLine.opacity = 0.45
        glowLine.cornerRadius = 3
        view.layer.addSublayer(glowLine)

        scanLine.backgroundColor = accent.cgColor
        scanLine.cornerRadius = 2
        scanLine.shadowColor  = accent.cgColor
        scanLine.shadowOffset = .zero
        scanLine.shadowRadius = 6
        scanLine.shadowOpacity = 0.9
        view.layer.addSublayer(scanLine)
    }

    private func layoutOverlay() {
        let side = min(view.bounds.width, view.bounds.height) * 0.70
        let cx = view.bounds.midX
        let cy = view.bounds.height * 0.45
        reticleRect = CGRect(x: cx - side/2, y: cy - side/2, width: side, height: side)

        // Remove previous named overlay sublayers.
        view.layer.sublayers?.filter { $0.name == "jx-overlay" }.forEach { $0.removeFromSuperlayer() }

        // Navy-tinted dim mask with reticle hole.
        let dim = CAShapeLayer()
        dim.name = "jx-overlay"
        let path = UIBezierPath(rect: view.bounds)
        path.append(UIBezierPath(roundedRect: reticleRect, cornerRadius: 20).reversing())
        dim.path = path.cgPath
        dim.fillColor = UIColor(red: 10/255, green: 15/255, blue: 30/255, alpha: 0.78).cgColor
        view.layer.insertSublayer(dim, above: previewLayer)

        // Subtle inner glow ring (just inside reticle edge).
        let glowRing = CAShapeLayer()
        glowRing.name = "jx-overlay"
        let inset: CGFloat = 1
        glowRing.path = UIBezierPath(roundedRect: reticleRect.insetBy(dx: inset, dy: inset), cornerRadius: 19).cgPath
        glowRing.fillColor = UIColor.clear.cgColor
        glowRing.strokeColor = accent.withAlphaComponent(0.15).cgColor
        glowRing.lineWidth = 2
        glowRing.shadowColor = accent.cgColor
        glowRing.shadowOffset = .zero
        glowRing.shadowRadius = 8
        glowRing.shadowOpacity = 0.4
        view.layer.insertSublayer(glowRing, above: dim)

        // Corner brackets with neon glow.
        let cornersGlow = CAShapeLayer()
        cornersGlow.name = "jx-overlay"
        cornersGlow.path = cornersPath().cgPath
        cornersGlow.strokeColor = accent.withAlphaComponent(0.6).cgColor
        cornersGlow.fillColor = UIColor.clear.cgColor
        cornersGlow.lineWidth = 8
        cornersGlow.lineCap = .round
        cornersGlow.shadowColor = accent.cgColor
        cornersGlow.shadowOffset = .zero
        cornersGlow.shadowRadius = 10
        cornersGlow.shadowOpacity = 1.0
        view.layer.insertSublayer(cornersGlow, above: glowRing)

        let corners = CAShapeLayer()
        corners.name = "jx-overlay"
        corners.path = cornersPath().cgPath
        corners.strokeColor = accent.cgColor
        corners.fillColor = UIColor.clear.cgColor
        corners.lineWidth = 3.5
        corners.lineCap = .round
        view.layer.insertSublayer(corners, above: cornersGlow)

        // Corner dots — filled accent circles at each reticle corner.
        addCornerDots(above: corners)

        // Glow band (wider, behind scan-line).
        glowLine.backgroundColor = accent.withAlphaComponent(0.3).cgColor
        glowLine.frame = CGRect(x: reticleRect.minX + 4, y: reticleRect.minY + 8,
                                width: reticleRect.width - 8, height: 12)

        // Scan-line.
        scanLine.frame = CGRect(x: reticleRect.minX + 6, y: reticleRect.minY + 8,
                                width: reticleRect.width - 12, height: 4)

        addScanAnimation()
    }

    private func addCornerDots(above layer: CALayer) {
        let dotR: CGFloat = 5
        let offsets: [(CGFloat, CGFloat)] = [
            (reticleRect.minX, reticleRect.minY),
            (reticleRect.maxX, reticleRect.minY),
            (reticleRect.maxX, reticleRect.maxY),
            (reticleRect.minX, reticleRect.maxY),
        ]
        for (cx, cy) in offsets {
            let dot = CALayer()
            dot.name = "jx-overlay"
            dot.bounds = CGRect(x: 0, y: 0, width: dotR * 2, height: dotR * 2)
            dot.position = CGPoint(x: cx, y: cy)
            dot.cornerRadius = dotR
            dot.backgroundColor = accent.cgColor
            dot.shadowColor = accent.cgColor
            dot.shadowOffset = .zero
            dot.shadowRadius = 4
            dot.shadowOpacity = 0.9
            view.layer.insertSublayer(dot, above: layer)
        }
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
        let anim = CABasicAnimation(keyPath: "position.y")
        anim.fromValue = reticleRect.minY + 8
        anim.toValue   = reticleRect.maxY - 8
        anim.duration  = 1.8
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        scanLine.removeAnimation(forKey: "sweep")
        glowLine.removeAnimation(forKey: "sweep")
        scanLine.add(anim, forKey: "sweep")
        glowLine.add(anim, forKey: "sweep")
    }

    // MARK: Controls

    private func setupControls() {
        // Wordmark — top center
        let wordmark = UILabel()
        wordmark.text = "JUNCTION®"
        wordmark.textColor = UIColor(white: 1, alpha: 0.55)
        wordmark.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        if #available(iOS 14.0, *) {
            // Letter spacing via attributed string
        }
        let wordmarkAttr = NSAttributedString(string: "JUNCTION®", attributes: [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor(white: 1, alpha: 0.50),
            .kern: 3.5,
        ])
        wordmark.attributedText = wordmarkAttr
        wordmark.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wordmark)

        // Close button — glassy pill
        let close = makeGlassButton(symbol: "xmark", size: 17)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(close)

        // Torch button — glassy pill
        let torch = makeGlassButton(symbol: torchOn ? "bolt.fill" : "bolt", size: 17)
        torch.tintColor = torchOn ? accent : .white
        torch.addTarget(self, action: #selector(torchTapped), for: .touchUpInside)
        torchBtn = torch
        view.addSubview(torch)

        // Hint text — glassmorphism pill
        let hintPill = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        hintPill.layer.cornerRadius = 16
        hintPill.clipsToBounds = true
        hintPill.layer.borderWidth = 0.5
        hintPill.layer.borderColor = UIColor(white: 1, alpha: 0.15).cgColor
        hintPill.translatesAutoresizingMaskIntoConstraints = false

        let hintLabel = UILabel()
        hintLabel.text = promptText.isEmpty ? "Inquadra il codice QR" : promptText
        hintLabel.textColor = UIColor(white: 1, alpha: 0.75)
        hintLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintPill.contentView.addSubview(hintLabel)

        view.addSubview(hintPill)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // Wordmark
            wordmark.topAnchor.constraint(equalTo: g.topAnchor, constant: 20),
            wordmark.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Close — top leading
            close.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),

            // Torch — top trailing
            torch.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            torch.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            torch.widthAnchor.constraint(equalToConstant: 44),
            torch.heightAnchor.constraint(equalToConstant: 44),

            // Hint pill — bottom
            hintPill.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 40),
            hintPill.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -40),
            hintPill.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -60),

            // Hint label inside pill
            hintLabel.topAnchor.constraint(equalTo: hintPill.contentView.topAnchor, constant: 10),
            hintLabel.bottomAnchor.constraint(equalTo: hintPill.contentView.bottomAnchor, constant: -10),
            hintLabel.leadingAnchor.constraint(equalTo: hintPill.contentView.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: hintPill.contentView.trailingAnchor, constant: -16),
        ])
    }

    private func makeGlassButton(symbol: String, size: CGFloat) -> UIButton {
        let btn = UIButton(type: .system)
        if let img = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .medium)) {
            btn.setImage(img, for: .normal)
        }
        btn.tintColor = .white
        btn.backgroundColor = glassReg
        btn.layer.cornerRadius = 22
        btn.layer.borderWidth = 0.5
        btn.layer.borderColor = glassBdr.cgColor
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    @objc private func closeTapped() {
        stopSession()
        dismiss(animated: true) { [weak self] in self?.onCancel?() }
    }

    @objc private func torchTapped() {
        guard let d = device, d.hasTorch else { return }
        torchOn = !torchOn
        setTorch(torchOn)
        // Update icon
        let symbolName = torchOn ? "bolt.fill" : "bolt"
        if let img = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)) {
            torchBtn?.setImage(img, for: .normal)
        }
        torchBtn?.tintColor = torchOn ? accent : .white
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
        AudioServicesPlaySystemSound(1057)
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
