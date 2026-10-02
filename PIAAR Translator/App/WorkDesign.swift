import SwiftUI

// Full-only metrics. Mini keeps its established compact layout.
enum WorkDesign {
    static let readingWidth: CGFloat = 668
    private static let adaptiveContent = NSColor(name: nil, dynamicProvider: { appearance in
        var color = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.windowBackgroundColor.blended(withFraction: 0.4, of: .textBackgroundColor) ?? .windowBackgroundColor
        }
        return color
    })
    static let contentBackground = Color(nsColor: adaptiveContent)
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
    static let softControl = Color.primary.opacity(0.035)
    static let padding: CGFloat = 24
    static let sectionSpacing: CGFloat = 26
    static let innerSpacing: CGFloat = 8
    static let rowHeight: CGFloat = 44
    static let inputHeight: CGFloat = 44
    static let radius: CGFloat = 10
    static let title = Font.system(size: 23, weight: .semibold)
    static let section = Font.system(size: 15, weight: .semibold)
    static let todo = Font.system(size: 15, weight: .medium)
    static let person = Font.system(size: 15, weight: .medium)
    static let secondary = Font.system(size: 12)
}

private struct WorkFullRowsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var workFullRows: Bool {
        get { self[WorkFullRowsKey.self] }
        set { self[WorkFullRowsKey.self] = newValue }
    }
}

struct WorkEmptyState: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: WorkDesign.innerSpacing) {
            Text(title).font(WorkDesign.todo)
            if let detail { Text(detail).font(WorkDesign.secondary) }
        }.foregroundStyle(.secondary).padding(.vertical, 12)
    }
}

struct WorkSearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: WorkDesign.innerSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("이름 또는 코드 검색...", text: $text).textFieldStyle(.plain)
        }.font(WorkDesign.todo).padding(.horizontal, 12).frame(height: WorkDesign.inputHeight)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WorkDesign.radius))
    }
}

extension View {
    func workSheet() -> some View {
        self.padding(WorkDesign.padding).controlSize(.regular)
    }
}

struct WorkHoverSurface: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.background(hovered ? Color.primary.opacity(0.035) : Color.clear,
                           in: RoundedRectangle(cornerRadius: WorkDesign.radius))
            .onHover { hovered = $0 }
    }
}
