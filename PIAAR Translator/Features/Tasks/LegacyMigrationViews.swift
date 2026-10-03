import SwiftUI

struct MigrationSummaryView: View {
    @ObservedObject var model: LegacyTaskMigration
    let open: () -> Void
    var body: some View {
        HStack {
            Text("기존 로컬 데이터는 이 Mac에 백업으로 보존되어 있습니다.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("가져오기 검토", action: open)
        }
    }
}
struct MigrationConsentView: View {
    @ObservedObject var model: LegacyTaskMigration
    let refresh: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var approved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.result == nil ? "기존 데이터 가져오기" : "가져오기 결과").font(.headline)
            Text("기존 로컬 데이터는 이 Mac에 그대로 보존됩니다.").font(.caption).foregroundStyle(.secondary)
            if model.busy {
                HStack { ProgressView().controlSize(.small); Text("가져오는 중…") }
                    .frame(height: 36)
            } else if let r = model.result {
                count("할 일", "\(r.todosSucceeded) / \(r.todosTotal)")
                count("그룹", "\(r.groupsSucceeded) / \(r.groupsTotal)")
                count("반복 규칙", "\(r.rulesSucceeded) / \(r.rulesTotal)")
                let failures = r.todosFailed + r.groupsFailed + r.rulesFailed
                if failures > 0 { Text("\(failures)개 항목을 가져오지 못했습니다.").font(.caption) }
                if r.pending > 0 { Text("\(r.pending)개 항목은 이전 대기로 원본에 남아 있습니다.").font(.caption) }
                if r.completionConstraintFailure { Text("완료 시각이 없는 항목을 서버에서 허용하는지 확인이 필요합니다. 임의 시각은 추가하지 않았습니다.").font(.caption) }
                if r.calendarFailures > 0 { Text("기기 Calendar 연결 \(r.calendarFailures)개를 보존하지 못했습니다. 다시 시도해주세요.").font(.caption) }
            } else if let p = model.preview {
                count("할 일", "\(p.totalTodos)개")
                count("그룹", "\(p.groups)개")
                count("반복 할 일", "\(p.repeatedTodos)개")
                count("메모가 있는 할 일", "\(p.notesIncluded)개")
                Divider()
                count("새로 가져올 할 일", "\(p.importable)개")
                count("이미 가져온 항목", "\(p.alreadyImported)개")
                if p.pendingTodos + p.pendingRepeatTemplates > 0 {
                    Text("해석할 수 없는 항목 \(p.pendingTodos + p.pendingRepeatTemplates)개는 원본에 보존합니다.").font(.caption)
                }
                if p.repeatTemplatesReady > 0 {
                    Text("반복은 이 Mac의 현재 시간대(\(TimeZone.current.identifier))로 가져옵니다.").font(.caption).foregroundStyle(.secondary)
                }
                if p.missingCompletionTimes > 0 {
                    Text("완료 시각이 없는 할 일 \(p.missingCompletionTimes)개는 시각을 비워서 가져옵니다.").font(.caption)
                }
                if p.duplicateRepeatDates > 0 {
                    Text("같은 반복·날짜의 중복 항목 \(p.duplicateRepeatDates)개는 하나의 서버 항목을 재사용합니다. 서로 다른 내용은 합치지 않으며 원본에 남습니다.").font(.caption)
                }
                Toggle("현재 로그인한 계정으로 가져오기를 승인합니다", isOn: $approved)
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !LegacyTaskMigration.isEnabled { Text("가져오기는 Debug 앱에서만 실행할 수 있습니다.").font(.caption) }
            HStack {
                Button(model.result == nil ? "취소" : "닫기") { dismiss() }.disabled(model.busy)
                Spacer()
                if model.result != nil {
                    Button("다시 시도") { runImport() }.disabled(model.busy || !LegacyTaskMigration.isEnabled)
                } else {
                    Button("미리보기 갱신") { approved = false; Task { await model.loadPreview() } }.disabled(model.busy)
                    Button("가져오기") { runImport() }
                        .disabled(!approved || model.preview == nil || model.busy || !LegacyTaskMigration.isEnabled)
                }
            }
        }.padding(24).frame(width: 440).interactiveDismissDisabled(model.busy)
            .task { await model.loadPreview() }
    }
    private func count(_ name: String, _ value: String) -> some View {
        HStack { Text(name); Spacer(); Text(value).monospacedDigit() }
    }
    private func runImport() {
        Task { await model.migrate(approvedUserID: model.userID); await refresh() }
    }
}
