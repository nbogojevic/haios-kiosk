//
//  ExperimentCameraUITests.swift
//  experiment-cameraUITests
//
//  Created by Nenad BOGOJEVIC on 19/06/2026.
//

import XCTest

final class ExperimentCameraUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testSettingsButtonAndBackButtonRemainInteractive() throws {
        let app = XCUIApplication()
        app.launch()

        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        let settingsNavigationBar = app.navigationBars["Settings"]
        XCTAssertTrue(settingsNavigationBar.waitForExistence(timeout: 5))

        let doneButton = settingsNavigationBar.buttons["Done"]
        XCTAssertTrue(doneButton.exists)
        doneButton.tap()

        let homeNavigationBar = app.navigationBars["Home"]
        XCTAssertTrue(homeNavigationBar.waitForExistence(timeout: 5))

        let openCameraControlsButton = app.buttons["Open camera controls"]
        XCTAssertTrue(openCameraControlsButton.exists)
        openCameraControlsButton.tap()

        let cameraNavigationBar = app.navigationBars["Camera"]
        XCTAssertTrue(cameraNavigationBar.waitForExistence(timeout: 5))

        let backButton = cameraNavigationBar.buttons["Home"]
        XCTAssertTrue(backButton.exists)
        backButton.tap()

        XCTAssertTrue(homeNavigationBar.waitForExistence(timeout: 5))
    }

    @MainActor
    func testTappingCaptureRowOpensCaptureDetails() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-uiTestSeedCaptureItem")
        app.launch()

        let openCapturesButton = app.buttons["Open captures"]
        XCTAssertTrue(openCapturesButton.waitForExistence(timeout: 5))
        openCapturesButton.tap()

        let capturesNavigationBar = app.navigationBars["Captures"]
        XCTAssertTrue(capturesNavigationBar.waitForExistence(timeout: 5))

        let captureRow = app.buttons["CaptureRow"].firstMatch
        XCTAssertTrue(captureRow.waitForExistence(timeout: 5))
        captureRow.tap()

        let captureNavigationBar = app.navigationBars["Capture"]
        XCTAssertTrue(captureNavigationBar.waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
