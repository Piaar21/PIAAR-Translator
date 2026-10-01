import Foundation

// MARK: - Models

struct ConversationMessage {

    let original: String
    let korean: String
    let replyKorean: String?
    let replyForeign: String?
}


// MARK: - Errors

enum TranslatorError:
    LocalizedError {

    case apiKeyNotFound
    case invalidResponse
    case emptyResponse
    case apiError(String)


    var errorDescription: String? {

        switch self {

        case .apiKeyNotFound:

            return """
            OpenAI API Key를 찾을 수 없습니다.
            설정에서 API Key를 등록해주세요.
            """


        case .invalidResponse:

            return """
            OpenAI 서버 응답을 확인할 수 없습니다.
            """


        case .emptyResponse:

            return """
            번역 결과가 비어 있습니다.
            """


        case .apiError(
            let message
        ):

            return message
        }
    }
}


// MARK: - OpenAI Service

protocol TranslationService {
    func translateReceivedMessage(_ text: String, history: [ConversationMessage]) async throws -> String
    func generateReplySuggestions(originalMessage: String, translatedMessage: String,
                                  history: [ConversationMessage]) async throws -> [String]
    func translateReply(reply: String, originalMessage: String, translatedMessage: String,
                        history: [ConversationMessage], alternativeTo: String?) async throws -> String
}

final class OpenAIService: TranslationService {

    static let shared =
        OpenAIService()


    private init() {}


    // MARK: - API Key

    private func loadAPIKey()
        throws -> String {

        try KeychainManager
            .loadAPIKey()
    }


    // MARK: - Incoming Translation

    func translateReceivedMessage(
        _ text: String,
        history: [ConversationMessage]
    ) async throws -> String {

        let historyText =
            makeHistoryText(
                history
            )


        let instructions = """
        You are the multilingual incoming-message translation engine
        for PIAAR Translator.

        Automatically detect the incoming language and translate the
        complete message into natural Korean.

        Rules:
        - Support any language.
        - Preserve the exact meaning and tone.
        - Preserve ALL numbers, quantities, prices, currencies, dates, times,
          dimensions, model names, order numbers, tracking numbers and URLs exactly.
        - Never invent, summarize or omit information.
        - If there are multiple chat messages, translate all of them in order.
        - Use conversation history only when needed to understand context.
        - If the message is already Korean, preserve its meaning.
        - Use natural Korean suitable for real-world business communication.

        Preferred PIAAR terminology:
        \(PIAARTerminology.promptText)

        RECENT CONVERSATION HISTORY:
        \(historyText)

        Output ONLY the Korean translation.
        No explanation, label, quotation marks or markdown.
        """


        return try await request(
            instructions:
                instructions,

            input:
                text
        )
    }


    // MARK: - Suggestions

    func generateReplySuggestions(
        originalMessage: String,
        translatedMessage: String,
        history: [ConversationMessage]
    ) async throws -> [String] {

        let historyText =
            makeHistoryText(
                history
            )


        let instructions = """
        You are the reply-assistance engine for PIAAR Translator.

        Based on the incoming message and its Korean translation,
        generate exactly 3 short and useful Korean reply suggestions.

        Rules:
        - Suggestions MUST be written in Korean.
        - Generate exactly 3 suggestions.
        - Keep them practical, natural and concise.
        - Make them meaningfully different when possible.
        - Do not invent promises, quantities, prices, dates or facts.
        - Do not assume the user agrees with the other person.
        - Make them suitable for real-world business chat.
        - Use conversation history only when needed for context.

        RECENT CONVERSATION HISTORY:
        \(historyText)

        Return ONLY valid JSON:

        {
          "suggestions": [
            "suggestion 1",
            "suggestion 2",
            "suggestion 3"
          ]
        }

        No markdown or code fences.
        """


        let input = """
        ORIGINAL MESSAGE:
        \(originalMessage)

        KOREAN TRANSLATION:
        \(translatedMessage)
        """


        let output =
            try await request(
                instructions:
                    instructions,

                input:
                    input
            )


        return try parseSuggestions(
            output
        )
    }


    // MARK: - Reply Translation

    func translateReply(
        reply: String,
        originalMessage: String,
        translatedMessage: String,
        history: [ConversationMessage],
        alternativeTo: String? = nil
    ) async throws -> String {

        let historyText =
            makeHistoryText(
                history
            )


        var alternativeInstruction =
            ""


        if let alternativeTo,
           !alternativeTo.isEmpty {

            alternativeInstruction = """

            Previous translation:
            \(alternativeTo)

            Use DIFFERENT natural wording while preserving exactly
            the same meaning, facts, numbers and tone.
            """
        }


        let instructions = """
        You are the multilingual reply translation engine for PIAAR Translator.

        The user writes their reply in Korean.

        Automatically detect the main language of ORIGINAL MESSAGE and
        translate USER'S REPLY into that same language.

        Rules:
        - Support any language.
        - Determine the output language ONLY from ORIGINAL MESSAGE,
          never from KOREAN TRANSLATION.
        - If multiple languages are present, use the dominant language
          used by the other person.
        - If ORIGINAL MESSAGE is Korean, default to Simplified Chinese.
        - Use natural, polite and concise real-world business chat language.
        - Match normal business-chat conventions of the target language.
        - Preserve the user's intended tone.
        - Preserve ALL numbers, quantities, prices, currencies, dates, times,
          dimensions, model names, order numbers, tracking numbers and URLs exactly.
        - Never invent, add or remove information.
        - Use conversation history only when needed to understand context.
        - For Chinese, use natural supplier/factory/1688 business-chat language.

        Preferred PIAAR terminology:
        \(PIAARTerminology.promptText)

        RECENT CONVERSATION HISTORY:
        \(historyText)

        \(alternativeInstruction)

        Output ONLY the translated reply.
        No explanation, label, quotation marks or markdown.
        """


        let input = """
        ORIGINAL MESSAGE:
        \(originalMessage)

        KOREAN TRANSLATION:
        \(translatedMessage)

        USER'S REPLY:
        \(reply)
        """


        return try await request(
            instructions:
                instructions,

            input:
                input
        )
    }


