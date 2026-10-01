import SwiftUI

// The workspace opens the existing popup; its session and keyboard UX remain unchanged.
struct TranslatorLauncherView: View {
    @ObservedObject private var hotKeyManager = GlobalHotKeyManager.shared
    let openTranslator: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "character.bubble")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Translator")
                .font(.title2.bold())
            Text("텍스트를 선택한 뒤 \(hotKeyManager.shortcut.displayText)를 누르면 번역 팝업이 열립니다.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("번역 팝업 열기", action: openTranslator)
                .buttonStyle(.borderedProminent)
            Text("버튼으로 열면 클립보드의 텍스트를 번역합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Translator")
    }
}
