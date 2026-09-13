import SwiftUI
import VisionKit
import Vision

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
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
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
    }
}
