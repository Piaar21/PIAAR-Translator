import SwiftUI

struct QuickAddPreview: View {
    let result: QuickAddParseResult
    var body: some View {
        Text(result.preview.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .frame(height: 18).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 28)
    }
}
