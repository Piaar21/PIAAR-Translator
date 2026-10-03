import Foundation
import OSLog
import Supabase

// No titles, notes, tokens, request URLs or server error details in diagnostics.
enum MigrationDiagnostics {
    static let logger = Logger(subsystem: "com.piaar.PIAAR-Translator", category: "LegacyMigration")
    static func sessionFailure(_ error: Error) -> CollaborationAuthError? {
        if let auth = error as? CollaborationAuthError, auth == .sessionMissing || auth == .refreshFailed { return auth }
        // JWT/authentication failures only; RLS/FK/CHECK/database errors are not session loss.
        if let code = (error as? PostgrestError)?.code, ["PGRST301", "PGRST302", "PGRST303"].contains(code) { return .sessionMissing }
        return nil
    }
    static func isCheckViolation(_ error: Error) -> Bool { (error as? PostgrestError)?.code == "23514" }
    static func summary(phase: String, todos: Int, groups: Int, rules: Int, failed: Int) {
        #if DEBUG
        logger.info("phase=\(phase, privacy: .public) todos=\(todos, privacy: .public) groups=\(groups, privacy: .public) rules=\(rules, privacy: .public) failed=\(failed, privacy: .public)")
        #endif
    }
    static func failure(_ error: Error, phase: String, id: UUID?) {
        #if DEBUG
        let code = (error as? PostgrestError)?.code ?? (error as? URLError).map { String($0.code.rawValue) } ?? String(describing: type(of: error))
        logger.error("phase=\(phase, privacy: .public) code=\(code, privacy: .public) item=\(id?.uuidString ?? "none", privacy: .private)")
        #endif
    }
}
