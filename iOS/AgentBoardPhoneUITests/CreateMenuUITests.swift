import XCTest

/// Creating from a host's screen, through the UI: a project, a clone, a worktree, and a refusal.
/// Runs only on the signed-in simulator against a real host: `PHONE_TEST_HOST`, `PHONE_TEST_NAME`
/// (a `phone-test-…` name), `PHONE_TEST_CLONE` (an https URL) and `PHONE_TEST_SHOTS` come in as
/// TEST_RUNNER_ variables.
final class CreateMenuUITests: XCTestCase {
    func testCreatingProjectsAndWorktreesFromTheMenu() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["PHONE_TEST_HOST"], let name = environment["PHONE_TEST_NAME"], name.hasPrefix("phone-test-"),
              let clone = environment["PHONE_TEST_CLONE"] else {
            throw XCTSkip("Needs PHONE_TEST_HOST, a phone-test PHONE_TEST_NAME and PHONE_TEST_CLONE")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-openHost", host]
        app.launch()
        let create = app.buttons["Create"]
        XCTAssertTrue(create.waitForExistence(timeout: 120), "the host connects")
        sleep(3)

        create.tap()
        XCTAssertTrue(item(app, "New project").waitForExistence(timeout: 10))
        shot(app, "20-create-menu")
        item(app, "New project").tap()
        type(app, name)
        shot(app, "21-create-alert")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 60), "the new project opens")
        sleep(3)
        shot(app, "22-project-opened")
        back(app)

        create.tap()
        XCTAssertTrue(item(app, "Clone a repository").waitForExistence(timeout: 10))
        shot(app, "23a-menu-again")
        item(app, "Clone a repository").tap()
        type(app, clone)
        app.alerts.textFields.element(boundBy: 1).tap()
        app.alerts.textFields.element(boundBy: 1).typeText(name + "-clone")
        shot(app, "23-clone-alert")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 120), "the clone opens")
        sleep(3)
        shot(app, "24-clone-opened")
        back(app)

        create.tap()
        XCTAssertTrue(item(app, name).waitForExistence(timeout: 10), "the new project offers a worktree")
        shot(app, "25-worktree-menu")
        item(app, name).tap()
        type(app, "phone-test-branch")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 60), "the worktree opens")
        sleep(3)
        shot(app, "26-worktree-opened")
        back(app)

        create.tap()
        item(app, "New project").tap()
        type(app, "phone-test-../escape")
        app.alerts.buttons["Create"].tap()
        let refused = app.alerts["Couldn't create it"]
        XCTAssertTrue(refused.waitForExistence(timeout: 30), "the refusal shows")
        shot(app, "27-refused")
        refused.buttons["OK"].tap()
    }

    /// A menu item by its title; its subtitle may be read as part of the label.
    private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func type(_ app: XCUIApplication, _ text: String) {
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText(text)
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 30), "back on the host")
        sleep(3)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["PHONE_TEST_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
