import SwiftUI
import AppKit

@MainActor
final class TranslatorViewModel: ObservableObject {

    private let service: TranslationService
    private var incomingTask: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?
    private var incomingRequestID = UUID()
    private var replyRequestID = UUID()

    init(service: TranslationService = OpenAIService.shared) {
        self.service = service
    }

    private func cancelIncomingRequest() {
        incomingRequestID = UUID()
        incomingTask?.cancel()
        incomingTask = nil
        isTranslating = false
        isGeneratingSuggestions = false
    }

    private func cancelReplyRequest() {
        replyRequestID = UUID()
        replyTask?.cancel()
        replyTask = nil
        isReplyTranslating = false
    }

    func cancelTranslationRequests() {
        cancelIncomingRequest()
        cancelReplyRequest()
        shouldFocusReply = false
    }

    // MARK: - Current Message

    @Published var originalText = ""
    @Published var translatedText = ""

    @Published var replyText = ""
    @Published var translatedReplyText = ""

    @Published var suggestions: [String] = []


    // MARK: - Loading

    @Published var isTranslating = false
    @Published var isGeneratingSuggestions = false
    @Published var isReplyTranslating = false


    // MARK: - UI

    @Published var errorMessage: String?
    @Published var shouldFocusReply = false

    @Published var copiedOriginal = false
    @Published var copiedTranslation = false


    // MARK: - Conversation

    @Published
    private(set)
    var conversationHistory:
        [ConversationMessage] = []


    // MARK: - Number Validation

    @Published
    var sourceNumbers: [String] = []

    @Published
    var translatedNumbers: [String] = []

    @Published
    var numberMismatch = false


    // MARK: - Computed

    var hasOriginalText: Bool {

        !originalText
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .isEmpty
    }

    var canTranslateReply: Bool {

        !replyText
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .isEmpty
        &&
        !isReplyTranslating
    }

    var hasTranslatedReply: Bool {

        !translatedReplyText
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .isEmpty
    }


    // MARK: - Prepare

    func prepareTranslation(text: String?) async {
        guard !Task.isCancelled else { return }
        cancelTranslationRequests()

        errorMessage = nil

        translatedText = ""
        replyText = ""
        translatedReplyText = ""

        suggestions = []

        sourceNumbers = []
        translatedNumbers = []
        numberMismatch = false

        shouldFocusReply = false

        originalText = Self.cleanedClipboardText(text)

        guard hasOriginalText else {

            errorMessage =
                "선택한 텍스트를 찾을 수 없습니다."

            return
        }

        await translateOriginal()
    }


    // MARK: - Clipboard

