import Foundation
import SwiftData

// Frozen V1 model definitions preserve the original on-disk checksum.
// Never edit V1 or recover from migration errors by deleting the store.
@available(macOS 14.0, *)
enum TodoSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [TodoItem.self, TodoGroup.self] }

    @Model
    final class TodoItem {
        // Defaults and optional relationships leave room for a future sync migration.
        // No uniqueness constraint: IDs are assigned by the repository.
        var id: UUID = UUID()
        var title: String = ""
        var notes: String?
        var date: Date = Date()
        var isCompleted: Bool = false
        var completedAt: Date?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var sortOrder: Int = 0
        var repeatRule: String?
        var linkedCalendarEventID: String?
        var group: TodoGroup?

        init(title: String, notes: String? = nil, date: Date, sortOrder: Int = 0,
             group: TodoGroup? = nil, now: Date = Date()) {
            self.title = title
            self.notes = notes
            self.date = date
            self.sortOrder = sortOrder
            self.group = group
            self.createdAt = now
            self.updatedAt = now
        }
    }


    @Model
    final class TodoGroup {
        var id: UUID = UUID()
        var name: String = ""
        var colorHex: String?
        var sortOrder: Int = 0
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        @Relationship(deleteRule: .nullify, inverse: \TodoItem.group)
        var items: [TodoItem]? = []

        init(name: String, colorHex: String? = nil, sortOrder: Int = 0, now: Date = Date()) {
            self.name = name
            self.colorHex = colorHex
            self.sortOrder = sortOrder
            self.createdAt = now
            self.updatedAt = now
        }
    }

}

@available(macOS 14.0, *)
enum TodoSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [TodoItem.self, TodoGroup.self, TodoRepeatSchedule.self] }

@Model
final class TodoItem {
    // Defaults and optional relationships leave room for a future sync migration.
    // No uniqueness constraint: IDs are assigned by the repository.
    var id: UUID = UUID()
    var title: String = ""
    var notes: String?
    var date: Date = Date()
    var isCompleted: Bool = false
    var completedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var sortOrder: Int = 0
    var repeatRule: String?
    var linkedCalendarEventID: String?
    var startDateTime: Date?
    var deadlineDateTime: Date?
    var repeatScheduleID: UUID?
    var group: TodoGroup?

    init(title: String, notes: String? = nil, date: Date, sortOrder: Int = 0,
         group: TodoGroup? = nil, now: Date = Date()) {
        self.title = title
        self.notes = notes
        self.date = date
        self.sortOrder = sortOrder
        self.group = group
        self.createdAt = now
        self.updatedAt = now
    }
}


@Model
final class TodoGroup {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String?
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \TodoItem.group)
    var items: [TodoItem]? = []

    init(name: String, colorHex: String? = nil, sortOrder: Int = 0, now: Date = Date()) {
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = now
        self.updatedAt = now
    }
}


// A persistent template, independent of the completion state of daily instances.
// Scalar defaults and no uniqueness constraints permit a future CloudKit migration.
@Model
final class TodoRepeatSchedule {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String?
    var groupID: UUID?
    var weekdayMask: Int = 0
    var beginsOn: Date = Date()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deadlineDayOffset: Int?
    var startMinutes: Int?
    var deadlineMinutes: Int?

    init(title: String, beginsOn: Date, now: Date) {
        self.title = title
        self.beginsOn = beginsOn
        self.createdAt = now
        self.updatedAt = now
    }
}

}
@available(macOS 14.0, *)
enum TodoSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { [TodoItem.self, TodoGroup.self, TodoRepeatSchedule.self] }
}

@available(macOS 14.0, *)
enum TodoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TodoSchemaV1.self, TodoSchemaV2.self, TodoSchemaV3.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: TodoSchemaV1.self, toVersion: TodoSchemaV2.self),
         .lightweight(fromVersion: TodoSchemaV2.self, toVersion: TodoSchemaV3.self)]
    }
}

enum TodoPersistence {
    // Deliberately independent of the display name and the app bundle location.
    static let directoryName = "com.piaar.PIAAR-Translator/Todo"
    static let fileName = "Todo.store"

    static func storeURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask, appropriateFor: nil, create: false)
        return support.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    @available(macOS 14.0, *)
    @MainActor
    static func makeContainer(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: TodoSchemaV3.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration("Todo", schema: schema,
                isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let url = try storeURL ?? self.storeURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            configuration = ModelConfiguration("Todo", schema: schema, url: url,
                                               cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: TodoMigrationPlan.self,
                                  configurations: [configuration])
    }
}
