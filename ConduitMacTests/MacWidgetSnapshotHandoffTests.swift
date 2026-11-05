import XCTest
@testable import ConduitMac

/// The app publishes, the extension reads (D25). Two stores on one directory
/// stand in for the two processes sharing the app group container.
@MainActor
final class MacWidgetSnapshotHandoffTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWidgetHandoff.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let workspace = WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!, profile: "default")

    private func reference(_ id: String) -> WidgetConversationReference {
        WidgetConversationReference(kind: .dashboard, scopeProfile: "default", botName: nil, botLabel: nil, sessionID: id, isUnverified: false)
    }

    private func workspaceSnapshot() -> WidgetWorkspaceSnapshot {
        let last = reference("s1")
        return WidgetWorkspaceSnapshot(
            id: workspace,
            dashboardLabel: "Home",
            profileLabel: "Default",
            lastConversation: last,
            choices: [WidgetConversationChoice(reference: last, title: "Weekly sync", isPinned: false, recency: 5)],
            recency: 5
        )
    }

    func testExtensionSideReadsWhatTheAppPublishedAndBuildsTheRightLinks() throws {
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(store: WidgetSnapshotStore(directory: directory), reload: { reloads += 1 })
        try publisher.publish(workspaceSnapshot(), current: workspace, language: "en")
        XCTAssertEqual(reloads, 1)

        let extensionStore = WidgetSnapshotStore(directory: directory)
        let model = WidgetSelection.resolve(snapshot: extensionStore.read(), workspace: nil, conversation: nil)

        XCTAssertEqual(model.title, "Weekly sync")
        XCTAssertEqual(model.dashboardLabel, "Home")
        XCTAssertEqual(model.profileLabel, "Default")
        XCTAssertEqual(model.resumeLink.action, .resume)
        XCTAssertEqual(model.resumeLink.reference, reference("s1"))
        XCTAssertEqual(model.newChatLink?.action, .newChat)
        XCTAssertEqual(model.talkLink?.action, .talk)
        for link in [model.resumeLink, model.newChatLink, model.talkLink].compactMap({ $0 }) {
            XCTAssertEqual(WidgetLaunchLink(url: link.url), link, "the URL a widget Link opens must parse back to the same launch")
        }
    }

    func testRepublishingUnchangedStateDoesNotReloadTheWidgets() throws {
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(store: WidgetSnapshotStore(directory: directory), reload: { reloads += 1 })
        try publisher.publish(workspaceSnapshot(), current: workspace, language: "en")
        try publisher.publish(workspaceSnapshot(), current: workspace, language: "en")
        XCTAssertEqual(reloads, 1)
    }

    func testNoSnapshotYieldsOpenConduitWithTheGenericOpenLink() {
        let store = WidgetSnapshotStore(directory: directory)
        XCTAssertNil(store.read())
        let model = WidgetSelection.resolve(snapshot: store.read(), workspace: nil, conversation: nil)
        XCTAssertEqual(model.titleCopy, .openConduit)
        XCTAssertEqual(model.resumeLink.action, .open)
        XCTAssertNil(model.resumeLink.workspace)
        XCTAssertNil(model.newChatLink)
        XCTAssertNil(model.talkLink)
    }

    func testUnknownSchemaOrCorruptFileYieldsTheSamePlaceholder() throws {
        let url = directory.appendingPathComponent(WidgetSnapshotStore.filename)
        for body in ["{\"schemaVersion\":99,\"appLanguage\":\"en\",\"workspaces\":[]}", "not json", ""] {
            try Data(body.utf8).write(to: url)
            let store = WidgetSnapshotStore(directory: directory)
            XCTAssertNil(store.read(), body)
            let model = WidgetSelection.resolve(snapshot: store.read(), workspace: nil, conversation: nil)
            XCTAssertEqual(model.titleCopy, .openConduit, body)
        }
    }

    func testStaleConversationShowsRefreshInsteadOfAnotherChat() throws {
        // The configured conversation is no longer in the snapshot.
        let publisher = WidgetSnapshotPublisher(store: WidgetSnapshotStore(directory: directory), reload: {})
        try publisher.publish(workspaceSnapshot(), current: workspace, language: "en")
        let model = WidgetSelection.resolve(
            snapshot: WidgetSnapshotStore(directory: directory).read(),
            workspace: workspace,
            conversation: reference("gone"),
            conversationWorkspace: workspace
        )
        XCTAssertEqual(model.titleCopy, .openConduitToRefresh)
    }
}