    // MARK: - History

    private func makeHistoryText(
        _ history: [ConversationMessage]
    ) -> String {

        guard !history.isEmpty
        else {

            return "(none)"
        }


        return history
            .suffix(5)
            .enumerated()
            .map {
                index,
                message in

                var block = """
                [\(index + 1)]
                OTHER PERSON:
                \(message.original)

                KOREAN:
                \(message.korean)
                """


                if let reply =
                    message.replyKorean {

                    block += """

                    USER REPLY:
                    \(reply)
                    """
                }


                if let foreign =
                    message.replyForeign {

                    block += """

                    SENT REPLY:
                    \(foreign)
                    """
                }


                return block
            }
            .joined(
                separator:
                    "\n\n"
            )
    }


    // MARK: - Parse Suggestions

    private func parseSuggestions(
        _ text: String
    ) throws -> [String] {

        var cleaned =
            text.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )


        if cleaned.hasPrefix(
            "```"
        ) {

            cleaned =
                cleaned
                    .replacingOccurrences(
                        of: "```json",
                        with: ""
                    )
                    .replacingOccurrences(
                        of: "```",
                        with: ""
                    )
                    .trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )
        }


        guard
            let data =
                cleaned.data(
                    using: .utf8
                ),

            let json =
                try? JSONSerialization
                    .jsonObject(
                        with: data
                    )
                    as? [String: Any],

            let suggestions =
                json["suggestions"]
                    as? [String]

        else {

            throw TranslatorError
                .invalidResponse
        }


        let result =
            Array(
                suggestions
                    .filter {

                        !$0
                            .trimmingCharacters(
                                in:
                                    .whitespacesAndNewlines
                            )
                            .isEmpty
                    }
                    .prefix(3)
            )


        guard !result.isEmpty
        else {

            throw TranslatorError
                .emptyResponse
        }


        return result
    }


    // MARK: - Request

    private func request(
        instructions: String,
        input: String
    ) async throws -> String {

        let apiKey =
            try loadAPIKey()


        guard let url =
                URL(
                    string:
                        "https://api.openai.com/v1/responses"
                )
        else {

            throw TranslatorError
                .invalidResponse
        }


        var request =
            URLRequest(
                url: url
            )


        request.httpMethod =
            "POST"


        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField:
                "Authorization"
        )


        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )


        let body:
            [String: Any] = [

                "model":
                    "gpt-5.6-luna",

                "reasoning": [
                    "effort":
                        "none"
                ],

                "instructions":
                    instructions,

                "input":
                    input
            ]


        request.httpBody =
            try JSONSerialization
                .data(
                    withJSONObject:
                        body
                )


        let (
            data,
            response
        ) =
            try await URLSession
                .shared
                .data(
                    for: request
                )


        guard
            let httpResponse =
                response
                    as? HTTPURLResponse

        else {

            throw TranslatorError
                .invalidResponse
        }


        guard
            (200...299)
                .contains(
                    httpResponse
                        .statusCode
                )

        else {

            if
                let json =
                    try? JSONSerialization
                        .jsonObject(
                            with: data
                        )
                        as? [String: Any],

                let error =
                    json["error"]
                        as? [String: Any],

                let message =
                    error["message"]
                        as? String {

                throw TranslatorError
                    .apiError(
                        message
                    )
            }


            throw TranslatorError
                .apiError(
                    "OpenAI API 오류: HTTP \(httpResponse.statusCode)"
                )
        }


        guard
            let json =
                try JSONSerialization
                    .jsonObject(
                        with: data
                    )
                    as? [String: Any]

        else {

            throw TranslatorError
                .invalidResponse
        }


        var outputText =
            ""


        if let output =
            json["output"]
                as? [[String: Any]] {

            for item in output {

                guard
                    item["type"]
                        as? String
                        == "message",

                    let content =
                        item["content"]
                            as? [[String: Any]]

                else {

                    continue
                }


                for part in content {

                    if
                        part["type"]
                            as? String
                            == "output_text",

                        let text =
                            part["text"]
                                as? String {

                        outputText +=
                            text
                    }
                }
            }
        }


        outputText =
            outputText
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )


        guard !outputText.isEmpty
        else {

            throw TranslatorError
                .emptyResponse
        }


        return outputText
    }
}
