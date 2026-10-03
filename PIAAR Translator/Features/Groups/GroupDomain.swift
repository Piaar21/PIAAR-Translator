import Foundation
struct TaskGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var colorHex: String?
    let ownerID: UUID
    let spaceID: UUID?
    var sortOrder: Int
    let createdAt: Date
    let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, name, colorHex = "color_hex", ownerID = "owner_id", spaceID = "space_id"
        case sortOrder = "sort_order", createdAt = "created_at", updatedAt = "updated_at"
    }
}
@MainActor protocol GroupRepository {
    var userID: UUID { get }
    func personalGroups() async throws -> [TaskGroup]
    func groups(spaceID: UUID) async throws -> [TaskGroup]
    func create(id: UUID, name: String, colorHex: String?, sortOrder: Int) async throws -> TaskGroup
    func rename(id: UUID, name: String, colorHex: String?) async throws
    func delete(id: UUID) async throws
    func reorder(ids: [UUID]) async throws
    func createSpaceGroup(id: UUID, spaceID: UUID, name: String, colorHex: String?, sortOrder: Int) async throws -> TaskGroup
    func renameSpaceGroup(id: UUID, spaceID: UUID, name: String, colorHex: String?) async throws
    func deleteSpaceGroup(id: UUID, spaceID: UUID) async throws
    func fetchGroup(id: UUID) async throws -> TaskGroup?
}
