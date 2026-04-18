import Foundation
import SwiftData

/// Canonical SwiftData schema for the app. Declaring this as a `VersionedSchema`
/// and passing it through a `SchemaMigrationPlan` stops SwiftData from falling
/// back to *destructive* migration the moment it can't auto-derive a
/// lightweight migration — the silent-wipe that nuked rc19 users' local
/// agents/workspaces/workitems when the `archived` field landed on `WorkItem`.
///
/// Whenever you change the shape of ANY `@Model` class in this module
/// (add/remove/rename a field, change an attribute type, etc.), you MUST:
///
/// 1. Copy the current shape of each changed model into a new `AMUXSchemaV<N>`
///    enum that snapshots the pre-change types (typically by nesting frozen
///    `@Model` classes inside the enum).
/// 2. Bump `models` on the next schema version to the new shape.
/// 3. Append a `MigrationStage` to `AMUXMigrationPlan.stages` describing the
///    transition (`.lightweight(fromVersion:toVersion:)` for default-filled
///    additive changes; `.custom` for anything needing data transformation).
/// 4. Register the new version in `AMUXMigrationPlan.schemas`.
///
/// If you don't do this, SwiftData may again wipe the on-device store on
/// upgrade.
public enum AMUXSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            Agent.self,
            AgentEvent.self,
            Member.self,
            Workspace.self,
            CollabSession.self,
            SessionMessage.self,
            WorkItem.self,
        ]
    }
}

public enum AMUXMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [AMUXSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
