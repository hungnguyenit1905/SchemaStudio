import XCTest

/// The sidebar is one tree of every saved connection, shared by every window,
/// and a table opened from it binds its tab to the table's own connection.
/// These drive that through the bundled Chinook sample: it is SQLite, so it
/// needs no server and no credentials, which is what keeps the run repeatable.
final class MultiConnectionSidebarUITests: XCTestCase {
    private let sampleConnection = "Chinook (Sample)"
    private let sampleTable = "Album"

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
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    /// Opens the sample from the File menu rather than the welcome window's
    /// empty state, which only appears when nothing is saved yet.
    private func openSampleDatabase(in app: XCUIApplication) {
        let openSample = app.menuBars.menuItems["Open Sample Database"]
        XCTAssertTrue(openSample.waitForExistence(timeout: 10))
        openSample.click()
    }

    private func row(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testSidebarListsTheConnectionAndOpensOneOfItsTables() {
        let app = launchApp()
        openSampleDatabase(in: app)

        let connectionRow = row("tree-connection-\(sampleConnection)", in: app)
        XCTAssertTrue(
            connectionRow.waitForExistence(timeout: 30),
            "The sidebar must list the saved connection as a row in the tree"
        )

        let tableRow = row("tree-table-\(sampleTable)", in: app)
        if !tableRow.waitForExistence(timeout: 5) {
            connectionRow.doubleClick()
        }
        XCTAssertTrue(
            tableRow.waitForExistence(timeout: 30),
            "Expanding a connection must connect it and load its tables"
        )

        tableRow.doubleClick()
        XCTAssertTrue(
            app.windows[sampleTable].waitForExistence(timeout: 30),
            "Opening a table from the tree must open a tab for it"
        )
    }

    /// Collapsing is not disconnecting. The connection keeps its session and
    /// its tables come straight back, with no second connect.
    func testCollapsingAConnectionKeepsItConnected() {
        let app = launchApp()
        openSampleDatabase(in: app)

        let connectionRow = row("tree-connection-\(sampleConnection)", in: app)
        XCTAssertTrue(connectionRow.waitForExistence(timeout: 30))

        let tableRow = row("tree-table-\(sampleTable)", in: app)
        if !tableRow.waitForExistence(timeout: 5) {
            connectionRow.doubleClick()
            XCTAssertTrue(tableRow.waitForExistence(timeout: 30))
        }

        connectionRow.doubleClick()
        XCTAssertTrue(
            tableRow.waitForNonExistence(timeout: 10),
            "Collapsing must hide the connection's tables"
        )

        connectionRow.doubleClick()
        XCTAssertTrue(
            tableRow.waitForExistence(timeout: 10),
            "A collapsed connection stays connected, so its tables come straight back"
        )
        XCTAssertFalse(
            row("tree-status-error", in: app).exists,
            "Re-expanding a still-connected connection must not report a connect error"
        )
    }
}
