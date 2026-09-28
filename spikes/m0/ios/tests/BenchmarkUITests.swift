import XCTest

final class BenchmarkUITests: XCTestCase {
    func testMetalWithoutFusionProducesExportableReport() {
        runMetalDiagnostic(environmentKey: "GGML_METAL_FUSION_DISABLE", screenshotName: "fusion-disabled-simulator-benchmark")
    }

    func testMetalWithoutSharedBuffersProducesExportableReport() {
        runMetalDiagnostic(environmentKey: "GGML_METAL_SHARED_BUFFERS_DISABLE", screenshotName: "shared-buffers-disabled-simulator-benchmark")
    }

    private func runMetalDiagnostic(environmentKey: String, screenshotName: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["M0_CPU_ONLY"] = "0"
        app.launchEnvironment[environmentKey] = "1"
        app.launch()
        let run = app.buttons["runBenchmark"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        run.tap()
        XCTAssertTrue(app.staticTexts["Completed runs: 1"].waitForExistence(timeout: 120))
        XCTAssertTrue(app.buttons["Export JSON report"].waitForExistence(timeout: 120))
        XCTAssertTrue(run.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = screenshotName
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRepeatedRunsProduceExportableReports() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["M0_CPU_ONLY"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Simulator run. Physical-device latency remains unmeasured."].waitForExistence(timeout: 10))
        let run = app.buttons["runBenchmark"]
        XCTAssertTrue(run.exists)
        for completed in 1...2 {
            run.tap()
            XCTAssertTrue(app.staticTexts["Completed runs: \(completed)"].waitForExistence(timeout: 120))
            XCTAssertTrue(app.buttons["Export JSON report"].waitForExistence(timeout: 120))
            XCTAssertTrue(run.isEnabled)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "completed-simulator-benchmark"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
