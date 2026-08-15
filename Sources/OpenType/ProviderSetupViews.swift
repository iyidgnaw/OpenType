import SwiftUI

/// Shared provider-configuration UI: a Whisper (local/remote) picker and an
/// LLM provider (Anthropic/OpenAI-compatible) picker with Test Connection +
/// model listing, each backed by `AppModel`'s `/config/*` wrappers
/// (`AppModel.swift`'s "Provider configuration" section, which themselves
/// call the sidecar's `provider/routes.ts`). Both the first-run
/// `OnboardingWizardView` below and `SettingsDetailColumn`
/// (`SettingsViews2.swift`, "语音识别"/"AI 模型" routes) embed these same two
/// content views rather than each having their own copy — per the task's
/// "reuse the same underlying config/test/model-list logic and UI
/// components" requirement.

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
/// whenever `AppModel.needsProviderOnboarding` is true -- i.e. per
/// `OnboardingPolicy`, the user has neither configured Whisper nor taken the
/// "just local transcription, skip AI setup" path yet (an LLM is deferred, not
/// required to enter the app -- P1-19). Reuses `WhisperSetupContent`/
/// `LLMProviderSetupContent` verbatim (same components `SettingsDetailColumn`
/// uses), so there is exactly one implementation of "configure + test + list
/// + save", not a parallel wizard-only copy. Disappears automatically the moment
/// Whisper is saved or the local-only path is acknowledged --
/// `AppModel.saveWhisperConfig` refreshes `providerConfigStatus` and
/// `chooseLocalOnly` sets `localTranscriptionOnlyAcknowledged`, either of which
/// flips `needsProviderOnboarding` to false and lets `RootView` fall through to
/// its normal tab content on the next body evaluation. No separate "Finish"
/// action is needed for that reason; a lightweight completion banner just
/// confirms it happened.
struct OnboardingWizardView: View {
    @ObservedObject var model: AppModel

    @State private var isChoosingLocalOnly = false
    @State private var localOnlyError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(OpenTypeL10n.text("欢迎使用 OpenType", english: "Welcome to OpenType"))
                        .font(.system(size: 18, weight: .bold))
                    Text(OpenTypeL10n.text(
                        "先授予权限并设置语音识别即可开始使用。AI 模型（问答 / Agent 需要）可以稍后再配置。",
                        english: "Grant permissions and set up speech recognition to get started. The AI model provider (needed for Ask / Agent) can wait until later."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                // Permissions first: recording and Accessibility gate every
                // mode, so guide those before any provider credentials.
                OnboardingStepCard(
                    title: OpenTypeL10n.text("1. 权限", english: "1. Permissions"),
                    done: model.microphonePermission == .granted && model.accessibilityGranted
                ) {
                    OnboardingPermissionsContent(model: model)
                }

                OnboardingStepCard(
                    title: OpenTypeL10n.text("2. 语音识别", english: "2. Speech recognition"),
                    done: model.providerConfigStatus?.whisperConfigured == true
                ) {
                    WhisperSetupContent(model: model)
                }

                OnboardingStepCard(
                    title: OpenTypeL10n.text("3. AI 模型（可选）", english: "3. AI model provider (optional)"),
                    done: model.providerConfigStatus?.llmConfigured == true
                ) {
                    LLMProviderSetupContent(model: model)
                }

                // Escape hatch for transcribe-only users: acknowledge local-only
                // and persist whisper=local so `needsProviderOnboarding` flips to
                // false and the wizard dismisses to the normal tabs. Ask/Agent
                // will still prompt for an LLM later, when a mode needs it.
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        chooseLocalOnly()
                    } label: {
                        if isChoosingLocalOnly {
                            Text(OpenTypeL10n.text("正在设置…", english: "Setting up…"))
                        } else {
                            Text(OpenTypeL10n.text(
                                "仅本地听写，跳过 AI 配置",
                                english: "Just local transcription — skip AI setup"
                            ))
                        }
                    }
                    .controlSize(.small)
                    .disabled(isChoosingLocalOnly)

                    if let localOnlyError {
                        Text(localOnlyError)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(OpenTypeL10n.text(
                    "之后可以随时在“设置”中重新配置。",
                    english: "You can reconfigure any of these anytime from Settings."
                ))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseLocalOnly() {
        isChoosingLocalOnly = true
        localOnlyError = nil
        Task { @MainActor in
            do {
                // Persist whisper=local via the normal save path so ASR is the
                // explicit choice (whisperConfigured becomes true) ...
                _ = try await model.saveWhisperConfig(mode: .local)
                // ... and record the acknowledgment so the local-only decision
                // survives relaunch even independently of whisper state.
                model.configuration.localTranscriptionOnlyAcknowledged = true
                isChoosingLocalOnly = false
            } catch {
                model.configuration.localTranscriptionOnlyAcknowledged = true
                isChoosingLocalOnly = false
                localOnlyError = error.localizedDescription
            }
        }
    }
}

/// Microphone + Accessibility guidance shown as the wizard's first step. Reuses
/// `AppModel`'s existing permission state/actions (the same ones Settings'
/// "连接与权限" section drives), so there is one implementation of the request
/// flow, not a wizard-only copy.
private struct OnboardingPermissionsContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(OpenTypeL10n.text(
                "OpenType 需要麦克风来录音，需要辅助功能来读取选中文本并写回结果。",
                english: "OpenType needs the microphone to record, and Accessibility to read your selection and write results back."
            ))
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label(
                    OpenTypeL10n.text(
                        "麦克风\(model.microphonePermission.title)",
                        english: "Microphone \(model.microphonePermission.title)"
                    ),
                    systemImage: model.microphonePermission.symbol
                )
                .font(.system(size: 11))
                .foregroundStyle(model.microphonePermission == .granted ? Color.secondary : Color.orange)
                Spacer()
                if model.microphonePermission != .granted {
                    Button(model.microphonePermission == .denied
                        ? OpenTypeL10n.text("打开设置", english: "Open Settings")
                        : OpenTypeL10n.text("授权", english: "Allow")
                    ) {
                        model.requestMicrophonePermission()
                    }
                    .controlSize(.small)
                }
            }

            HStack {
                Label(
                    model.accessibilityGranted
                        ? OpenTypeL10n.text("辅助功能已授权", english: "Accessibility granted")
                        : OpenTypeL10n.text("辅助功能未授权", english: "Accessibility not granted"),
                    systemImage: model.accessibilityGranted ? "circle.fill" : "circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(model.accessibilityGranted ? Color.secondary : Color.orange)
                Spacer()
                if !model.accessibilityGranted {
                    Button(OpenTypeL10n.text("授权", english: "Allow")) {
                        model.requestAccessibility()
                    }
                    .controlSize(.small)
                }
            }
        }
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
