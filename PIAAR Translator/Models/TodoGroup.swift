import Foundation
import SwiftData

@available(macOS 14.0, *)
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
