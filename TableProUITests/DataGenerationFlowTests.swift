import XCTest

final class DataGenerationFlowTests: XCTestCase {
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

    func testToolsMenuOffersGenerateDataAndDisablesItWithoutAConnection() {
        let app = launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let generate = app.menuBars.menuItems["Generate Data…"]
        XCTAssertTrue(
            generate.waitForExistence(timeout: 5),
            "The Tools menu must carry Generate Data"
        )
        XCTAssertFalse(
            generate.isEnabled,
            "Generating needs a connected session, so it stays disabled until there is one"
        )
    }

    /// The whole flow (pick a table, preview, run, watch the log finish) needs the
    /// app launched against a seeded SQLite file and a connection already saved for
    /// it. That fixture does not exist yet, and the wizard's steps carry the
    /// accessibility identifiers this test would drive:
    /// `generation.connection`, `generation.database`, `generation.table.<name>`,
    /// `generation.rowCount`, `generation.seed`, `generation.next`,
    /// `generation.generator.<column>`, `generation.param.<key>`,
    /// `generation.preview`, `generation.previewGrid`, `generation.emptyFirst`,
    /// `generation.start`, `generation.log`, `generation.done`.
    func testGenerateFlowAgainstASqliteFixture() throws {
        throw XCTSkip(
            "Needs a launch fixture: a seeded SQLite database plus a saved connection for it."
        )
    }
}
