import SwiftUI
import AppKit

struct FullTodoView: View {
    @ObservedObject var model: TodoViewModel
    @State private var month = Date()
    @State private var calendarOpen = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { month = model.fullDate; calendarOpen = true } label: {
                    HStack(spacing: 8) {
                        Text(model.fullDate.formatted(.dateTime.year().month().day())).font(.title3).fontWeight(.semibold)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
                    .popover(isPresented: $calendarOpen) {
                        VStack(spacing: 12) {
                            TodoMonthView(month: $month, selected: model.fullDate, today: model.todayDate,
                                overdueDays: model.overdueDays, calendar: model.calendar) {
                                    model.selectFullDate($0); calendarOpen = false
                                }
                            Button("오늘") { model.openFullToday(); calendarOpen = false }
                        }.padding(16).frame(width: 290)
                    }
                Spacer()
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TodoQuickInput(text: $model.quickTitle, focusRevision: model.quickFocusRequest,
                    wantsFocus: model.quickWantsFocus, submit: { _ = model.submitFullQuickEntry() },
                    cancel: model.cancelQuickEntry, newShortcut: model.focusFullQuickEntry,
                    placeholder: "할 일을 입력하세요...").frame(height: 24)
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(model.fullSections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 7) {
                                Circle().fill(TodoGroupColor.resolve(section.group?.colorHex)).frame(width: 7, height: 7)
                                Text(section.group?.name ?? "그룹 없음").font(.subheadline).fontWeight(.medium)
                                Text("\(section.items.count)개").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(section.items) { item in
                                TodoRowView(model: model, item: item, showMoreButton: true)
                            }
                            if let entry = model.groupQuickEntry, entry.groupID == section.id {
                                TodoQuickInput(text: Binding(get: { model.groupQuickEntry?.title ?? "" },
                                    set: model.updateGroupQuickTitle), focusRevision: model.groupQuickFocusRequest,
                                    wantsFocus: true, submit: { _ = model.submitGroupQuickEntry() },
                                    cancel: model.cancelGroupQuickEntry, newShortcut: model.focusFullQuickEntry,
                                    placeholder: "할 일을 입력하세요...").frame(height: 24)
                            } else {
                                HStack {
                                    Spacer()
                                    Button { model.beginGroupQuickEntry(groupID: section.id) } label: {
                                        Image(systemName: "plus").frame(width: 28, height: 24).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help("\(section.group?.name ?? "그룹 없음")에 할 일 추가")
                                    Spacer()
                                }
                            }
                        }
                    }
                }.padding(.vertical, 4)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $model.fullEditor) { session in TodoEditorView(model: model, initial: session) }
            .onAppear { model.refresh() }
            .onReceive(timer) { _ in model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in model.refresh() }
    }
}

// Shared by Full sections and Mini rows; invalid/missing colors use semantic gray.
enum TodoGroupColor {
    static func resolve(_ hex: String?) -> Color {
        guard let rgb = TodoGroupColors.rgb(hex) else { return Color(nsColor: .systemGray) }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: rgb.alpha)
    }
}
private struct TodoMonthView: View {
    @Binding var month: Date
    let selected: Date
    let today: Date
    let overdueDays: Set<Date>
    let calendar: Calendar
    let select: (Date) -> Void

    private var monthStart: Date { calendar.dateInterval(of: .month, for: month)!.start }
    private var offset: Int { (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7 }
    private var count: Int { calendar.range(of: .day, in: .month, for: monthStart)!.count }
    private var symbols: [String] {
        let values = calendar.veryShortWeekdaySymbols
        return (0..<7).map { values[(calendar.firstWeekday - 1 + $0) % 7] }
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.help("이전 월")
                Spacer()
                Text(monthStart.formatted(.dateTime.year().month(.wide))).font(.headline)
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right") }.help("다음 월")
            }.buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(0..<7, id: \.self) { index in Text(symbols[index]).font(.caption).foregroundStyle(.secondary) }
                ForEach(0..<((count + offset + 6) / 7 * 7), id: \.self) { index in
                    if index >= offset && index < offset + count,
                       let date = calendar.date(byAdding: .day, value: index - offset, to: monthStart) {
                        Button { select(date) } label: {
                            VStack(spacing: 3) {
                                Text("\(index - offset + 1)").font(.callout)
                                    .fontWeight(calendar.isDate(date, inSameDayAs: today) ? .bold : .regular)
                                    .foregroundStyle(calendar.isDate(date, inSameDayAs: selected) ? Color.white :
                                                        (calendar.isDate(date, inSameDayAs: today) ? Color.accentColor : Color.primary))
                                Circle().fill(overdueDays.contains(calendar.startOfDay(for: date)) ? Color.red : Color.clear)
                                    .frame(width: 4, height: 4)
                            }.frame(maxWidth: .infinity).frame(height: 30)
                                .background(calendar.isDate(date, inSameDayAs: selected) ? Color.accentColor : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                            .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                            .accessibilityValue(overdueDays.contains(calendar.startOfDay(for: date)) ? "미완료 할 일 있음" : "")
                    } else { Color.clear.frame(height: 30) }
                }
            }
        }
    }
    private func move(_ offset: Int) {
        if let date = calendar.date(byAdding: .month, value: offset, to: monthStart) { month = date }
    }
}

