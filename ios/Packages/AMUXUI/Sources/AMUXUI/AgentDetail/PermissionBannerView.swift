import SwiftUI

public struct PermissionBannerView: View {
    let toolName: String
    let description: String
    let requestId: String
    let isResolved: Bool
    let wasGranted: Bool?
    let onGrant: ((String) -> Void)?
    let onDeny: ((String) -> Void)?

    public init(toolName: String, description: String, requestId: String,
                isResolved: Bool = false, wasGranted: Bool? = nil,
                onGrant: ((String) -> Void)?, onDeny: ((String) -> Void)?) {
        self.toolName = toolName; self.description = description; self.requestId = requestId
        self.isResolved = isResolved; self.wasGranted = wasGranted
        self.onGrant = onGrant; self.onDeny = onDeny
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").foregroundStyle(.primary)
                Text("Permission Request").font(.subheadline).fontWeight(.semibold)
            }
            Text("\(toolName): \(description)").font(.caption).foregroundStyle(.secondary)

            if isResolved {
                HStack(spacing: 6) {
                    Image(systemName: wasGranted == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(.primary)
                    Text(wasGranted == true ? "Allowed" : "Denied")
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(wasGranted == true ? .green : .red)
                }
            } else {
                HStack(spacing: 12) {
                    Button { onDeny?(requestId) } label: {
                        Text("Deny").font(.subheadline).fontWeight(.medium).frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .liquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: false)
                    }
                    Button { onGrant?(requestId) } label: {
                        Text("Allow").font(.subheadline).fontWeight(.medium).frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .liquidGlass(in: RoundedRectangle(cornerRadius: 8), interactive: false)
                    }
                }
            }
        }
        .padding(12).liquidGlass(in: RoundedRectangle(cornerRadius: 12), interactive: false)
    }
}
