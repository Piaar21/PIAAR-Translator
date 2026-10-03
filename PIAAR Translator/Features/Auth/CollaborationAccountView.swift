import SwiftUI
import AppKit

struct CollaborationAccountView: View {
    @ObservedObject var model: AuthViewModel
    @State private var creating = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            if let profile = model.profile {
                Text("내 프로필").font(WorkDesign.title)
                Text(profile.displayName).font(.title3.weight(.medium))
                HStack {
                    Text("#" + profile.friendCode).font(.system(.body, design: .monospaced))
                    Button(copied ? "복사됨" : "복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("#" + profile.friendCode, forType: .string)
                        copied = true
                    }
                }
                Label("Supabase · 로그인됨", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                TextField("이름", text: $name).textFieldStyle(.roundedBorder)
                Button("이름 저장") { Task { await model.rename(name) } }.disabled(model.isBusy)
                Button("프로필 새로고침") { Task { await model.restore() } }.disabled(model.isBusy)
                Button("로그아웃") { Task { await model.signOut(); password = ""; name = "" } }
                    .disabled(model.isBusy)
            } else {
                Text(creating ? "PIAAR Work 시작하기" : "협업 로그인").font(WorkDesign.title)
                Text("PIAAR Work를 사용하려면 로그인해주세요.")
                    .font(WorkDesign.secondary).foregroundStyle(.secondary)
                if model.state == .checkingSession {
                    ProgressView("로그인 확인 중…")
                } else {
                    if creating { TextField("이름", text: $name).textFieldStyle(.roundedBorder) }
                    TextField("이메일", text: $email).textFieldStyle(.roundedBorder)
                    SecureField("비밀번호", text: $password).textFieldStyle(.roundedBorder)
                    HStack {
                        Button(creating ? "계정 만들기" : "로그인") {
                            let value = password
                            Task {
                                if creating { await model.signUp(name: name, email: email, password: value) }
                                else { await model.signIn(email: email, password: value) }
                                password = ""
                            }
                        }.buttonStyle(.borderedProminent).disabled(model.isBusy)
                        Button(creating ? "로그인으로" : "회원가입") { creating.toggle(); password = "" }
                            .disabled(model.isBusy)
                    }
                    if model.state == .needsEmailConfirmation {
                        Text("인증 메일을 확인해주세요. 인증 후 이메일과 비밀번호로 로그인해주세요.")
                            .foregroundStyle(.secondary)
                    }
                    Button("세션 / 프로필 다시 확인") { Task { await model.restore() } }.disabled(model.isBusy)
                }
            }
            if model.isBusy && model.state != .checkingSession { ProgressView() }
            if let error = model.error { Text(error.localizedDescription).foregroundStyle(.red).font(WorkDesign.secondary) }
            Spacer(minLength: 0)
        }.frame(maxWidth: 340, alignment: .leading).padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
            .onAppear { name = model.profile?.displayName ?? "" }
            .onChange(of: model.profile?.displayName) { _, value in if let value { name = value } }
    }
}

// Existing Mock behavior stays available and is explicitly separate from the real account.
struct CollaborationFeatureGate<Content: View>: View {
    @ObservedObject var account: AuthViewModel
    @ViewBuilder let content: () -> Content
    var body: some View {
        if account.profile == nil {
            CollaborationAccountView(model: account)
        } else {
            VStack(spacing: 0) {
                Text("Mock 협업 미리보기 · 실제 Supabase 계정과 별도이며 서버에 저장되지 않습니다.")
                    .font(WorkDesign.secondary).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                content()
            }
        }
    }
}
