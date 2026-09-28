import XCTest

final class NativeReproUITests: XCTestCase {
    func testWrongModelIsRejectedBeforeDecode() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.andrewdongminyoo.edgeone.m0.native-repro")
        app.launchArguments = ["--invalid-model"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Repro failed: model hash mismatch"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Native repro complete"].exists)
    }

    func testDirectCPUAndMetalDecode() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.andrewdongminyoo.edgeone.m0.native-repro")
        app.launch()
        XCTAssertTrue(app.staticTexts["Native repro complete"].waitForExistence(timeout: 120))
    }
}
