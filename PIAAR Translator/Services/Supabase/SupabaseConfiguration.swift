import Foundation

struct SupabaseConfiguration {
    let projectURL: URL
    let publishableKey: String
    init(projectURL: String, publishableKey: String) throws {
        let key = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: projectURL), url.scheme == "https", url.host != nil,
              key.hasPrefix("sb_publishable_"), key.count > "sb_publishable_".count,
              !key.contains(where: { $0.isWhitespace }) else { throw CollaborationAuthError.configuration }
        self.projectURL = url; self.publishableKey = key
    }
    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "SupabaseConfiguration", withExtension: "plist"),
              let values = NSDictionary(contentsOf: url),
              let project = values["ProjectURL"] as? String,
              let key = values["PublishableKey"] as? String else { throw CollaborationAuthError.configuration }
        return try Self(projectURL: project, publishableKey: key)
    }
}
