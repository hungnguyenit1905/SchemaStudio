import XCTest

final class DataTransferWizardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launch()
        return app
    }

    func testToolsMenuOffersDataTransferAndDisablesItWithoutAConnection() {
        let app = launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let dataTransfer = app.menuBars.menuItems["Data Transfer…"]
        XCTAssertTrue(
            dataTransfer.waitForExistence(timeout: 5),
            "The Tools menu must carry Data Transfer"
        )
        XCTAssertFalse(
            dataTransfer.isEnabled,
            "Data Transfer needs a connected session, so it stays disabled until there is one"
        )
    }
}
