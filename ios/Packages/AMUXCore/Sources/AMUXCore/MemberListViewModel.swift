import Foundation
import Observation
import SwiftData

@Observable @MainActor
public final class MemberListViewModel {
    public var members: [Member] = []
    private var task: Task<Void, Never>?

    public init() {}

    public func start(mqtt: MQTTService, deviceId: String, modelContext: ModelContext) {
        // Load cached members immediately
        members = (try? modelContext.fetch(FetchDescriptor<Member>(sortBy: [SortDescriptor(\.displayName)]))) ?? []

        task?.cancel()
        task = Task {
            let topic = "amux/\(deviceId)/members"
            let stream = mqtt.messages()
            // Subscribe triggers delivery of retained member list
            try? await mqtt.subscribe(topic)
            for await msg in stream {
                guard msg.topic == topic else { continue }
                guard let list = try? ProtoMQTTCoder.decode(Amux_MemberList.self, from: msg.payload) else { continue }
                syncMembers(list, modelContext: modelContext)
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
    }
}