    static func cleanedClipboardText(_ text: String?) -> String {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func copiedSelection(from pasteboard: NSPasteboard, after changeCount: Int) -> String? {
        guard pasteboard.changeCount != changeCount else { return nil }
        let text = cleanedClipboardText(pasteboard.string(forType: .string))
        return text.isEmpty ? nil : text
    }

    func loadClipboard(from pasteboard: NSPasteboard = .general) {
        originalText = Self.cleanedClipboardText(pasteboard.string(forType: .string))
    }


    func copyToClipboard(
        _ text: String
    ) {

        NSPasteboard.general
            .clearContents()

        NSPasteboard.general
            .setString(
                text,
                forType: .string
            )
    }


    func copyOriginal() {

        copyToClipboard(originalText)

        copiedOriginal = true

        Task {

            try? await Task.sleep(
                for: .seconds(1)
            )

            copiedOriginal = false
        }
    }


    func copyTranslation() {

        copyToClipboard(
            translatedText
        )

        copiedTranslation = true

        Task {

            try? await Task.sleep(
                for: .seconds(1)
            )

            copiedTranslation = false
        }
    }


    // MARK: - Original Edited

    func originalWasEdited() {
        cancelTranslationRequests()

        translatedText = ""
        suggestions = []

        isGeneratingSuggestions = false
    }


    // MARK: - Incoming Translation

    func translateOriginal() async {
        guard !Task.isCancelled else { return }
        cancelTranslationRequests()
        let requestID = incomingRequestID
        let text = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "번역할 메시지가 없습니다."
            return
        }

        originalText = text
        isTranslating = true
        errorMessage = nil
        translatedText = ""
        suggestions = []
        let history = conversationHistory

        let task = Task { @MainActor in
            defer {
                if incomingRequestID == requestID {
                    isTranslating = false
                    isGeneratingSuggestions = false
                    incomingTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                let translation = try await service.translateReceivedMessage(text, history: history)
                guard incomingRequestID == requestID, !Task.isCancelled else { return }
                translatedText = translation
                isTranslating = false
                isGeneratingSuggestions = true
                do {
                    let result = try await service.generateReplySuggestions(
                        originalMessage: text, translatedMessage: translation, history: history)
                    guard incomingRequestID == requestID, !Task.isCancelled else { return }
                    suggestions = result
                } catch {
                    guard incomingRequestID == requestID, !Task.isCancelled else { return }
                    // 추천답변 실패는 번역 자체의 실패로 취급하지 않습니다.
                    suggestions = []
                }
                shouldFocusReply = true
            } catch {
                guard incomingRequestID == requestID, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
        incomingTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }


    // MARK: - Suggestion

    func selectSuggestion(
        _ suggestion: String
    ) {
        cancelReplyRequest()

        replyText = suggestion

        translatedReplyText = ""

        resetNumberValidation()
    }


    // MARK: - Translate Reply

    func translateReply() async {
        await performReplyTranslation(alternative: false)
    }

    // MARK: - Retranslate

    func retranslateReply() async {
        await performReplyTranslation(alternative: true)
    }

    private func performReplyTranslation(alternative: Bool) async {
        guard !Task.isCancelled else { return }
        cancelReplyRequest()
        let requestID = replyRequestID
        let reply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        let previous = alternative ? translatedReplyText : nil
        let original = originalText
        let translation = translatedText
        let history = conversationHistory
        isReplyTranslating = true
        errorMessage = nil
        if !alternative {
            translatedReplyText = ""
            resetNumberValidation()
        }

        let task = Task { @MainActor in
            defer {
                if replyRequestID == requestID {
                    isReplyTranslating = false
                    replyTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                let result = try await service.translateReply(
                    reply: reply, originalMessage: original, translatedMessage: translation,
                    history: history, alternativeTo: previous)
                guard replyRequestID == requestID, !Task.isCancelled else { return }
                translatedReplyText = result
                validateNumbers()
            } catch {
                guard replyRequestID == requestID, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
        replyTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }


    // MARK: - Reply Edited

    func replyWasEdited() {
        cancelReplyRequest()

        if hasTranslatedReply {
            translatedReplyText = ""
        }

        resetNumberValidation()
    }


    // MARK: - Translated Reply Edited

    func translatedReplyWasEdited() {
        cancelReplyRequest()

        validateNumbers()
    }


    // MARK: - Number Validation

    func validateNumbers() {

        sourceNumbers =
            extractNumbers(
                from: replyText
            )

        translatedNumbers =
            extractNumbers(
                from: translatedReplyText
            )

        numberMismatch =
            sourceNumbers !=
            translatedNumbers
    }


    private func extractNumbers(
        from text: String
    ) -> [String] {

        let pattern =
            #"(?<![A-Za-z])\d+(?:[.,]\d+)*(?:\s*[×xX*]\s*\d+(?:[.,]\d+)*)?"#

        guard let regex =
                try? NSRegularExpression(
                    pattern: pattern
                )
        else {
            return []
        }

        let range =
            NSRange(
                text.startIndex...,
                in: text
            )

        return regex
            .matches(
                in: text,
                range: range
            )
            .compactMap {

                guard let swiftRange =
                        Range(
                            $0.range,
                            in: text
                        )
                else {
                    return nil
                }

                return String(
                    text[swiftRange]
                )
                .replacingOccurrences(
                    of: " ",
                    with: ""
                )
                .replacingOccurrences(
                    of: "X",
                    with: "×"
                )
                .replacingOccurrences(
                    of: "x",
                    with: "×"
                )
                .replacingOccurrences(
                    of: "*",
                    with: "×"
                )
            }
    }


    private func resetNumberValidation() {

        sourceNumbers = []
        translatedNumbers = []
        numberMismatch = false
    }


    // MARK: - Copy + Close

    func copyTranslatedReplyAndClose() {

        guard hasTranslatedReply else {
            return
        }

        validateNumbers()

        saveCurrentConversation()

        copyToClipboard(
            translatedReplyText
        )

        NSApp.keyWindow?
            .orderOut(nil)
    }


    // MARK: - History

    private func saveCurrentConversation() {

        guard
            !originalText.isEmpty,
            !translatedText.isEmpty
        else {
            return
        }

        let item =
            ConversationMessage(
                original:
                    originalText,
                korean:
                    translatedText,
                replyKorean:
                    replyText.isEmpty
                    ? nil
                    : replyText,
                replyForeign:
                    translatedReplyText.isEmpty
                    ? nil
                    : translatedReplyText
            )

        conversationHistory
            .append(item)

        if conversationHistory.count > 5 {

            conversationHistory =
                Array(
                    conversationHistory
                        .suffix(5)
                )
        }
    }


    // MARK: - New Conversation

    func clearConversation() {
        cancelTranslationRequests()
        errorMessage = nil

        conversationHistory = []

        originalText = ""
        translatedText = ""

        replyText = ""
        translatedReplyText = ""

        suggestions = []

        isTranslating = false
        isGeneratingSuggestions = false
        isReplyTranslating = false

        resetNumberValidation()
    }
}
