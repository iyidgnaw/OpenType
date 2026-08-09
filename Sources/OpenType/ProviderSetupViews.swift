import SwiftUI

/// Shared provider-configuration UI: a Whisper (local/remote) picker and an
/// LLM provider (Anthropic/OpenAI-compatible) picker with Test Connection +
/// model listing, each backed by `AppModel`'s `/config/*` wrappers
/// (`AppModel.swift`'s "Provider configuration" section, which themselves
/// call the sidecar's `provider/routes.ts`). Both the first-run
/// `OnboardingWizardView` below and `SettingsView` (`Views.swift`, "语音识别"/
/// "AI 模型" sections) embed these same two content views rather than each
/// having their own copy — per the task's "reuse the same underlying
/// config/test/model-list logic and UI components" requirement.

// MARK: - Whisper

struct WhisperSetupContent: View {
    @ObservedObject var model: AppModel
    /// Invoked after a successful save — the wizard uses this to know when
    /// to re-check overall readiness; Settings doesn't need it.
    var onSaved: (() -> Void)?

    @State private var mode: WhisperMode = .local
    @State private var baseUrl: String = ""
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var testResult: ProviderTestResultSummary?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var didLoadExisting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = model.whisperConfigSummary, summary.configured {
                Label(
                    OpenTypeL10n.text(
                        "当前已配置：\(summary.mode?.title ?? "")",
                        english: "Currently configured: \(summary.mode?.title ?? "")"
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.green)
            }

            Picker(
                OpenTypeL10n.text("方式", english: "Mode"),
                selection: $mode
            ) {
                ForEach(WhisperMode.allCases) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
            .pickerStyle(.segmented)

            if mode == .local {
                Text(OpenTypeL10n.text(
                    "使用本机运行的 MLX-Whisper，无需联网、无需 API Key。",
                    english: "Uses the locally-running MLX-Whisper — no network or API key required."
                ))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                TextField(
                    "Base URL",
                    text: $baseUrl,
                    prompt: Text("https://api.openai.com/v1")
                )
                .textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                TextField(
                    OpenTypeL10n.text("模型（默认 whisper-1）", english: "Model (defaults to whisper-1)"),
                    text: $modelName
                )
                .textFieldStyle(.roundedBorder)

                Text(OpenTypeL10n.text(
                    "实现基于 OpenAI 的 /v1/audio/transcriptions 接口，可填写自建的兼容服务地址，不限于 api.openai.com。",
                    english: "Implemented against OpenAI's /v1/audio/transcriptions shape — point this at any OpenAI-API-compatible server, not just api.openai.com."
                ))
                .font(.system(size: 8.8))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(isTesting
                        ? OpenTypeL10n.text("测试中…", english: "Testing…")
                        : OpenTypeL10n.text("测试连接", english: "Test Connection")
                    ) {
                        testConnection()
                    }
                    .controlSize(.small)
                    .disabled(baseUrl.isEmpty || apiKey.isEmpty || isTesting)

                    if let testResult {
                        if testResult.success {
                            Label(
                                OpenTypeL10n.text("连接成功", english: "Connected"),
                                systemImage: "checkmark.circle.fill"
                            )
                            .font(.system(size: 9.5))
                            .foregroundStyle(.green)
                        } else {
                            Label(
                                testResult.error ?? OpenTypeL10n.text("连接失败", english: "Connection failed"),
                                systemImage: "xmark.circle.fill"
                            )
                            .font(.system(size: 9.5))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Button(isSaving
                ? OpenTypeL10n.text("保存中…", english: "Saving…")
                : OpenTypeL10n.text("保存", english: "Save")
            ) {
                save()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || (mode == .remote && (baseUrl.isEmpty || apiKey.isEmpty)))

            if let saveError {
                Text(saveError)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            guard !didLoadExisting else { return }
            didLoadExisting = true
            await loadExisting()
        }
    }

    private func loadExisting() async {
        await model.refreshWhisperConfigSummary()
        guard let summary = model.whisperConfigSummary, summary.configured else { return }
        mode = summary.mode ?? .local
        baseUrl = summary.baseUrl ?? ""
        modelName = summary.model ?? ""
        // apiKey is deliberately left blank -- the sidecar never echoes the
        // real key back, only a masked preview (`summary.apiKeyMasked`); an
        // unchanged blank field on save would otherwise need special
        // "keep existing key" handling this v1 doesn't implement, so
        // changing modes/re-saving remote config requires re-entering it.
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task { @MainActor in
            testResult = await model.testWhisperConnection(baseUrl: baseUrl, apiKey: apiKey)
            isTesting = false
        }
    }

    private func save() {
        isSaving = true
        saveError = nil
        Task { @MainActor in
            do {
                _ = try await model.saveWhisperConfig(
                    mode: mode,
                    baseUrl: mode == .remote ? baseUrl : nil,
                    apiKey: mode == .remote ? apiKey : nil,
                    model: mode == .remote && !modelName.isEmpty ? modelName : nil
                )
                isSaving = false
                onSaved?()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}

// MARK: - LLM provider

struct LLMProviderSetupContent: View {
    @ObservedObject var model: AppModel
    var onSaved: (() -> Void)?

    @State private var providerType: LLMProviderType = .openaiCompatible
    @State private var baseUrl: String = ""
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var testResult: ProviderTestResultSummary?
    @State private var isTesting = false
    @State private var isListingModels = false
    @State private var availableModels: [String] = []
    @State private var modelsAreFallback = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var didLoadExisting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = model.llmConfigSummary, summary.configured {
                Label(
                    OpenTypeL10n.text(
                        "当前已配置：\(summary.type?.title ?? "") · \(summary.model ?? "")",
                        english: "Currently configured: \(summary.type?.title ?? "") · \(summary.model ?? "")"
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.green)
            }

            Picker(
                OpenTypeL10n.text("提供方", english: "Provider"),
                selection: $providerType
            ) {
                ForEach(LLMProviderType.allCases) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: providerType) { newValue in
                resetTestAndModelState()
                if baseUrl.isEmpty {
                    baseUrl = newValue.baseUrlPlaceholder
                }
            }

            TextField(
                "Base URL",
                text: $baseUrl,
                prompt: Text(providerType.baseUrlPlaceholder)
            )
            .textFieldStyle(.roundedBorder)
            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button(isTesting
                    ? OpenTypeL10n.text("测试中…", english: "Testing…")
                    : OpenTypeL10n.text("测试连接", english: "Test Connection")
                ) {
                    testConnection()
                }
                .controlSize(.small)
                .disabled(baseUrl.isEmpty || apiKey.isEmpty || isTesting)

                if let testResult {
                    if testResult.success {
                        Label(
                            OpenTypeL10n.text("连接成功", english: "Connected"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.system(size: 9.5))
                        .foregroundStyle(.green)
                    } else {
                        Label(
                            testResult.error ?? OpenTypeL10n.text("连接失败", english: "Connection failed"),
                            systemImage: "xmark.circle.fill"
                        )
                        .font(.system(size: 9.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if isListingModels {
                Label(
                    OpenTypeL10n.text("正在获取模型列表…", english: "Fetching model list…"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            }

            if !availableModels.isEmpty {
                Picker(
                    OpenTypeL10n.text("模型", english: "Model"),
                    selection: $modelName
                ) {
                    ForEach(availableModels, id: \.self) { candidate in
                        Text(candidate).tag(candidate)
                    }
                }
                .pickerStyle(.menu)

                if modelsAreFallback {
                    Text(OpenTypeL10n.text(
                        "该提供方未返回模型列表，以下为常见模型，可能不完整或已过期。",
                        english: "This provider didn't return a live model list — showing known common models, which may be incomplete or outdated."
                    ))
                    .font(.system(size: 8.8))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                TextField(
                    OpenTypeL10n.text("模型名称（测试连接后可从列表选择）", english: "Model name (or Test Connection to pick from a list)"),
                    text: $modelName
                )
                .textFieldStyle(.roundedBorder)
            }

            Button(isSaving
                ? OpenTypeL10n.text("保存中…", english: "Saving…")
                : OpenTypeL10n.text("保存", english: "Save")
            ) {
                save()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(baseUrl.isEmpty || apiKey.isEmpty || modelName.isEmpty || isSaving)

            if let saveError {
                Text(saveError)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            guard !didLoadExisting else { return }
            didLoadExisting = true
            await loadExisting()
        }
    }

    private func resetTestAndModelState() {
        testResult = nil
        availableModels = []
        modelsAreFallback = false
    }

    private func loadExisting() async {
        await model.refreshLLMConfigSummary()
        if let summary = model.llmConfigSummary, summary.configured {
            providerType = summary.type ?? .openaiCompatible
            baseUrl = summary.baseUrl ?? providerType.baseUrlPlaceholder
            modelName = summary.model ?? ""
        }
        if baseUrl.isEmpty {
            baseUrl = providerType.baseUrlPlaceholder
        }
        // apiKey deliberately left blank -- see WhisperSetupContent's
        // matching comment; the sidecar never echoes the real key back.
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        availableModels = []
        Task { @MainActor in
            let result = await model.testLLMConnection(type: providerType, baseUrl: baseUrl, apiKey: apiKey)
            testResult = result
            isTesting = false
            if result.success {
                await loadModels()
            }
        }
    }

    private func loadModels() async {
        isListingModels = true
        defer { isListingModels = false }
        do {
            let list = try await model.listLLMModels(type: providerType, baseUrl: baseUrl, apiKey: apiKey)
            availableModels = list.models
            modelsAreFallback = list.fallback
            if modelName.isEmpty, let first = list.models.first {
                modelName = first
            }
        } catch {
            // Listing failed outright (not even the sidecar's hardcoded
            // fallback, e.g. the sidecar itself is unreachable) -- leave
            // `availableModels` empty so the plain text field stays up as a
            // manual-entry fallback rather than showing a broken picker.
        }
    }

    private func save() {
        isSaving = true
        saveError = nil
        Task { @MainActor in
            do {
                _ = try await model.saveLLMConfig(
                    type: providerType,
                    baseUrl: baseUrl,
                    apiKey: apiKey,
                    model: modelName
                )
                isSaving = false
                onSaved?()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}

// MARK: - First-run onboarding wizard

/// Shown instead of the normal Home tab (see `RootView` in `Views.swift`)
/// whenever `AppModel.needsProviderOnboarding` is true -- i.e. the sidecar's
/// `/config/status` reports the user hasn't explicitly finished configuring
/// both Whisper and an LLM provider yet. Reuses `WhisperSetupContent`/
/// `LLMProviderSetupContent` verbatim (same components `SettingsView` uses),
/// so there is exactly one implementation of "configure + test + list +
/// save", not a parallel wizard-only copy. Disappears automatically the
/// moment both are saved -- `AppModel.saveWhisperConfig`/`saveLLMConfig`
/// both refresh `providerConfigStatus`, which flips `needsProviderOnboarding`
/// to false and lets `RootView` fall through to its normal tab content on
/// the next body evaluation. No separate "Finish" action is needed for that
/// reason; a lightweight completion banner just confirms it happened.
struct OnboardingWizardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(OpenTypeL10n.text("欢迎使用 OpenType", english: "Welcome to OpenType"))
                        .font(.system(size: 18, weight: .bold))
                    Text(OpenTypeL10n.text(
                        "开始之前，请先配置语音识别和 AI 模型提供方。两项都设置完成后即可正常使用。",
                        english: "Before you start, set up speech recognition and an AI model provider below. Once both are configured, OpenType is ready to use."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                OnboardingStepCard(
                    title: OpenTypeL10n.text("1. 语音识别", english: "1. Speech recognition"),
                    done: model.providerConfigStatus?.whisperConfigured == true
                ) {
                    WhisperSetupContent(model: model)
                }

                OnboardingStepCard(
                    title: OpenTypeL10n.text("2. AI 模型", english: "2. AI model provider"),
                    done: model.providerConfigStatus?.llmConfigured == true
                ) {
                    LLMProviderSetupContent(model: model)
                }

                Text(OpenTypeL10n.text(
                    "之后可以随时在“设置”中重新配置。",
                    english: "You can reconfigure either of these anytime from Settings."
                ))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingStepCard<Content: View>: View {
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }
}
