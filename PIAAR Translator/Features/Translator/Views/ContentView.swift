import SwiftUI
import AppKit

struct ContentView: View {

    @ObservedObject var viewModel: TranslatorViewModel

    var body: some View {

        VStack(spacing: 0) {

            header

            Divider()
                .opacity(0.6)

            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: 0
                ) {

                    originalSection

                    sectionSpacing

                    translationSection

                    if viewModel.isGeneratingSuggestions ||
                        !viewModel.suggestions.isEmpty {

                        suggestionSection
                    }

                    majorDivider

                    replySection

                    if viewModel.isReplyTranslating ||
                        viewModel.hasTranslatedReply {

                        outgoingSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 20)
            }

            Divider()
                .opacity(0.6)

            bottomBar
        }
        .frame(
            width: 500,
            height: 720
        )
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
            .stroke(
                Color.primary.opacity(0.08),
                lineWidth: 1
            )
        }
        .alert(
            "PIAAR Translator",
            isPresented: Binding(
                get: {
                    viewModel.errorMessage != nil
                },
                set: { value in
                    if !value {
                        viewModel.errorMessage = nil
                    }
                }
            )
        ) {
            Button("확인") {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(
                viewModel.errorMessage ?? ""
            )
        }
    }


    // MARK: - Header

    // MARK: - Header

    private var header: some View {

        HStack(spacing: 9) {

            // 왼쪽 영역만 창 드래그 가능
            ZStack {

                WindowDragArea()

                HStack(spacing: 9) {

                    Image(
                        systemName:
                            "character.bubble.fill"
                    )
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)

                    Text("PIAAR Translator")
                        .font(
                            .system(
                                size: 14,
                                weight: .semibold
                            )
                        )
                        .allowsHitTesting(false)

                    Spacer()
                }
            }


            // 대화 문맥 표시
            if !viewModel
                .conversationHistory
                .isEmpty {

                HStack(spacing: 4) {

                    Circle()
                        .frame(
                            width: 5,
                            height: 5
                        )

                    Text(
                        "문맥 \(viewModel.conversationHistory.count)"
                    )
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }


            // 새 대화
            Button {

                viewModel
                    .clearConversation()

            } label: {

                Image(
                    systemName:
                        "arrow.counterclockwise"
                )
                .font(
                    .system(size: 12)
                )
                .frame(
                    width: 22,
                    height: 22
                )
                .contentShape(
                    Rectangle()
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("새 대화")


            // 설정
            Button {

                HotKeySettingsWindowController
                    .shared
                    .show()

            } label: {

                Image(
                    systemName:
                        "gearshape"
                )
                .font(
                    .system(size: 12)
                )
                .frame(
                    width: 22,
                    height: 22
                )
                .contentShape(
                    Rectangle()
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("설정")


            // 닫기
            Button {

                NSApp.keyWindow?
                    .orderOut(nil)

            } label: {

                Image(
                    systemName:
                        "xmark"
                )
                .font(
                    .system(
                        size: 11,
                        weight: .semibold
                    )
                )
                .frame(
                    width: 22,
                    height: 22
                )
                .contentShape(
                    Rectangle()
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("닫기")
        }
        .padding(
            .horizontal,
            18
        )
        .frame(
            height: 46
        )
    }

    // MARK: - Original

    private var originalSection: some View {

        VStack(
            alignment: .leading,
            spacing: 8
        ) {

            HStack {

                HStack(spacing: 6) {

                    Image(
                        systemName: "message"
                    )

                    Text("받은 메시지")
                }
                .font(
                    .system(
                        size: 11,
                        weight: .semibold
                    )
                )
                .foregroundStyle(.secondary)

                Spacer()

                Text("Enter 번역 · ⇧Enter 줄바꿈")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Button {

                    Task {
                        await viewModel
                            .translateOriginal()
                    }

                } label: {

                    Image(
                        systemName:
                            "arrow.clockwise"
                    )
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("다시 번역")

                Button {
                    viewModel.copyOriginal()
                } label: {
                    Image(
                        systemName:
                            viewModel.copiedOriginal
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("원문 복사")
            }

            EditableOriginalMessage(
                text:
                    $viewModel.originalText,

                onTextChange: {
                    viewModel
                        .originalWasEdited()
                },

                onTranslate: {

                    Task {
                        await viewModel
                            .translateOriginal()
                    }
                }
            )
            .frame(
                minHeight: 72,
                idealHeight: 86,
                maxHeight: 115
            )
            .background(
                Color.primary.opacity(0.035)
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 8
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 8
                )
                .stroke(
                    Color.primary.opacity(0.06),
                    lineWidth: 1
                )
            }
        }
    }


    // MARK: - Translation

    private var translationSection: some View {

        VStack(
            alignment: .leading,
            spacing: 8
        ) {

            sectionHeader(
                title: "번역 결과",
                icon: "character.book.closed",
                trailing: {

                    if !viewModel
                        .translatedText
                        .isEmpty {

                        return AnyView(
                            Button {
                                viewModel
                                    .copyTranslation()
                            } label: {
                                Image(
                                    systemName:
                                        viewModel.copiedTranslation
                                        ? "checkmark"
                                        : "doc.on.doc"
                                )
                                .font(
                                    .system(
                                        size: 11
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(
                                .secondary
                            )
                            .help("번역 결과 복사")
                        )
                    }

                    return AnyView(
                        EmptyView()
                    )
                }
            )

            ZStack(
                alignment: .leading
            ) {

                Color.clear
                    .frame(minHeight: 44)

                if viewModel.isTranslating {

                    HStack(spacing: 8) {

                        ProgressView()
                            .controlSize(.small)

                        Text(
                            "번역하고 있습니다..."
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    }

                } else {

                    Text(
                        viewModel.translatedText.isEmpty
                        ? "번역 결과가 여기에 표시됩니다."
                        : viewModel.translatedText
                    )
                    .font(
                        .system(
                            size: 14,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(
                        viewModel.translatedText.isEmpty
                        ? .secondary
                        : .primary
                    )
                    .lineSpacing(3)
                    .textSelection(.enabled)
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
        }
    }


    // MARK: - Suggestions

    private var suggestionSection: some View {

        VStack(
            alignment: .leading,
            spacing: 8
        ) {

            HStack(spacing: 5) {

                Image(
                    systemName: "sparkles"
                )

                Text("추천 답변")

                if viewModel
                    .isGeneratingSuggestions {

                    Text("· 생성 중...")
                        .foregroundStyle(
                            .tertiary
                        )

                    ProgressView()
                        .controlSize(.mini)

                } else {

                    Text(
                        "· 선택하면 입력창에 삽입"
                    )
                    .foregroundStyle(
                        .tertiary
                    )
                }
            }
            .font(
                .system(
                    size: 11,
                    weight: .medium
                )
            )
            .foregroundStyle(.secondary)

            if !viewModel
                .suggestions
                .isEmpty {

                VStack(spacing: 2) {

                    ForEach(
                        Array(
                            viewModel
                                .suggestions
                                .enumerated()
                        ),
                        id: \.offset
                    ) { _, suggestion in

                        Button {

                            viewModel
                                .selectSuggestion(
                                    suggestion
                                )

                        } label: {

                            HStack(
                                alignment:
                                    .firstTextBaseline,
                                spacing: 8
                            ) {

                                Image(
                                    systemName:
                                        "arrow.turn.down.right"
                                )
                                .font(
                                    .system(size: 9)
                                )
                                .foregroundStyle(
                                    .tertiary
                                )

                                Text(suggestion)
                                    .font(
                                        .system(
                                            size: 12
                                        )
                                    )
                                    .foregroundStyle(
                                        .secondary
                                    )
                                    .multilineTextAlignment(
                                        .leading
                                    )
                                    .lineLimit(2)

                                Spacer(
                                    minLength: 8
                                )
                            }
                            .padding(
                                .horizontal,
                                8
                            )
                            .padding(
                                .vertical,
                                6
                            )
                            .frame(
                                maxWidth:
                                    .infinity,
                                alignment: .leading
                            )
                            .contentShape(
                                Rectangle()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 14)
    }


    // MARK: - Reply

    private var replySection: some View {

        VStack(
            alignment: .leading,
            spacing: 9
        ) {

            HStack {

                HStack(spacing: 6) {

                    Image(
                        systemName:
                            "square.and.pencil"
                    )

                    Text("내 답변")
                }
                .font(
                    .system(
                        size: 13,
                        weight: .semibold
                    )
                )

                Spacer()

                Text(
                    "Enter 번역 · ⇧Enter 줄바꿈"
                )
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            ReplyTextEditor(
                text:
                    $viewModel.replyText,

                onTextChange: {
                    viewModel
                        .replyWasEdited()
                },

                onEnter: {

                    if viewModel
                        .hasTranslatedReply {

                        viewModel
                            .copyTranslatedReplyAndClose()

                        return
                    }

                    if viewModel
                        .canTranslateReply {

                        Task {
                            await viewModel
                                .translateReply()
                        }
                    }
                }
            )
            .frame(
                minHeight: 115,
                idealHeight: 125,
                maxHeight: 150
            )
            .background(
                Color.primary.opacity(0.045)
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 10
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 10
                )
                .stroke(
                    Color.accentColor
                        .opacity(0.30),
                    lineWidth: 1
                )
            }

            HStack {

                if viewModel
                    .replyText
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .isEmpty {

                    Text(
                        "한국어로 답변을 작성하거나 추천 답변을 선택하세요."
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)

                } else {

                    Text(
                        "Enter를 누르면 상대방 언어로 번역합니다."
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel
                    .canTranslateReply &&
                    !viewModel
                        .hasTranslatedReply {

                    Button {

                        Task {
                            await viewModel
                                .translateReply()
                        }

                    } label: {

                        HStack(spacing: 5) {

                            Text("번역")

                            Image(
                                systemName:
                                    "arrow.down"
                            )
                        }
                        .font(
                            .system(
                                size: 11,
                                weight: .semibold
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        Color.accentColor
                    )
                }
            }
        }
    }


    // MARK: - Outgoing

    private var outgoingSection: some View {

        VStack(
            alignment: .leading,
            spacing: 9
        ) {

            HStack {

                HStack(spacing: 6) {

                    Image(
                        systemName:
                            "paperplane"
                    )

                    Text("보낼 메시지")
                }
                .font(
                    .system(
                        size: 12,
                        weight: .semibold
                    )
                )
                .foregroundStyle(.secondary)

                Spacer()

                if viewModel
                    .hasTranslatedReply {

                    Button {

                        Task {
                            await viewModel
                                .retranslateReply()
                        }

                    } label: {

                        Image(
                            systemName:
                                "arrow.clockwise"
                        )
                        .font(
                            .system(size: 11)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("다시 번역")
                }
            }

            ZStack {

                Color.clear
                    .frame(minHeight: 82)

                if viewModel
                    .isReplyTranslating {

                    HStack(spacing: 8) {

                        ProgressView()
                            .controlSize(.small)

                        Text(
                            "답변을 번역하고 있습니다..."
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(
                            .secondary
                        )
                    }

                } else {

                    EditableTranslatedReply(
                        text:
                            $viewModel
                                .translatedReplyText,

                        onTextChange: {
                            viewModel
                                .translatedReplyWasEdited()
                        },

                        onEnter: {
                            viewModel
                                .copyTranslatedReplyAndClose()
                        }
                    )
                    .frame(
                        minHeight: 82,
                        maxHeight: 115
                    )
                }
            }
            .background(
                Color.primary.opacity(0.025)
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 8
                )
            )

            validationStatus
        }
        .padding(.top, 20)
    }


    // MARK: - Validation

    @ViewBuilder
    private var validationStatus:
        some View {

        if viewModel.hasTranslatedReply {

            HStack(spacing: 6) {

                if viewModel.numberMismatch {

                    Image(
                        systemName:
                            "exclamationmark.triangle.fill"
                    )

                    Text("숫자 불일치")

                    Text(
                        "\(viewModel.sourceNumbers.joined(separator: " · ")) → \(viewModel.translatedNumbers.joined(separator: " · "))"
                    )
                    .lineLimit(1)

                } else if !viewModel
                    .sourceNumbers
                    .isEmpty {

                    Image(
                        systemName:
                            "checkmark.circle.fill"
                    )

                    Text("숫자 · 수량 일치")

                } else {

                    Image(
                        systemName:
                            "checkmark.circle"
                    )

                    Text("확인할 숫자 없음")
                }
            }
            .font(
                .system(
                    size: 10.5,
                    weight:
                        viewModel.numberMismatch
                        ? .semibold
                        : .regular
                )
            )
            .foregroundStyle(
                viewModel.numberMismatch
                ? Color.orange
                : Color.secondary
            )
        }
    }


    // MARK: - Bottom

    private var bottomBar: some View {

        HStack(spacing: 12) {

            if viewModel.hasTranslatedReply {

                if viewModel.numberMismatch {

                    Label(
                        "숫자를 확인해주세요",
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)

                } else {

                    Label(
                        "번역 완료",
                        systemImage:
                            "checkmark.circle"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }

            } else {

                Text("ESC 닫기")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if viewModel.hasTranslatedReply {

                Button {

                    viewModel
                        .copyTranslatedReplyAndClose()

                } label: {

                    HStack(spacing: 7) {

                        Image(
                            systemName:
                                "doc.on.doc.fill"
                        )

                        Text(
                            "복사하고 닫기"
                        )

                        Text("↵")
                            .opacity(0.7)
                    }
                    .font(
                        .system(
                            size: 12,
                            weight: .semibold
                        )
                    )
                    .padding(
                        .horizontal,
                        5
                    )
                }
                .buttonStyle(
                    .borderedProminent
                )
                .controlSize(.large)

            } else {

                Button("닫기") {
                    NSApp.keyWindow?
                        .orderOut(nil)
                }
                .keyboardShortcut(
                    .cancelAction
                )
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }


    // MARK: - Helpers

    private var sectionSpacing:
        some View {

        Color.clear
            .frame(height: 18)
    }


    private var majorDivider:
        some View {

        Divider()
            .opacity(0.55)
            .padding(.vertical, 18)
    }


    private func sectionHeader(
        title: String,
        icon: String,
        trailing: () -> AnyView
    ) -> some View {

        HStack {

            HStack(spacing: 6) {

                Image(
                    systemName: icon
                )

                Text(title)
            }
            .font(
                .system(
                    size: 11,
                    weight: .semibold
                )
            )
            .foregroundStyle(.secondary)

            Spacer()

            trailing()
        }
    }
}


// MARK: - Editable Original Message

struct EditableOriginalMessage:
    NSViewRepresentable {

    @Binding var text: String

    let onTextChange: () -> Void
    let onTranslate: () -> Void


    func makeCoordinator()
        -> Coordinator {

        Coordinator(
            text: $text,
            onTextChange:
                onTextChange
        )
    }


    func makeNSView(
        context: Context
    ) -> NSScrollView {

        let scroll =
            NSScrollView()

        scroll.hasVerticalScroller =
            true

        scroll.hasHorizontalScroller =
            false

        scroll.autohidesScrollers =
            true

        scroll.borderType =
            .noBorder

        scroll.drawsBackground =
            false


        let textView =
            OriginalNSTextView()

        textView.delegate =
            context.coordinator

        textView.onTranslate =
            onTranslate

        textView.isRichText =
            false

        textView.isEditable =
            true

        textView.isSelectable =
            true

        textView.allowsUndo =
            true

        textView.drawsBackground =
            false

        textView.font =
            NSFont.systemFont(
                ofSize: 13.5
            )

        textView.textContainerInset =
            NSSize(
                width: 11,
                height: 10
            )


        // MARK: - 자동 줄바꿈

        textView.isHorizontallyResizable =
            false

        textView.isVerticallyResizable =
            true

        textView.autoresizingMask = [
            .width
        ]

        if let textContainer =
            textView.textContainer {

            textContainer.widthTracksTextView =
                true

            textContainer.heightTracksTextView =
                false

            // 중국어, 영어, 긴 문자열도 강제 줄바꿈
            textContainer.lineBreakMode =
                .byCharWrapping

            textContainer.containerSize =
                NSSize(
                    width: 0,
                    height: CGFloat.greatestFiniteMagnitude
                )
        }


        textView.string =
            text

        scroll.documentView =
            textView

        return scroll
    }

    func updateNSView(
        _ nsView: NSScrollView,
        context: Context
    ) {

        guard let textView =
                nsView.documentView
                    as? OriginalNSTextView
        else {
            return
        }

        if textView.string != text {
            textView.string = text
        }

        textView.onTranslate =
            onTranslate
    }


    final class Coordinator:
        NSObject,
        NSTextViewDelegate {

        @Binding var text: String

        let onTextChange: () -> Void

        init(
            text: Binding<String>,
            onTextChange:
                @escaping () -> Void
        ) {

            _text = text

            self.onTextChange =
                onTextChange
        }

        func textDidChange(
            _ notification:
                Notification
        ) {

            guard let textView =
                    notification.object
                        as? NSTextView
            else {
                return
            }

            text =
                textView.string

            onTextChange()
        }
    }
}


// MARK: - Original NSTextView

final class OriginalNSTextView:
    NSTextView {

    var onTranslate: (() -> Void)?

    override func keyDown(
        with event: NSEvent
    ) {

        if event.keyCode == 36 ||
            event.keyCode == 76 {

            // Shift + Enter → 줄바꿈
            if event.modifierFlags
                .contains(.shift) {

                insertNewline(nil)
                return
            }

            // Enter → 번역
            onTranslate?()
            return
        }

        super.keyDown(
            with: event
        )
    }
}


// MARK: - Reply Editor

struct ReplyTextEditor:
    NSViewRepresentable {

    @Binding var text: String

    let onTextChange: () -> Void
    let onEnter: () -> Void


    func makeCoordinator()
        -> Coordinator {

        Coordinator(
            text: $text,
            onTextChange:
                onTextChange
        )
    }


    func makeNSView(
        context: Context
    ) -> NSScrollView {

        let scroll =
            NSScrollView()

        // 세로 스크롤만 사용
        scroll.hasVerticalScroller =
            true

        scroll.hasHorizontalScroller =
            false

        scroll.autohidesScrollers =
            true

        scroll.borderType =
            .noBorder

        scroll.drawsBackground =
            false


        let textView =
            ReplyNSTextView()

        textView.delegate =
            context.coordinator

        textView.onEnter =
            onEnter

        textView.isRichText =
            false

        textView.isEditable =
            true

        textView.isSelectable =
            true

        textView.allowsUndo =
            true

        textView.drawsBackground =
            false

        textView.font =
            NSFont.systemFont(
                ofSize: 14
            )

        textView.textContainerInset =
            NSSize(
                width: 11,
                height: 11
            )


        // MARK: - 자동 줄바꿈

        // 가로 방향으로 TextView가 늘어나지 않게 함
        textView.isHorizontallyResizable =
            false

        // 내용이 길어지면 세로 방향으로 처리
        textView.isVerticallyResizable =
            true

        // ScrollView 너비를 따라가도록 설정
        textView.autoresizingMask = [
            .width
        ]

        if let textContainer =
            textView.textContainer {

            // TextView 너비에 맞춰 자동 줄바꿈
            textContainer.widthTracksTextView =
                true

            textContainer.heightTracksTextView =
                false

            // 중국어 / 영어 / 긴 문자열까지
            // 영역 밖으로 나가지 않도록 문자 단위 줄바꿈
            textContainer.lineBreakMode =
                .byCharWrapping

            // 사실상 무제한 세로 높이
            textContainer.containerSize =
                NSSize(
                    width: 0,
                    height: CGFloat.greatestFiniteMagnitude
                )
        }


        textView.string =
            text

        scroll.documentView =
            textView

        return scroll
    }


    func updateNSView(
        _ nsView: NSScrollView,
        context: Context
    ) {

        guard let textView =
                nsView.documentView
                    as? ReplyNSTextView
        else {
            return
        }

        if textView.string != text {
            textView.string = text
        }

        textView.onEnter =
            onEnter
    }


    final class Coordinator:
        NSObject,
        NSTextViewDelegate {

        @Binding var text: String

        let onTextChange: () -> Void

        init(
            text: Binding<String>,
            onTextChange:
                @escaping () -> Void
        ) {

            _text = text

            self.onTextChange =
                onTextChange
        }

        func textDidChange(
            _ notification:
                Notification
        ) {

            guard let textView =
                    notification.object
                        as? NSTextView
            else {
                return
            }

            text =
                textView.string

            onTextChange()
        }
    }
}


// MARK: - Reply NSTextView

final class ReplyNSTextView:
    NSTextView {

    var onEnter: (() -> Void)?

    override func keyDown(
        with event: NSEvent
    ) {

        if event.keyCode == 36 ||
            event.keyCode == 76 {

            if event.modifierFlags
                .contains(.shift) {

                insertNewline(nil)
                return
            }

            onEnter?()
            return
        }

        super.keyDown(
            with: event
        )
    }
}


// MARK: - Editable Outgoing Message

struct EditableTranslatedReply:
    NSViewRepresentable {

    @Binding var text: String

    let onTextChange: () -> Void
    let onEnter: () -> Void


    func makeCoordinator()
        -> Coordinator {

        Coordinator(
            text: $text,
            onTextChange:
                onTextChange
        )
    }


    func makeNSView(
        context: Context
    ) -> NSScrollView {

        let scroll =
            NSScrollView()

        scroll.hasVerticalScroller =
            true

        scroll.hasHorizontalScroller =
            false

        scroll.autohidesScrollers =
            true

        scroll.borderType =
            .noBorder

        scroll.drawsBackground =
            false


        let textView =
            TranslatedNSTextView()

        textView.delegate =
            context.coordinator

        textView.onEnter =
            onEnter

        textView.isRichText =
            false

        textView.isEditable =
            true

        textView.isSelectable =
            true

        textView.allowsUndo =
            true

        textView.drawsBackground =
            false

        textView.font =
            NSFont.systemFont(
                ofSize: 14
            )

        textView.textContainerInset =
            NSSize(
                width: 11,
                height: 10
            )


        // MARK: - 자동 줄바꿈

        textView.isHorizontallyResizable =
            false

        textView.isVerticallyResizable =
            true

        textView.autoresizingMask = [
            .width
        ]

        if let textContainer =
            textView.textContainer {

            textContainer.widthTracksTextView =
                true

            textContainer.heightTracksTextView =
                false

            // 중국어, 영어, 긴 문자열도 강제 줄바꿈
            textContainer.lineBreakMode =
                .byCharWrapping

            textContainer.containerSize =
                NSSize(
                    width: 0,
                    height: CGFloat.greatestFiniteMagnitude
                )
        }


        textView.string =
            text

        scroll.documentView =
            textView

        return scroll
    }


    func updateNSView(
        _ nsView: NSScrollView,
        context: Context
    ) {

        guard let textView =
                nsView.documentView
                    as? TranslatedNSTextView
        else {
            return
        }

        if textView.string != text {
            textView.string = text
        }

        textView.onEnter =
            onEnter
    }


    final class Coordinator:
        NSObject,
        NSTextViewDelegate {

        @Binding var text: String

        let onTextChange: () -> Void

        init(
            text: Binding<String>,
            onTextChange:
                @escaping () -> Void
        ) {

            _text = text

            self.onTextChange =
                onTextChange
        }

        func textDidChange(
            _ notification:
                Notification
        ) {

            guard let textView =
                    notification.object
                        as? NSTextView
            else {
                return
            }

            text =
                textView.string

            onTextChange()
        }
    }
}


// MARK: - Outgoing NSTextView

final class TranslatedNSTextView:
    NSTextView {

    var onEnter: (() -> Void)?

    override func keyDown(
        with event: NSEvent
    ) {

        if event.keyCode == 36 ||
            event.keyCode == 76 {

            if event.modifierFlags
                .contains(.shift) {

                insertNewline(nil)
                return
            }

            onEnter?()
            return
        }

        super.keyDown(
            with: event
        )
    }
}


#Preview {
    ContentView(
        viewModel:
            TranslatorViewModel()
    )
}

// MARK: - Window Drag Area

struct WindowDragArea:
    NSViewRepresentable {

    func makeNSView(
        context: Context
    ) -> NSView {

        let view =
            WindowDragNSView()

        view.wantsLayer = true

        return view
    }

    func updateNSView(
        _ nsView: NSView,
        context: Context
    ) {
    }
}


final class WindowDragNSView:
    NSView {

    override var mouseDownCanMoveWindow:
        Bool {
        false
    }

    override func mouseDown(
        with event: NSEvent
    ) {

        guard let window else {
            return
        }

        window.performDrag(
            with: event
        )
    }
}
