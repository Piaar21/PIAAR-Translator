import SwiftUI

// Sibling buttons avoid nested gestures: the full completion hit area excludes ⋯.
struct TodoRowView: View {
    @ObservedObject var model: TodoViewModel
    let item: TodoSnapshot
    let showMoreButton: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { model.toggleCompletion(item) } label: {
                HStack(alignment: .center, spacing: 10) {
                    TodoCompletionMark(color: TodoGroupColor.resolve(model.colorHex(for: item)), completed: item.isCompleted)
                    Text(item.title).strikethrough(item.isCompleted)
                        .foregroundStyle(item.isCompleted ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let dDay = model.dDay(item) { Text(dDay).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.isCompleted ? "완료" : "미완료")
            if showMoreButton {
                Button { model.beginFullEditing(item) } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help("할 일 수정 / 설정")
                    .accessibilityLabel("\(item.title) 수정")
            }
        }
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
