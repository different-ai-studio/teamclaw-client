import SwiftUI

public struct ConnectionStatusBadge: View {
    let isOnline: Bool
    let deviceName: String?

    public init(isOnline: Bool, deviceName: String? = nil) {
        self.isOnline = isOnline
        self.deviceName = deviceName
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isOnline ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isOnline ? (deviceName ?? "Daemon Online") : "Daemon Offline")
                .font(.caption2)
                .foregroundStyle(isOnline ? Color(.secondaryLabel) : Color.red)
        }
    }
}
