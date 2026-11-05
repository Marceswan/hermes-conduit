import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// R17: the frozen Mac Connection Setup copy (ConduitMac/Login) must give the sign-in-choice outcome
/// both ways forward that upstream shows: Enter Credentials and the browser sign-in path.
@MainActor
final class ConnectionSetupSignInChoiceTests: XCTestCase {
    private var boostWasOn = false
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        boostWasOn = AccessibilityTreeBoost.isOn
    }

    override func tearDown() {
        if let window { HostedTestSupport.tearDown(window) }
        window = nil
        AccessibilityTreeBoost.set(boostWasOn)
        super.tearDown()
    }

    private struct Harness: View {
        @State var flow: ConnectionSetupFlow
        let repair: ConnectionSetupRepairReview?
        var body: some View {
            ConnectionSetupForm(flow: $flow, onStartTest: {}, onComplete: { _ in }, repairReview: repair)
        }
    }

    private func repairReview(interactive: Bool, offersPassword: Bool) -> ConnectionSetupRepairReview {
        ConnectionSetupRepairReview(
            isInteractive: interactive, offersPasswordSignIn: offersPassword, isCandidateAvailable: false,
            activationFailure: nil, isActivating: false,
            reconnectNow: {}, signInToReconnect: {}, enterCredentials: {}, testAgain: {})
    }

    /// A flow whose staged test ended in `terminal`, sitting on Review.
    private func flowAtReview(entry: ConnectionHelpDestination, ending terminal: ConnectionSetupTestEvent) throws -> ConnectionSetupFlow {
        var flow = ConnectionSetupFlow(
            entry: entry, draft: ConnectionSetupDraft(existingServerURL: "https://hermes.example.com"))
        XCTAssertEqual(flow.step, .connectionTest)
        let generation = try XCTUnwrap(flow.beginTest())
        let events: [ConnectionSetupTestEvent] = [
            .started(.server), .succeeded(.server), .started(.dashboard), .succeeded(.dashboard),
            .started(.authentication), terminal
        ]
        for event in events { flow.applyTestEvent(event, generation: generation) }
        XCTAssertEqual(flow.step, .review)
        return flow
    }

    private func identifiers(_ flow: ConnectionSetupFlow, repair: ConnectionSetupRepairReview?, expecting: String) throws -> Set<String> {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let host = Harness(flow: flow, repair: repair)
            .environmentObject(AppStateRuntimeRegistry.shared.appState)
            .frame(width: 560, height: 700)
        let window = HostedTestSupport.host(host, size: NSSize(width: 560, height: 700))
        self.window = window
        func ids() -> Set<String> { Set(AccessibilityProbe.nodes(in: window).compactMap(\.identifier)) }
        _ = HostedTestSupport.waitUntil { ids().contains(expecting) }
        HostedTestSupport.settle(0.3)
        return ids()
    }

    private let choice = ConnectionSetupTestEvent.requiresSignInChoice(.authentication, .legacyOAuth)

    func testRepairReviewOffersSignInAndEnterCredentials() throws {
        let flow = try flowAtReview(entry: .repairConnection, ending: choice)
        XCTAssertTrue(flow.testState.requiresSignInChoice)
        let ids = try identifiers(flow, repair: repairReview(interactive: true, offersPassword: true),
                                  expecting: "setup.review.sign-in-reconnect")
        XCTAssertTrue(ids.contains("setup.review.sign-in-reconnect"), "\(ids)")
        XCTAssertTrue(ids.contains("setup.review.enter-credentials"), "\(ids)")
    }

    func testInteractiveOutcomeDoesNotOfferEnterCredentials() throws {
        let flow = try flowAtReview(
            entry: .repairConnection, ending: .requiresInteractiveSignIn(.authentication, .browser(.authProxyRedirect)))
        let ids = try identifiers(flow, repair: repairReview(interactive: true, offersPassword: false),
                                  expecting: "setup.review.sign-in-reconnect")
        XCTAssertTrue(ids.contains("setup.review.sign-in-reconnect"), "\(ids)")
        XCTAssertFalse(ids.contains("setup.review.enter-credentials"), "\(ids)")
    }

    func testSettingsReviewOffersUseSettingsAndEnterCredentials() throws {
        let flow = try flowAtReview(entry: .currentConnection, ending: choice)
        let ids = try identifiers(flow, repair: nil, expecting: "setup.use-settings")
        XCTAssertTrue(ids.contains("setup.use-settings"), "\(ids)")
        XCTAssertTrue(ids.contains("setup.test.choice-enter-credentials"), "\(ids)")
    }

    func testTestScreenAfterBackOffersContinueAndEnterCredentials() throws {
        var flow = try flowAtReview(entry: .currentConnection, ending: choice)
        flow.back()
        XCTAssertEqual(flow.step, .connectionTest)
        let ids = try identifiers(flow, repair: nil, expecting: "setup.test.continue")
        XCTAssertTrue(ids.contains("setup.test.continue"), "\(ids)")
        XCTAssertTrue(ids.contains("setup.test.choice-enter-credentials"), "\(ids)")
    }

    func testEnterCredentialsLeavesForTheCredentialsStep() throws {
        var flow = try flowAtReview(entry: .currentConnection, ending: choice)
        flow.enterCredentialsForSignInChoice()
        XCTAssertEqual(flow.step, .loginCredentials)
    }
}
