import Foundation

public enum MQTTTopics {
    public static func normalizedTeamID(_ teamID: String) -> String {
        teamID.isEmpty ? "teamclaw" : teamID
    }

    public static func deviceBase(teamID: String, deviceID: String) -> String {
        "amux/\(normalizedTeamID(teamID))/device/\(deviceID)"
    }

    public static func teamclawBase(teamID: String) -> String {
        "amux/\(normalizedTeamID(teamID))"
    }

    public static func deviceStatus(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/status"
    }

    public static func devicePeers(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/peers"
    }

    public static func deviceWorkspaces(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/workspaces"
    }

    public static func deviceCollab(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/collab"
    }

    public static func agentState(teamID: String, deviceID: String, agentID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/agent/\(agentID)/state"
    }

    public static func agentStateWildcard(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/agent/+/state"
    }

    public static func agentStatePrefix(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/agent/"
    }

    public static func agentEvents(teamID: String, deviceID: String, agentID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/agent/\(agentID)/events"
    }

    public static func agentCommands(teamID: String, deviceID: String, agentID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/agent/\(agentID)/commands"
    }

    public static func teamSessions(teamID: String) -> String {
        "\(teamclawBase(teamID: teamID))/sessions"
    }

    public static func teamMembers(teamID: String) -> String {
        "\(teamclawBase(teamID: teamID))/members"
    }

    public static func teamTasks(teamID: String) -> String {
        "\(teamclawBase(teamID: teamID))/tasks"
    }

    public static func userInvites(teamID: String, actorID: String) -> String {
        "\(teamclawBase(teamID: teamID))/user/\(actorID)/invites"
    }

    public static func rpcRequest(teamID: String, deviceID: String, requestID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/rpc/\(requestID)/req"
    }

    public static func rpcResponseWildcard(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/rpc/+/res"
    }

    public static func sessionMessages(teamID: String, sessionID: String) -> String {
        "\(teamclawBase(teamID: teamID))/session/\(sessionID)/messages"
    }

    public static func sessionTasks(teamID: String, sessionID: String) -> String {
        "\(teamclawBase(teamID: teamID))/session/\(sessionID)/tasks"
    }

    public static func sessionPresence(teamID: String, sessionID: String) -> String {
        "\(teamclawBase(teamID: teamID))/session/\(sessionID)/presence"
    }

    public static func actorSessionMeta(teamID: String, actorID: String, sessionID: String) -> String {
        "\(teamclawBase(teamID: teamID))/actor/\(actorID)/session/\(sessionID)/meta"
    }

    public static func actorSessionMetaWildcard(teamID: String, actorID: String) -> String {
        "\(teamclawBase(teamID: teamID))/actor/\(actorID)/session/+/meta"
    }
}
