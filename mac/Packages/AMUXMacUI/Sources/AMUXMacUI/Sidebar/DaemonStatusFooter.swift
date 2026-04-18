import SwiftUI
import AMUXCore

struct DaemonStatusFooter: View {
    let pairing: PairingManager
    let monitor: ConnectionMonitor?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(monitor?.daemonOnline == true ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(monitor?.daemonOnline == true ? "Daemon online" : "Daemon offline")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
