import SwiftUI
import VisionKit
import Vision
import AVFoundation

/// Camera-based barcode scanner built on VisionKit's DataScannerViewController.
/// Reports (payload, symbology raw value) pairs for every detected barcode.
public struct ScannerView: UIViewControllerRepresentable {
    public let onScan: (_ payload: String, _ symbology: String?) -> Void
    public let onUnavailable: (String) -> Void

    public static var supportedSymbologies: [VNBarcodeSymbology] {
        [
            .ean13, .ean8, .upce,
            .code39, .code93, .code128, .codabar,
            .itf14,
            .gs1DataBar, .gs1DataBarLimited, .gs1DataBarExpanded,
            .qr, .aztec, .dataMatrix, .pdf417
        ]
    }

    public static var isSupported: Bool { DataScannerViewController.isSupported }
    public static var isAvailable: Bool { DataScannerViewController.isAvailable }

    public func makeUIViewController(context: Context) -> DataScannerViewController {
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
        // Tap-to-focus: DataScannerViewController exposes no focus API, but
        // the device it runs on is the shared default video device — point
        // focus/exposure can be driven through AVCaptureDevice directly.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleFocusTap(_:))
        )
        scanner.view.addGestureRecognizer(tap)
        return scanner
    }

    public func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        // VisionKit does not scan until startScanning() is called. Wait until
        // the scanner is in a window so a premature call doesn't permanently fail.
        guard !context.coordinator.didFail else { return }
        guard !scanner.isScanning else { return }
        guard scanner.viewIfLoaded?.window != nil else { return }
        do {
            try scanner.startScanning()
        } catch {
            context.coordinator.didFail = true
            onUnavailable(error.localizedDescription)
        }
    }

    public static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        if scanner.isScanning { scanner.stopScanning() }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: ScannerView
        var didFail = false
        public init(_ parent: ScannerView) { self.parent = parent }

        public func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue {
                    let symbology = barcode.observation.symbology.rawValue
                    parent.onScan(payload, symbology)
                    return // single-shot: first barcode wins
                }
            }
        }

        public func dataScanner(_ dataScanner: DataScannerViewController,
                         didBecomeUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            parent.onUnavailable(error.localizedDescription)
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
