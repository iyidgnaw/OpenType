import Foundation

struct AIServiceClient {
    private let selection: AIServiceSelection
    private let vault: ProviderVault
    private let session: URLSession

    init(
        selection: AIServiceSelection,
        vault: ProviderVault,
        session: URLSession = .shared
    ) {
        self.selection = selection
        self.vault = vault
        self.session = session
    }

    var isFullyConfigured: Bool {
        vault.hasToken(for: selection.speechProvider)
            && vault.hasToken(for: selection.textProvider)
    }

    var safeStatusDescription: String {
        let speech = vault.hasToken(for: selection.speechProvider)
            ? selection.speechProvider.shortTitle
            : OpenTypeL10n.text("\(selection.speechProvider.shortTitle) 未配置", english: "\(selection.speechProvider.shortTitle) not configured")
        let text = vault.hasToken(for: selection.textProvider)
            ? selection.textProvider.shortTitle
            : OpenTypeL10n.text("\(selection.textProvider.shortTitle) 未配置", english: "\(selection.textProvider.shortTitle) not configured")
        return OpenTypeL10n.text("语音：\(speech) · 文字：\(text)", english: "Speech: \(speech) · Text: \(text)")
    }

    func transcribe(
        audioURL: URL,
        personalVocabulary: [String]
    ) async throws -> String {
        let token = try vault.token(for: selection.speechProvider)
        switch selection.speechProvider {
        case .dashScope:
            return try await transcribeWithDashScope(
                audioURL: audioURL,
                token: token
            )
        case .openAI:
            return try await transcribeWithOpenAI(
                audioURL: audioURL,
                token: token,
                personalVocabulary: personalVocabulary
            )
        case .elevenLabs:
            return try await transcribeWithElevenLabs(
                audioURL: audioURL,
                token: token
            )
        case .volcengine, .anthropic:
            throw OpenTypeError.service(
                "\(selection.speechProvider.title) 当前不支持语音识别"
            )
        }
    }

    private func transcribeWithDashScope(
        audioURL: URL,
        token: String
    ) async throws -> String {
        let audioData = try Data(contentsOf: audioURL)
        guard !audioData.isEmpty else { throw OpenTypeError.emptyRecording }
        let dataURI = "data:audio/wav;base64,\(audioData.base64EncodedString())"
        let body = ASRRequestBuilder.body(
            model: selection.speechModel,
            dataURI: dataURI,
            languageCode: selection.transcriptionLanguage.code(for: .dashScope)
        )
        let data = try await postJSON(
            url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(token)"],
            body: body,
            timeout: 90
        )
        let text = try ResponseParser.content(from: data)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenTypeError.emptyRecording }
        return text
    }

    private func transcribeWithOpenAI(
        audioURL: URL,
        token: String,
        personalVocabulary: [String]
    ) async throws -> String {
        var multipart = MultipartFormDataBuilder()
        multipart.addField(name: "model", value: selection.speechModel)
        if let languageCode = selection.transcriptionLanguage.code(for: .openAI) {
            multipart.addField(name: "language", value: languageCode)
        }
        if !personalVocabulary.isEmpty {
            multipart.addField(
                name: "prompt",
                value: "Vocabulary: \(personalVocabulary.joined(separator: ", "))"
            )
        }
        try multipart.addFile(
            name: "file",
            filename: audioURL.lastPathComponent,
            mimeType: "audio/wav",
            fileURL: audioURL
        )
        let data = try await postMultipart(
            url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
            headers: ["Authorization": "Bearer \(token)"],
            multipart: multipart,
            timeout: 90
        )
        return try transcriptionText(from: data)
    }

    private func transcribeWithElevenLabs(
        audioURL: URL,
        token: String
    ) async throws -> String {
        var multipart = MultipartFormDataBuilder()
        multipart.addField(name: "model_id", value: selection.speechModel)
        if let languageCode = selection.transcriptionLanguage.code(for: .elevenLabs) {
            multipart.addField(name: "language_code", value: languageCode)
        }
        try multipart.addFile(
            name: "file",
            filename: audioURL.lastPathComponent,
            mimeType: "audio/wav",
            fileURL: audioURL
        )
        let data = try await postMultipart(
            url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
            headers: ["xi-api-key": token],
            multipart: multipart,
            timeout: 90
        )
        return try transcriptionText(from: data)
    }

    private func transcriptionText(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text"] as? String else {
            throw OpenTypeError.invalidResponse
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw OpenTypeError.emptyRecording }
        return normalized
    }

    private func postJSON(
        url: URL,
        headers: [String: String],
        body: [String: Any],
        timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func postMultipart(
        url: URL,
        headers: [String: String],
        multipart: MultipartFormDataBuilder,
        timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(
            "multipart/form-data; boundary=\(multipart.boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = multipart.finalizedData()
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenTypeError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let serviceMessage = ResponseParser.errorMessage(from: data)
                ?? anthropicErrorMessage(from: data)
                ?? "模型请求失败（HTTP \(http.statusCode)）"
            throw OpenTypeError.service(serviceMessage)
        }
        return data
    }

    private func anthropicErrorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

struct MultipartFormDataBuilder {
    let boundary = "OpenType-\(UUID().uuidString)"
    private var data = Data()

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func addFile(
        name: String,
        filename: String,
        mimeType: String,
        fileURL: URL
    ) throws {
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        )
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(try Data(contentsOf: fileURL))
        append("\r\n")
    }

    func finalizedData() -> Data {
        var result = data
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func append(_ string: String) {
        data.append(Data(string.utf8))
    }
}
