import SwiftUI

// MARK: - HotKey Settings View

struct HotKeySettingsView: View {

    @ObservedObject private var hotKeyManager =
        GlobalHotKeyManager.shared

    @ObservedObject private var todoHotKeyManager = GlobalHotKeyManager.todoShared

    @ObservedObject private var launchAtLoginManager =
        LaunchAtLoginManager.shared

    @ObservedObject private var keychainManager =
        KeychainManager.shared


    @State private var recordingFeature: GlobalHotKeyFeature?

    @State private var apiKeyInput =
        ""

    @State private var showingDeleteConfirmation =
        false


    var body: some View {

        ScrollView {
            VStack(
                alignment: .leading,
                spacing: 0
            ) {

                shortcutSection(title: "번역기 단축키", manager: hotKeyManager, feature: .translator)
                Divider().padding(.vertical, 16)
                shortcutSection(title: "Todo 단축키", manager: todoHotKeyManager, feature: .todo)
                Divider().padding(.vertical, 16)

                // MARK: 로그인 시 자동 실행

                HStack(
                    alignment: .center,
                    spacing: 12
                ) {

                    VStack(
                        alignment: .leading,
                        spacing: 4
                    ) {

                        Text(
                            "로그인 시 자동 실행"
                        )
                        .font(
                            .system(
                                size: 12,
                                weight: .medium
                            )
                        )


                        Text(
                            "Mac에 로그인하면 PIAAR Work를 자동으로 실행합니다."
                        )
                        .font(
                            .system(size: 10)
                        )
                        .foregroundStyle(
                            .secondary
                        )
                    }


                    Spacer()


                    Toggle(
                        "",
                        isOn:
                            Binding(
                                get: {

                                    launchAtLoginManager
                                        .isEnabled
                                },

                                set: {
                                    newValue in

                                    launchAtLoginManager
                                        .setEnabled(
                                            newValue
                                        )
                                }
                            )
                    )
                    .labelsHidden()
                    .toggleStyle(
                        .switch
                    )
                    .controlSize(
                        .small
                    )
                }


                if let error =
                    launchAtLoginManager
                        .errorMessage {

                    Text(error)
                        .font(
                            .system(size: 10)
                        )
                        .foregroundStyle(
                            .red
                        )
                        .padding(
                            .top,
                            7
                        )
                }


                Divider()
                    .padding(
                        .vertical,
                        16
                    )


                // MARK: OpenAI API

                Text("OpenAI API")
                    .font(
                        .system(
                            size: 13,
                            weight: .semibold
                        )
                    )


                Text(
                    "API Key는 이 Mac의 Keychain에 안전하게 저장됩니다."
                )
                .font(
                    .system(size: 10)
                )
                .foregroundStyle(
                    .secondary
                )
                .padding(
                    .top,
                    4
                )


                HStack(
                    spacing: 8
                ) {

                    SecureField(
                        keychainManager.hasAPIKey
                        ? "새 API Key를 입력하면 기존 Key가 변경됩니다."
                        : "OpenAI API Key 입력",

                        text:
                            $apiKeyInput
                    )
                    .textFieldStyle(
                        .roundedBorder
                    )
                    .font(
                        .system(size: 11)
                    )


                    Button("저장") {

                        if keychainManager
                            .saveAPIKey(
                                apiKeyInput
                            ) {

                            apiKeyInput =
                                ""
                        }
                    }
                    .controlSize(
                        .small
                    )
                    .disabled(
                        apiKeyInput
                            .trimmingCharacters(
                                in:
                                    .whitespacesAndNewlines
                            )
                            .isEmpty
                    )
                }
                .padding(
                    .top,
                    10
                )


                HStack(
                    spacing: 7
                ) {

                    Circle()
                        .fill(
                            keychainManager
                                .hasAPIKey
                            ? Color.green
                            : Color.secondary
                        )
                        .frame(
                            width: 7,
                            height: 7
                        )


                    Text(
                        keychainManager.apiKeyStatusText
                    )
                    .font(
                        .system(
                            size: 10.5,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(
                        keychainManager
                            .hasAPIKey
                        ? .primary
                        : .secondary
                    )


                    Spacer()


                    if keychainManager
                        .hasAPIKey {

                        Button(
                            "삭제"
                        ) {

                            showingDeleteConfirmation =
                                true
                        }
                        .buttonStyle(
                            .plain
                        )
                        .font(
                            .system(size: 10)
                        )
                        .foregroundStyle(
                            .red
                        )
                    }
                }
                .padding(
                    .top,
                    10
                )


                if let message =
                    keychainManager
                        .statusMessage {

                    Text(message)
                        .font(
                            .system(size: 10)
                        )
                        .foregroundStyle(
                            keychainManager
                                .isError
                            ? Color.red
                            : Color.secondary
                        )
                        .padding(
                            .top,
                            6
                        )
                }


                Spacer()
            }
            .padding(20)
        }
        .frame(
            minWidth: 420,
            idealWidth: 420,
            maxWidth: .infinity,

            minHeight: 600,
            idealHeight: 600,
            maxHeight: .infinity,

            alignment:
                .topLeading
        )
        .onChange(of: recordingFeature) { oldValue, newValue in
            if oldValue == nil, newValue != nil { GlobalHotKeyPair.shared.unregister() }
            if oldValue != nil, newValue == nil { GlobalHotKeyPair.shared.resumeAfterRecording() }
        }
        .onDisappear {
            if recordingFeature != nil {
                recordingFeature = nil
                GlobalHotKeyPair.shared.resumeAfterRecording()
            }
        }
        .onAppear {

            launchAtLoginManager
                .refreshStatus()

            keychainManager
                .refreshStatus()
        }
        .alert(
            "API Key 삭제",
            isPresented:
                $showingDeleteConfirmation
        ) {

            Button(
                "취소",
                role: .cancel
            ) {
            }


            Button(
                "삭제",
                role: .destructive
            ) {

                _ =
                    keychainManager
                        .deleteAPIKey()

                apiKeyInput =
                    ""
            }

        } message: {

            Text(
                "이 Mac에 저장된 OpenAI API Key를 삭제하시겠습니까?"
            )
        }
    }
    private func shortcutSection(title: String, manager: GlobalHotKeyManager,
                                 feature: GlobalHotKeyFeature) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text("아래 영역을 클릭한 후 원하는 단축키를 누르세요.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HotKeyRecorderView(isRecording: Binding(
                get: { recordingFeature == feature },
                set: { recordingFeature = $0 ? feature : (recordingFeature == feature ? nil : recordingFeature) }
            ), shortcutText: manager.shortcut.displayText) { keyCode, modifiers in
                _ = manager.updateShortcut(keyCode: keyCode, modifiers: modifiers)
                recordingFeature = nil
            }
            .frame(height: 42)
            if let error = manager.registrationError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
            HStack {
                Button("기본값으로 복원") {
                    _ = manager.restoreDefault()
                    recordingFeature = nil
                }.controlSize(.small)
                Spacer()
                Text("기본값 \(feature.defaultShortcut.displayText)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

}
