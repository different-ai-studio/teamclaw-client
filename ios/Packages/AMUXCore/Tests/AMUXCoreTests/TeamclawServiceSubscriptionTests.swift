import XCTest
import SwiftData
@testable import AMUXCore

@MainActor
final class TeamclawServiceSubscriptionTests: XCTestCase {
    func testStartRehydratesForegroundSessionSubscriptionsOnNewMQTTRuntime() async throws {
        let firstMQTT = MQTTService(
            subscribeHook: { _ in },
            unsubscribeHook: { _ in }
        )
        let service = TeamclawService()
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)

        service.configureRuntimeForTesting(
            mqtt: firstMQTT,
            teamId: "team1",
            deviceId: "device1",
            peerId: "peer1",
            modelContainer: container
        )

        try await service.beginForegroundSession("sess-1")
        XCTAssertEqual(service.foregroundSessionIDs, ["sess-1"])

        let restartedMQTT = MQTTService(
            subscribeHook: { _ in },
            unsubscribeHook: { _ in }
        )

        service.start(
            mqtt: restartedMQTT,
            teamId: "team1",
            deviceId: "device1",
            peerId: "peer1",
            modelContext: modelContext
        )

        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            restartedMQTT.subscribedTopics,
            [
                MQTTTopics.deviceNotify(teamID: "team1", deviceID: "device1"),
                MQTTTopics.deviceRpcResponse(teamID: "team1", deviceID: "device1"),
                MQTTTopics.devicePeers(teamID: "team1", deviceID: "device1"),
                MQTTTopics.sessionLive(teamID: "team1", sessionID: "sess-1"),
            ]
        )
        XCTAssertEqual(service.foregroundSessionIDs, ["sess-1"])

        service.stop()
    }

    func testMembershipRefreshNotifyUsesExplicitRefreshPath() async throws {
        let mqtt = MQTTService(
            subscribeHook: { _ in },
            unsubscribeHook: { _ in }
        )
        let service = TeamclawService()
        let container = try makeModelContainer()

        service.configureRuntimeForTesting(
            mqtt: mqtt,
            teamId: "team1",
            deviceId: "device1",
            peerId: "peer1",
            modelContainer: container
        )

        var notify = Teamclaw_NotifyEnvelope()
        notify.eventType = "membership.refresh"
        notify.sessionID = "sess-1"

        await service.handleIncomingForTesting(
            MQTTIncoming(
                topic: MQTTTopics.deviceNotify(teamID: "team1", deviceID: "device1"),
                payload: try notify.serializedData(),
                retained: false
            )
        )

        XCTAssertEqual(service.refreshedSessionIDs, ["sess-1"])
        XCTAssertTrue(service.foregroundSessionIDs.isEmpty)
    }

    func testMembershipRefreshNotifyFetchesSessionInfoWithoutMessageBackfillForBackgroundSession() async throws {
        let mqtt = MQTTService(
            subscribeHook: { _ in },
            unsubscribeHook: { _ in }
        )
        let service = TeamclawService()
        let container = try makeModelContainer()

        service.configureRuntimeForTesting(
            mqtt: mqtt,
            teamId: "team1",
            deviceId: "device1",
            peerId: "peer1",
            modelContainer: container
        )

        var notify = Teamclaw_NotifyEnvelope()
        notify.eventType = "membership.refresh"
        notify.sessionID = "sess-background"

        await service.handleIncomingForTesting(
            MQTTIncoming(
                topic: MQTTTopics.deviceNotify(teamID: "team1", deviceID: "device1"),
                payload: try notify.serializedData(),
                retained: false
            )
        )

        XCTAssertEqual(service.refreshedSessionIDs, ["sess-background"])
        XCTAssertEqual(service.fetchSessionInfoCalls, ["sess-background"])
        XCTAssertTrue(service.fetchRecentMessagesCalls.isEmpty)
        XCTAssertTrue(service.foregroundSessionIDs.isEmpty)
    }

    func testMembershipRefreshNotifyBackfillsMessagesForForegroundSession() async throws {
        let mqtt = MQTTService(
            subscribeHook: { _ in },
            unsubscribeHook: { _ in }
        )
        let service = TeamclawService()
        let container = try makeModelContainer()

        service.configureRuntimeForTesting(
            mqtt: mqtt,
            teamId: "team1",
            deviceId: "device1",
            peerId: "peer1",
            modelContainer: container
        )

        try await service.beginForegroundSession("sess-foreground")
        XCTAssertEqual(service.fetchRecentMessagesCalls, ["sess-foreground"])

        var notify = Teamclaw_NotifyEnvelope()
        notify.eventType = "membership.refresh"
        notify.sessionID = "sess-foreground"

        await service.handleIncomingForTesting(
            MQTTIncoming(
                topic: MQTTTopics.deviceNotify(teamID: "team1", deviceID: "device1"),
                payload: try notify.serializedData(),
                retained: false
            )
        )

        XCTAssertEqual(service.refreshedSessionIDs, ["sess-foreground"])
        XCTAssertEqual(service.fetchSessionInfoCalls, ["sess-foreground"])
        XCTAssertEqual(service.fetchRecentMessagesCalls, ["sess-foreground", "sess-foreground"])
        XCTAssertEqual(service.foregroundSessionIDs, ["sess-foreground"])
    }

    func testBeginForegroundSessionSubscribesToLiveTopicAndFetchesHistoryOnce() async throws {
        let mqtt = MQTTService(
            subscribeHook: { _ in },
            unsubscribeHook: { _ in }
        )
        let service = TeamclawService()
        let container = try makeModelContainer()

        service.configureRuntimeForTesting(
            mqtt: mqtt,
            teamId: "team1",
            deviceId: "device1",
            peerId: "peer1",
            modelContainer: container
        )

        try await service.beginForegroundSession("sess-1")

        XCTAssertEqual(
            mqtt.subscribedTopics,
            [MQTTTopics.sessionLive(teamID: "team1", sessionID: "sess-1")]
        )
        XCTAssertEqual(service.foregroundSessionIDs, ["sess-1"])
        XCTAssertEqual(service.fetchRecentMessagesCalls, ["sess-1"])

        try await service.beginForegroundSession("sess-1")

        XCTAssertEqual(
            mqtt.subscribedTopics,
            [MQTTTopics.sessionLive(teamID: "team1", sessionID: "sess-1")]
        )
        XCTAssertEqual(service.fetchRecentMessagesCalls, ["sess-1"])
    }

    func testSendMessagePublishesLiveEventTopic() async throws {
        var published: [(String, Data, Bool)] = []
        let mqtt = MQTTService(
            subscribeHook: { _ in },
            unsubscribeHook: { _ in },
            publishHook: { topic, payload, retain in
                published.append((topic, payload, retain))
            }
        )
        let service = TeamclawService()
        let container = try makeModelContainer()

        service.configureRuntimeForTesting(
            mqtt: mqtt,
            teamId: "team1",
            deviceId: "device1",
            peerId: "peer1",
            modelContainer: container
        )

        var peers = Amux_PeerList()
        var mine = Amux_PeerInfo()
        mine.peerID = "peer1"
        mine.memberID = "member1"
        peers.peers = [mine]

        await service.handleIncomingForTesting(
            MQTTIncoming(
                topic: MQTTTopics.devicePeers(teamID: "team1", deviceID: "device1"),
                payload: try peers.serializedData(),
                retained: false
            )
        )

        service.sendMessage(sessionId: "sess-1", content: "hello")
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].0, MQTTTopics.sessionLive(teamID: "team1", sessionID: "sess-1"))
        XCTAssertFalse(published[0].2)
    }

    func testEndForegroundSessionUnsubscribesLiveTopic() async throws {
        let mqtt = MQTTService(
            subscribeHook: { _ in },
            unsubscribeHook: { _ in }
        )
        let service = TeamclawService()
        let container = try makeModelContainer()

        service.configureRuntimeForTesting(
            mqtt: mqtt,
            teamId: "team1",
            deviceId: "device1",
            peerId: "peer1",
            modelContainer: container
        )

        try await service.beginForegroundSession("sess-1")
        try await service.beginForegroundSession("sess-2")

        try await service.endForegroundSession("sess-1")

        XCTAssertEqual(
            mqtt.unsubscribedTopics,
            [MQTTTopics.sessionLive(teamID: "team1", sessionID: "sess-1")]
        )
        XCTAssertEqual(service.foregroundSessionIDs, ["sess-2"])
    }

    func testStopClearsForegroundSubscriptions() async throws {
        let stopUnsubscribeExpectation = expectation(description: "stop unsubscribes live topics")
        stopUnsubscribeExpectation.expectedFulfillmentCount = 2

        let mqtt = MQTTService(
            subscribeHook: { _ in },
            unsubscribeHook: { _ in
                stopUnsubscribeExpectation.fulfill()
            }
        )
        let service = TeamclawService()
        let container = try makeModelContainer()

        service.configureRuntimeForTesting(
            mqtt: mqtt,
            teamId: "team1",
            deviceId: "device1",
            peerId: "peer1",
            modelContainer: container
        )

        try await service.beginForegroundSession("sess-1")
        try await service.beginForegroundSession("sess-2")

        service.stop()

        await fulfillment(of: [stopUnsubscribeExpectation], timeout: 1.0)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            Set(mqtt.unsubscribedTopics),
            Set([
                MQTTTopics.sessionLive(teamID: "team1", sessionID: "sess-1"),
                MQTTTopics.sessionLive(teamID: "team1", sessionID: "sess-2"),
            ])
        )
        XCTAssertTrue(service.foregroundSessionIDs.isEmpty)
    }

    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            Session.self,
            SessionMessage.self,
            SessionTask.self,
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
