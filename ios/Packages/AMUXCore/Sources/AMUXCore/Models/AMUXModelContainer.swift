import SwiftData

public enum AMUXModelContainerFactory {
    public static func make() throws -> ModelContainer {
        let schema = Schema(versionedSchema: AMUXSchemaV2.self)
        let config = ModelConfiguration(schema: schema)
        return try ModelContainer(
            for: schema,
            migrationPlan: AMUXMigrationPlan.self,
            configurations: config
        )
    }
}
