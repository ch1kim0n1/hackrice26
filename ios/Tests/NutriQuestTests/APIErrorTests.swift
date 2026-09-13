import XCTest
@testable import NutriQuest

/// Pins FINDING-001: HTTP error copy must stay one line and never include HTML.
final class APIErrorTests: XCTestCase {

    /// An HTML 404 body must not appear in the string shown on NQBanner.
    func testHTMLBodyIsStrippedFromStatusMessage() {
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head><title>Error</title></head>
        <body><pre>Cannot GET /portal-wheel/state</pre></body>
        </html>
        """
        let message = APIError.userFacingStatus(404, body: html)
        XCTAssertEqual(message, "Couldn't reach the server (HTTP 404).")
        XCTAssertFalse(message.contains("DOCTYPE"))
        XCTAssertFalse(message.contains("Cannot GET"))
    }

    /// A short plain-text body is still useful and stays attached.
    func testShortPlainBodyIsKept() {
        let message = APIError.userFacingStatus(400, body: "wager too large")
        XCTAssertEqual(message, "Couldn't reach the server (HTTP 400): wager too large")
    }

    /// LocalizedError for badStatus uses the same sanitizer as the helper.
    func testBadStatusErrorDescriptionDropsHTML() {
        let error = APIError.badStatus(404, "<html>nope</html>")
        XCTAssertEqual(error.errorDescription, "Couldn't reach the server (HTTP 404).")
    }
}
