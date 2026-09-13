import SwiftUI
import VisionKit
import Vision
import AVFoundation

/// Camera permission, resolved before the scanner is ever shown so a
/// `.notDetermined` state prompts instead of being misreported as "unavailable".
public enum CameraPermission {
    public enum Outcome { case granted, denied, restricted }

    public static func request() async -> Outcome {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }
}

/// Hosts DataScannerViewController as a child so scanning starts exactly when
/// UIKit says the view is on screen. DataScannerViewController is not `open`,
/// and it stops itself in viewDidDisappear but never auto-starts — and a
/// SwiftUI representable's `update` is not re-run once the view lands in a
/// window, so `viewDidAppear` here is the only reliable trigger.
public final class ScannerHostController: UIViewController {
    let scanner: DataScannerViewController
    var onStartFailure: ((Error) -> Void)?
    private var startFailed = false

    init(scanner: DataScannerViewController) {
        self.scanner = scanner
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startIfNeeded()
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if scanner.isScanning { scanner.stopScanning() }
    }

    func startIfNeeded() {
        guard !startFailed, !scanner.isScanning, view.window != nil else { return }
        do {
            try scanner.startScanning()
        } catch {
            startFailed = true
            onStartFailure?(error)
        }
    }
}

/// Camera-based barcode scanner built on VisionKit's DataScannerViewController.
/// Reports (payload, symbology raw value) for the first barcode it locks on.
public struct ScannerView: UIViewControllerRepresentable {
    public let onScan: (_ payload: String, _ symbology: String?) -> Void
    public let onUnavailable: (String) -> Void

    /// Retail product codes only. With QR/Aztec/PDF417 enabled the single-shot
    /// lock frequently lands on the QR code printed next to the barcode, and
    /// the server rejects the non-numeric payload. VisionKit reports UPC-A as
    /// EAN-13, so no separate UPC-A entry is needed.
    public static var supportedSymbologies: [VNBarcodeSymbology] {
        [
            .ean13, .ean8, .upce,
            .itf14,
            .gs1DataBar, .gs1DataBarLimited, .gs1DataBarExpanded
        ]
    }

    public static var isSupported: Bool { DataScannerViewController.isSupported }
    public static var isAvailable: Bool { DataScannerViewController.isAvailable }

    public func makeUIViewController(context: Context) -> ScannerHostController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: Self.supportedSymbologies)],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        let host = ScannerHostController(scanner: scanner)
        host.onStartFailure = { [coordinator = context.coordinator] error in
            coordinator.parent.onUnavailable(error.localizedDescription)
        }
        // Tap-to-focus: DataScannerViewController exposes no focus API, but
        // the device it runs on is the shared default video device — point
        // focus/exposure can be driven through AVCaptureDevice directly.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleFocusTap(_:))
        )
        host.view.addGestureRecognizer(tap)
        return host
    }

    public func updateUIViewController(_ host: ScannerHostController, context: Context) {
        // SwiftUI rebuilds this struct on every parent render; keep the
        // coordinator's closures pointing at the current ones.
        context.coordinator.parent = self
        // viewDidAppear is the real trigger; this is a harmless re-check.
        host.startIfNeeded()
    }

    public static func dismantleUIViewController(_ host: ScannerHostController, coordinator: Coordinator) {
        if host.scanner.isScanning { host.scanner.stopScanning() }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: ScannerView
        /// Single-shot: a second `didAdd` can land before SwiftUI tears the
        /// scanner down, which would double-post the same barcode.
        private var hasReported = false
        public init(_ parent: ScannerView) { self.parent = parent }

        public func dataScanner(_ dataScanner: DataScannerViewController,
                                didAdd addedItems: [RecognizedItem],
                                allItems: [RecognizedItem]) {
            guard !hasReported else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue, !payload.isEmpty {
                    hasReported = true
                    dataScanner.stopScanning()
                    parent.onScan(payload, barcode.observation.symbology.rawValue)
                    return
                }
            }
        }

        public func dataScanner(_ dataScanner: DataScannerViewController,
                                becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            switch error {
            case .cameraRestricted:
                parent.onUnavailable("Camera access is restricted or denied. Enable it in Settings and try again.")
            case .unsupported:
                parent.onUnavailable("This device can't scan barcodes.")
            @unknown default:
                parent.onUnavailable(error.localizedDescription)
            }
        }

        /// Tap anywhere in the preview → focus + expose at that point, then
        /// hand control back to continuous autofocus. Also flashes a small
        /// reticle so the tap reads as an action.
        @objc func handleFocusTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let devicePoint = CGPoint(
                x: point.x / max(1, view.bounds.width),
                y: point.y / max(1, view.bounds.height)
            )
            guard let device = AVCaptureDevice.default(for: .video),
                  device.isFocusPointOfInterestSupported else { return }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch { return }
            flashReticle(at: point, in: view)
            // Return to continuous focus once the point focus locks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    device.unlockForConfiguration()
                } catch { return }
            }
        }

        /// Brief square reticle at the tap point, like the system camera.
        private func flashReticle(at point: CGPoint, in view: UIView) {
            let side: CGFloat = 64
            let reticle = UIView(frame: CGRect(
                x: point.x - side / 2, y: point.y - side / 2,
                width: side, height: side
            ))
            reticle.layer.borderColor = UIColor.systemYellow.cgColor
            reticle.layer.borderWidth = 1.5
            reticle.layer.cornerRadius = 6
            reticle.isUserInteractionEnabled = false
            reticle.alpha = 0
            reticle.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
            view.addSubview(reticle)
            UIView.animate(withDuration: 0.18, animations: {
                reticle.alpha = 1
                reticle.transform = .identity
            }) { _ in
                UIView.animate(withDuration: 0.4, delay: 0.5, options: [], animations: {
                    reticle.alpha = 0
                    reticle.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
                }) { _ in reticle.removeFromSuperview() }
            }
        }
    }
}
