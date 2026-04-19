import Foundation
import Observation
import SwiftData

@Observable @MainActor
public final class MemberListViewModel {
    public var members: [Member] = []
    /// memberIds of members whose devices are currently connected to the
    /// daemon, derived from the retained PeerList on amux/{deviceId}/peers.
    public var onlineMemberIds: Set<String> = []
    private var task: Task<Void, Never>?

    public init() {}

    public func isOnline(_ member: Member) -> Bool {
        onlineMemberIds.contains(member.memberId)
    }

    public func start(mqtt: MQTTService, deviceId: String, modelContext: ModelContext) {
        // Load cached members immediately
        members = (try? modelContext.fetch(FetchDescriptor<Member>(sortBy: [SortDescriptor(\.displayName)]))) ?? []

        task?.cancel()
        task = Task {
            let membersTopic = "amux/\(deviceId)/members"
            let peersTopic = "amux/\(deviceId)/peers"
            let stream = mqtt.messages()
            // Subscribing triggers delivery of the retained messages on both topics.
            try? await mqtt.subscribe(membersTopic)
            try? await mqtt.subscribe(peersTopic)
            for await msg in stream {
                if msg.topic == membersTopic {
                    if let list = try? ProtoMQTTCoder.decode(Amux_MemberList.self, from: msg.payload) {
                        syncMembers(list, modelContext: modelContext)
                    }
                } else if msg.topic == peersTopic {
                    if let list = try? ProtoMQTTCoder.decode(Amux_PeerList.self, from: msg.payload) {
                        onlineMemberIds = Set(list.peers.map(\.memberID).filter { !$0.isEmpty })
                    }
                }
            }
        }
    }

    private func syncMembers(_ list: Amux_MemberList, modelContext: ModelContext) {
        for proto in list.members {
            let id = proto.memberID
            let department: String? = proto.department.isEmpty ? nil : proto.department
            let descriptor = FetchDescriptor<Member>(predicate: #Predicate { $0.memberId == id })
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.displayName = proto.displayName
                existing.role = Int(proto.role.rawValue)
                existing.department = department
            } else {
                modelContext.insert(Member(
                    memberId: proto.memberID,
                    displayName: proto.displayName,
                    role: Int(proto.role.rawValue),
                    joinedAt: Date(timeIntervalSince1970: TimeInterval(proto.joinedAt)),
                    department: department
                ))
            }
        }
        try? modelContext.save()
        members = (try? modelContext.fetch(FetchDescriptor<Member>(sortBy: [SortDescriptor(\.displayName)]))) ?? []
    }

    public func invite(displayName: String, role: Amux_MemberRole = .member, mqtt: MQTTService, deviceId: String, peerId: String) async throws {
        var cmd = Amux_DeviceCommandEnvelope()
        cmd.deviceID = deviceId; cmd.peerID = peerId
        cmd.commandID = UUID().uuidString; cmd.timestamp = Int64(Date().timeIntervalSince1970)
        var invite = Amux_InviteMember(); invite.displayName = displayName; invite.requestID = UUID().uuidString; invite.role = role
        var collabCmd = Amux_DeviceCollabCommand(); collabCmd.command = .inviteMember(invite)
        cmd.command = collabCmd
        let data = try ProtoMQTTCoder.encode(cmd)
        try await mqtt.publish(topic: "amux/\(deviceId)/collab", payload: data)
    }

    public enum InviteError: Error {
        case duplicateName
        case timedOut
        case rejected(String)
    }

    /// Publishes an InviteMember command and waits for the daemon to respond
    /// with an InviteCreated event on amux/{deviceId}/collab. Returns the
    /// shareable deeplink + token + expiry from the daemon.
    public func inviteAndWait(displayName: String,
                              role: Amux_MemberRole = .member,
                              mqtt: MQTTService,
                              deviceId: String,
                              peerId: String,
                              timeout: TimeInterval = 10) async throws -> Amux_InviteCreated {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if members.contains(where: { $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw InviteError.duplicateName
        }

        let collabTopic = "amux/\(deviceId)/collab"
        try? await mqtt.subscribe(collabTopic)

        // Start listening BEFORE publishing so we don't miss a fast response.
        let stream = mqtt.messages()

        let requestId = UUID().uuidString
        let commandId = UUID().uuidString
        var cmd = Amux_DeviceCommandEnvelope()
        cmd.deviceID = deviceId
        cmd.peerID = peerId
        cmd.commandID = commandId
        cmd.timestamp = Int64(Date().timeIntervalSince1970)
        var invite = Amux_InviteMember()
        invite.displayName = trimmed
        invite.requestID = requestId
        invite.role = role
        var collabCmd = Amux_DeviceCollabCommand()
        collabCmd.command = .inviteMember(invite)
        cmd.command = collabCmd
        let data = try ProtoMQTTCoder.encode(cmd)
        try await mqtt.publish(topic: collabTopic, payload: data)

        let deadline = Date().addingTimeInterval(timeout)
        for await msg in stream {
            if Date() > deadline { break }
            guard msg.topic == collabTopic,
                  let event = try? ProtoMQTTCoder.decode(Amux_DeviceCollabEvent.self, from: msg.payload)
            else { continue }
            switch event.event {
            case .inviteCreated(let created) where created.requestID == requestId:
                return created
            case .commandRejected(let rej)
                where !rej.reason.isEmpty && (rej.commandID == commandId || rej.commandID.isEmpty):
                throw InviteError.rejected(rej.reason)
            default:
                continue
            }
        }
        throw InviteError.timedOut
    }
}
