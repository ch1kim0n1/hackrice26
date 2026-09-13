import XCTest
@testable import NutriQuest

/// The barcode the camera reads is not always the one product databases key
/// on: UPC-E must expand to UPC-A before it hits Open Food Facts. These pin
/// the GS1 expansion table row by row (every expected code checksums).
final class BarcodeUtilsTests: XCTestCase {
    func testGTINChecksum() {
        XCTAssertEqual(BarcodeUtils.validateGTINChecksum("3017620422003"), true)   // Nutella EAN-13
        XCTAssertEqual(BarcodeUtils.validateGTINChecksum("3017620422004"), false)
        XCTAssertEqual(BarcodeUtils.validateGTINChecksum("042100005264"), true)    // UPC-A
        XCTAssertNil(BarcodeUtils.validateGTINChecksum("abc"))
        XCTAssertNil(BarcodeUtils.validateGTINChecksum("12345"))                   // unknown length
    }

    func testExpandUPCEAllLastDigitForms() {
        XCTAssertEqual(BarcodeUtils.expandUPCE("04252614"), "042100005264") // X6 = 1
        XCTAssertEqual(BarcodeUtils.expandUPCE("06543217"), "065100004327") // X6 = 1, different digits
        XCTAssertEqual(BarcodeUtils.expandUPCE("01234531"), "012300000451") // X6 = 3
        XCTAssertEqual(BarcodeUtils.expandUPCE("01234543"), "012340000053") // X6 = 4
        XCTAssertEqual(BarcodeUtils.expandUPCE("01234558"), "012345000058") // X6 = 8
        XCTAssertNil(BarcodeUtils.expandUPCE("24252614"))  // number system must be 0 or 1
        XCTAssertNil(BarcodeUtils.expandUPCE("1234567"))   // wrong length
    }

    func testExpandedUPCEChecksums() throws {
        for code in ["04252614", "06543217", "01234531", "01234543", "01234558"] {
            let expanded = try XCTUnwrap(BarcodeUtils.expandUPCE(code))
            XCTAssertEqual(BarcodeUtils.validateGTINChecksum(expanded), true, code)
        }
    }

    func testLookupCodeExpandsOnlyUPCE() {
        XCTAssertEqual(BarcodeUtils.lookupCode(for: "04252614", symbology: "org.gs1.UPC-E"), "042100005264")
        XCTAssertEqual(BarcodeUtils.lookupCode(for: "3017620422003", symbology: "org.gs1.EAN-13"), "3017620422003")
        XCTAssertEqual(BarcodeUtils.lookupCode(for: "04252614", symbology: nil), "04252614")
    }
}
