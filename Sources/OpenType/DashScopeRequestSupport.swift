import Foundation

enum ASRRequestBuilder {
    static func body(
        model: String,
        dataURI: String,
        languageCode: String? = nil
    ) -> [String: Any] {
        var asrOptions: [String: Any] = ["enable_itn": true]
        if let languageCode {
            asrOptions["language"] = languageCode
        }

        return [
            "model": model,
            // DashScope's dedicated ASR task rejects text/system messages.
            // Personal vocabulary is applied during the following text
            // transformation instead of being mixed into this audio request.
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": dataURI
                            ]
                        ]
                    ]
                ]
            ],
            "stream": false,
            "asr_options": asrOptions
        ]
    }
}

enum ResponseParser {
    static func content(from data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any] else {
            throw OpenTypeError.invalidResponse
        }

        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw OpenTypeError.service(message)
        }

        guard
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"]
        else {
            throw OpenTypeError.invalidResponse
        }

        if let text = content as? String {
            return text
        }

        if let parts = content as? [[String: Any]] {
            let strings = parts.compactMap {
                ($0["text"] as? String) ?? ($0["content"] as? String)
            }
            if !strings.isEmpty {
                return strings.joined()
            }
        }

        throw OpenTypeError.invalidResponse
    }

    static func errorMessage(from data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let message = root["message"] as? String {
            return message
        }
        return nil
    }
}
