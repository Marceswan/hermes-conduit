import AppKit
import SwiftUI
import XCTest
@testable import ConduitMac

/// R17, B4 and M1: Settings > Connection Setup on the dashboard Conduit is set up for. When the test ends in a browser
/// sign-in (or a choice that offers it), the Review must carry a Sign In Again control and must not send the user to a
/// login screen that is not there (the app shell is up).
@MainActor
final class ConnectionSetupSettingsSignInTests: XCTestCase {
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
        let settings: ConnectionSetupSettingsReview?
        var body: some View {
            ConnectionSetupForm(
                flow: $flow, onStartTest: {}, onComplete: { _ in }, repairReview: nil, settingsReview: settings)
        }
    }

    private func settingsReview(
        offers: Bool, connected: Bool = true, signingIn: Bool = false, failure: ConnectionFailure? = nil,
        signInAgain: @escaping () -> Void = {}
    ) -> ConnectionSetupSettingsReview {
        ConnectionSetupSettingsReview(
            isSessionConnected: connected, offersSignInAgain: offers, isSigningIn: signingIn,
            signInFailure: failure, signInAgain: signInAgain)
    }

    private func flowAtReview(ending terminal: ConnectionSetupTestEvent) throws -> ConnectionSetupFlow {
        var flow = ConnectionSetupFlow(
            entry: .currentConnection, draft: ConnectionSetupDraft(existingServerURL: "https://hermes.example.com"))
        let generation = try XCTUnwrap(flow.beginTest())
        let events: [ConnectionSetupTestEvent] = [
            .started(.server), .succeeded(.server), .started(.dashboard), .succeeded(.dashboard),
            .started(.authentication), terminal
        ]
        for event in events { flow.applyTestEvent(event, generation: generation) }
        XCTAssertEqual(flow.step, .review)
        return flow
    }

    private func read(_ flow: ConnectionSetupFlow, settings: ConnectionSetupSettingsReview?, expecting: String)
        throws -> (ids: Set<String>, texts: [String]) {
        try XCTSkipUnless(AccessibilityTreeBoost.isAvailable)
        AccessibilityTreeBoost.set(true)
        let host = Harness(flow: flow, settings: settings)
            .environmentObject(AppStateRuntimeRegistry.shared.appState)
            .frame(width: 560, height: 800)
        let window = HostedTestSupport.host(host, size: NSSize(width: 560, height: 800))
        self.window = window
        func ids() -> Set<String> { Set(AccessibilityProbe.nodes(in: window).compactMap(\.identifier)) }
        _ = HostedTestSupport.waitUntil { ids().contains(expecting) }
        HostedTestSupport.settle(0.3)
        return (ids(), AccessibilityProbe.texts(in: window))
    }

    private let interactive = ConnectionSetupTestEvent.requiresInteractiveSignIn(.authentication, .browser(.authProxyRedirect))
    private let choice = ConnectionSetupTestEvent.requiresSignInChoice(.authentication, .legacyOAuth)

    func testBrowserSignInOutcomeOffersSignInAgainAndNamesNoLoginScreen() throws {
        let flow = try flowAtReview(ending: interactive)
        let out = try read(flow, settings: settingsReview(offers: true), expecting: "setup.review.sign-in-again")
        XCTAssertTrue(out.ids.contains("setup.review.sign-in-again"), "\(out.ids)")
        XCTAssertTrue(out.ids.contains("setup.test.sign-in-again"), "\(out.ids)")
        XCTAssertTrue(out.texts.contains(ConnectionSetupSettingsReview.signInAgainMessage(connected: true)), "\(out.texts)")
        XCTAssertFalse(out.texts.contains { $0.localizedCaseInsensitiveContains("login screen") }, "\(out.texts)")
    }

    func testSignInChoiceOutcomeOffersSignInAgainAndEnterCredentials() throws {
        let flow = try flowAtReview(ending: choice)
        let out = try read(flow, settings: settingsReview(offers: true, connected: false), expecting: "setup.review.sign-in-again")
        XCTAssertTrue(out.ids.contains("setup.review.sign-in-again"), "\(out.ids)")
        XCTAssertTrue(out.ids.contains("setup.test.choice-enter-credentials"), "\(out.ids)")
        XCTAssertTrue(out.texts.contains(ConnectionSetupSettingsReview.signInAgainMessage(connected: false)), "\(out.texts)")
    }

    func testSigningInShowsReconnectingInPlaceOfTheButton() throws {
        let flow = try flowAtReview(ending: interactive)
        let out = try read(flow, settings: settingsReview(offers: true, signingIn: true), expecting: "setup.review.reconnecting")
        XCTAssertTrue(out.ids.contains("setup.review.reconnecting"), "\(out.ids)")
        XCTAssertFalse(out.ids.contains("setup.review.sign-in-again"), "\(out.ids)")
    }

    func testFailedSignInShowsItsMessageAndKeepsTheButton() throws {
        let flow = try flowAtReview(ending: interactive)
        let out = try read(flow, settings: settingsReview(offers: true, failure: .connectionRefused),
                           expecting: "setup.review.sign-in-again-failure")
        XCTAssertTrue(out.ids.contains("setup.review.sign-in-again-failure"), "\(out.ids)")
        XCTAssertTrue(out.ids.contains("setup.review.sign-in-again"), "\(out.ids)")
    }

    func testAnotherAddressDoesNotOfferSignInAgain() throws {
        let flow = try flowAtReview(ending: interactive)
        let out = try read(flow, settings: settingsReview(offers: false), expecting: "setup.use-settings")
        XCTAssertTrue(out.ids.contains("setup.use-settings"), "\(out.ids)")
        XCTAssertFalse(out.ids.contains("setup.review.sign-in-again"), "\(out.ids)")
    }

    // MARK: the address gate of Sign In Again

    func testSignInAgainIsOfferedForTheActiveDashboardOnly() throws {
        let flow = try flowAtReview(ending: interactive)
        XCTAssertTrue(ConnectionSetupSettingsReview.offersSignInAgain(
            for: flow, activeDashboardURL: "https://hermes.example.com"))
        XCTAssertFalse(ConnectionSetupSettingsReview.offersSignInAgain(
            for: flow, activeDashboardURL: "https://other.example.com"))
        XCTAssertFalse(ConnectionSetupSettingsReview.offersSignInAgain(for: flow, activeDashboardURL: nil))
    }

    func testSignInAgainIsNotOfferedWithoutABrowserOutcome() throws {
        let flow = try flowAtReview(ending: .succeeded(.authentication))
        XCTAssertFalse(ConnectionSetupSettingsReview.offersSignInAgain(
            for: flow, activeDashboardURL: "https://hermes.example.com"))
    }

    // MARK: the spoken result

    func testSettingsAnnouncementNamesSignInAgainNotTheLoginScreen() {
        let review = settingsReview(offers: true, connected: false)
        let expected = ConnectionSetupSettingsReview.signInAgainMessage(connected: false)
        for event in [interactive, choice] {
            XCTAssertEqual(ConnectionSetupAnnouncement.completion(for: event, repairing: false, settingsReview: review), expected)
        }
    }

    func testOtherAnnouncementsUseTheSharedWording() {
        let none = settingsReview(offers: false)
        XCTAssertEqual(ConnectionSetupAnnouncement.completion(for: interactive, repairing: false, settingsReview: none),
                       ConnectionSetupTestState.interactiveReadyMessage)
        XCTAssertEqual(ConnectionSetupAnnouncement.completion(for: interactive, repairing: true, settingsReview: nil),
                       ConnectionSetupTestState.repairInteractiveMessage)
        XCTAssertEqual(ConnectionSetupAnnouncement.completion(for: choice, repairing: true, settingsReview: nil),
                       ConnectionSetupTestState.repairSignInChoiceMessage)
        XCTAssertEqual(ConnectionSetupAnnouncement.completion(for: choice, repairing: false, settingsReview: nil),
                       ConnectionSetupTestState.signInChoiceMessage)
        XCTAssertEqual(ConnectionSetupAnnouncement.completion(for: .succeeded(.authentication), repairing: false, settingsReview: nil),
                       ConnectionSetupTestState.readyMessage)
        XCTAssertNil(ConnectionSetupAnnouncement.completion(for: .started(.server), repairing: false, settingsReview: nil))
    }
}
