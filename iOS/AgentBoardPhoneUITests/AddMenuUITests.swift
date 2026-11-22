import XCTest

/// The "+" menu on a real host, through the UI: an agent, a runner with a command, a post-it.
/// Runs only on a phone-test board on the signed-in simulator: `PHONE_TEST_HOST` and
/// `PHONE_TEST_WORKTREE` (a `phone-test-…` folder) come in as TEST_RUNNER_ variables, and
/// `PHONE_TEST_SHOTS` is where the screenshots go.
final class AddMenuUITests: XCTestCase {
    func testAddingAnAgentARunnerAndAPostItFromTheMenu() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["PHONE_TEST_HOST"], let worktree = environment["PHONE_TEST_WORKTREE"],
              (worktree as NSString).lastPathComponent.hasPrefix("phone-test-") else {
            throw XCTSkip("Needs PHONE_TEST_HOST and a phone-test PHONE_TEST_WORKTREE")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-openHost", host, "-openWorktree", worktree, "-prepareTest", "YES"]
        app.launch()
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 120), "the canvas opens")
        sleep(5)

        add.tap()
        let agent = item(app, "Claude")
        XCTAssertTrue(agent.waitForExistence(timeout: 10))
        shot(app, "13-menu")
        agent.tap()
        sleep(3)

        add.tap()
        item(app, "Runner").tap()
        let command = app.alerts.textFields.firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 10))
        command.typeText("sh -c 'while true; do date; sleep 2; done'")
        shot(app, "14-runner-command")
        app.alerts.buttons["Add"].tap()
        sleep(3)

        add.tap()
        item(app, "Post-it").tap()
        let text = app.alerts.textFields.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.typeText("Added from the phone")
        app.alerts.buttons["Add"].tap()

        sleep(15)
        shot(app, "15-added-from-menu")
        XCTAssertTrue(app.staticTexts["Post-it"].exists, "the post-it shows")
        XCTAssertTrue(app.staticTexts["Claude"].exists, "the agent shows")
        XCTAssertTrue(app.staticTexts["sh"].exists, "the runner shows, named after its command")
    }

    /// A menu item by its title; its subtitle may be read as part of the label.
    private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
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
