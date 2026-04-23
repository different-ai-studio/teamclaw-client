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
                MQTTTopics.teamSessions(teamID: "team1"),
                MQTTTopics.teamMembers(teamID: "team1"),
                MQTTTopics.userInvites(teamID: "team1", actorID: "peer1"),
                MQTTTopics.rpcResponseWildcard(teamID: "team1", deviceID: "device1"),
                MQTTTopics.teamTasks(teamID: "team1"),
                MQTTTopics.devicePeers(teamID: "team1", deviceID: "device1"),
                MQTTTopics.sessionLive(teamID: "team1", sessionID: "sess-1"),
            ]
        )
        XCTAssertEqual(service.foregroundSessionIDs, ["sess-1"])

        service.stop()
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
