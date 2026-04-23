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

    /// Fixed device-scoped request channel for the MQTT rearchitecture.
    public static func deviceRpcRequest(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/rpc/req"
    }

    /// Fixed device-scoped response channel for the MQTT rearchitecture.
    public static func deviceRpcResponse(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/rpc/res"
    }

    /// Targeted device notification channel used to invalidate local state.
    public static func deviceNotify(teamID: String, deviceID: String) -> String {
        "\(deviceBase(teamID: teamID, deviceID: deviceID))/notify"
    }

    /// Single realtime stream for live session events in the new contract.
    public static func sessionLive(teamID: String, sessionID: String) -> String {
        "\(teamclawBase(teamID: teamID))/session/\(sessionID)/live"
    }
}
