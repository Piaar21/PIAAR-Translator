import Foundation

// The repository's established base order is created_at, then id. Rebuilding it
// from identity prevents an optimistic partition from losing the reopen position.
enum TaskPresentationSorter {
    static func sort(_ tasks: [WorkTask]) -> [WorkTask] {
        tasks.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status == .open }
            if lhs.status == .completed, lhs.completedAt != rhs.completedAt {
                switch (lhs.completedAt, rhs.completedAt) {
                case let (a?, b?): return a > b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): break
                }
            }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
