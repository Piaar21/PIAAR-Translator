import SwiftUI

// Sibling buttons avoid nested gestures: the full completion hit area excludes ⋯.
struct TodoRowView: View {
    @ObservedObject var model: TodoViewModel
    let item: TodoSnapshot
    let showMoreButton: Bool
    @State private var hovered = false
    var sendTask: ((TodoSnapshot) -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { model.toggleCompletion(item) } label: {
                TodoRowContent(presentation: .personal(item, deadlineText: model.dDay(item)),
                               color: TodoGroupColor.resolve(model.colorHex(for: item)))
            }.buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.isCompleted ? "완료" : "미완료")
            if showMoreButton, let sendTask {
                Menu {
                    Button("수정") { model.beginFullEditing(item) }
                    Button("업무 전달") { sendTask(item) }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary).opacity(hovered ? 0.9 : 0.25).frame(width: 28, height: 28).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).fixedSize().help("할 일 수정 / 업무 전달")
            } else if showMoreButton {
                Button { model.beginFullEditing(item) } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary).opacity(hovered ? 0.9 : 0.25).frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help("할 일 수정 / 설정")
                    .accessibilityLabel("\(item.title) 수정")
            }
        }.onHover { hovered = $0 }
    }
}

private struct TodoCompletionMark: View {
    let color: Color
    let completed: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(color, lineWidth: 1.5)
            if completed {
                Circle().fill(color)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
        }.frame(width: 18, height: 18).accessibilityHidden(true)
    }
}

// UI values only; personal and shared persistence remain separate.
struct TodoRowPresentation {
    enum Direction { case none, received, sent
        var arrow: String? {
            switch self { case .none: return nil; case .received: return "←"; case .sent: return "→" }
        }
    }
    let title: String
    let isCompleted: Bool
    let direction: Direction
    let personName: String?
    let deadlineText: String?
    var isInteractive: Bool { direction != .sent }
    var personLabel: String? {
        guard let arrow = direction.arrow, let personName else { return nil }
        return arrow + " " + personName
    }
    static func personal(_ todo: TodoSnapshot, deadlineText: String?) -> Self {
        Self(title: todo.title, isCompleted: todo.isCompleted, direction: .none,
             personName: nil, deadlineText: deadlineText)
    }
    static func shared(_ task: SharedTask, received: Bool, deadlineText: String?) -> Self {
        Self(title: task.title, isCompleted: task.isCompleted, direction: received ? (task.senderUserID == task.receiverUserID ? .none : .received) : .sent,
             personName: received ? (task.senderUserID == task.receiverUserID ? nil : task.senderDisplayName) : task.receiverDisplayName, deadlineText: deadlineText)
    }
}

struct TodoRowContent: View {
    let presentation: TodoRowPresentation
    let color: Color
    var supplementalPerson: String? = nil
    var allowsHover = true
    @State private var hovered = false
    @Environment(\.workFullRows) private var full
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TodoCompletionMark(color: color, completed: presentation.isCompleted)
            Text(presentation.title).font(full ? WorkDesign.todo : .body).strikethrough(presentation.isCompleted)
                .foregroundStyle(presentation.isCompleted ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let person = presentation.personLabel ?? supplementalPerson {
                Text(person).font(full ? WorkDesign.secondary : .caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let label = presentation.deadlineText {
                Text(label).font(full ? WorkDesign.secondary : .caption).foregroundStyle(.secondary).fixedSize()
            }
        }.frame(maxWidth: .infinity, minHeight: full ? WorkDesign.rowHeight : 28, alignment: .leading)
            .contentShape(Rectangle())
            .background(hovered && allowsHover && presentation.isInteractive ? Color.primary.opacity(0.035) : Color.clear,
                        in: RoundedRectangle(cornerRadius: WorkDesign.radius))
            .onHover { hovered = $0 }
    }
}
