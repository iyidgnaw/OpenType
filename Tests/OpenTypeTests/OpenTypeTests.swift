import Foundation
import SQLite3
import XCTest
@testable import OpenType

final class OpenTypeTests: XCTestCase {
    func testEnvironmentParserHandlesQuotesAndExport() {
        let values = EnvironmentFileParser.parse(
            """
            # comment
            export DASHSCOPE_API_KEY="secret-value"
            DASHSCOPE_ASR_MODEL='qwen3-asr-flash'
            EMPTY=
            """
        )

        XCTAssertEqual(values["DASHSCOPE_API_KEY"], "secret-value")
        XCTAssertEqual(values["DASHSCOPE_ASR_MODEL"], "qwen3-asr-flash")
        XCTAssertEqual(values["EMPTY"], "")
    }

    func testSelectionRequiredErrorUsesGenericMessage() {
        // No remaining mode (transcribe/ask/agent) requires a selection, so
        // this error path is unreachable in practice; it still needs a
        // sensible generic message for forward compatibility.
        XCTAssertEqual(
            OpenTypeError.selectionRequired(.ask).errorDescription,
            "这个模式需要先选中文字"
        )
    }

    func testTechnicalASRErrorBecomesHumanReadable() {
        let message = ErrorMessagePresenter.message(
            for: OpenTypeError.service(
                "<400> InternalError.Algo.InvalidParameter: does not support this input"
            )
        )

        XCTAssertEqual(message, "这段语音没有识别成功，请再说一次")
    }

    func testCopiedStateExplainsClipboardFallback() {
        XCTAssertEqual(ProcessingState.copied.title, "已复制")
        XCTAssertEqual(ProcessingState.copied.symbol, "doc.on.clipboard.fill")
    }

    func testSendCommandIsRemovedFromTail() {
        let result = SendCommandParser.parse(
            "这就是我今天的判断。按回车",
            enabled: true
        )
        XCTAssertEqual(result.text, "这就是我今天的判断。")
        XCTAssertTrue(result.pressEnter)
    }

    func testSendCommandAllowsASRTrailingPunctuationAndKeepsQuestionMark() {
        let result = SendCommandParser.parse(
            "你睡了吗？发送。",
            enabled: true
        )
        XCTAssertEqual(result.text, "你睡了吗？")
        XCTAssertTrue(result.pressEnter)
    }

    func testSendCommandDoesNotTriggerWhenSendIsPartOfTheSentence() {
        let result = SendCommandParser.parse(
            "我想聊聊发送机制。",
            enabled: true
        )
        XCTAssertEqual(result.text, "我想聊聊发送机制。")
        XCTAssertFalse(result.pressEnter)
    }

    func testVoiceModeRouterDoesNotMisreadOrdinarySentence() {
        let result = VoiceModeRouter.route(
            "英文产品的增长很快",
            currentMode: .ask
        )

        XCTAssertEqual(result.mode, .ask)
        XCTAssertEqual(result.text, "英文产品的增长很快")
    }

    func testModeCycleFollowsVisibleModeOrderAndWraps() {
        XCTAssertEqual(InputMode.transcribe.next, .ask)
        XCTAssertEqual(InputMode.ask.next, .agent)
        XCTAssertEqual(InputMode.agent.next, .transcribe)
        XCTAssertNil(InputMode(rawValue: "clean"))
        XCTAssertNil(InputMode(rawValue: "command"))
        XCTAssertNil(InputMode(rawValue: "sidecarPolish"))
    }

    func testVoiceModeRouterRecognizesCommandInputName() {
        let result = VoiceModeRouter.route(
            "命令输入：帮我写一封简短的感谢邮件",
            currentMode: .ask
        )

        XCTAssertEqual(result.mode, .agent)
        XCTAssertEqual(result.text, "帮我写一封简短的感谢邮件")
    }

    func testVoiceModeRouterRecognizesAgentModeName() {
        let result = VoiceModeRouter.route(
            "Agent 模式：继续刚才的任务",
            currentMode: .ask
        )

        XCTAssertEqual(result.mode, .agent)
        XCTAssertEqual(result.text, "继续刚才的任务")
    }

    func testModeChangedOverlayHasExplicitStatus() {
        XCTAssertEqual(ProcessingState.modeChanged.title, "已切换模式")
        XCTAssertEqual(
            ProcessingState.modeChanged.symbol,
            "arrow.triangle.2.circlepath"
        )
        XCTAssertEqual(
            ProcessingState.modeChanged.overlayDetail(for: .ask),
            "问答"
        )
    }

    func testMissingEditInstructionUsesNeutralCancelledState() {
        let state = ProcessingState.cancelled("没有明确修改指令，原文保持不变")
        XCTAssertEqual(state.title, "未执行")
        XCTAssertEqual(state.symbol, "circle.slash")
        XCTAssertEqual(
            state.overlayDetail(for: .ask),
            "没有明确修改指令，原文保持不变"
        )
    }

    func testFailureOverlayShowsTheActionableReason() {
        let message = "请先选中要编辑的文字，再开始说话"
        let state = ProcessingState.failure(message)

        XCTAssertEqual(state.title, "出现问题")
        XCTAssertEqual(state.overlayDetail(for: .ask), message)
    }

    func testDispatchedStateShowsTheAcknowledgementMessageAndIsNotBusy() {
        // Part B: Agent-mode dispatch is a transient, non-blocking
        // acknowledgement — distinct from `.success`/`.copied` because
        // nothing has actually finished when it's shown.
        let message = "已下发给 Agent"
        let state = ProcessingState.dispatched(message)

        XCTAssertEqual(state.title, "已下发")
        XCTAssertEqual(state.symbol, "paperplane.fill")
        XCTAssertEqual(state.overlayDetail(for: .agent), message)
    }

    func testEveryModeKeepsItsResultOnTheClipboard() {
        for mode in InputMode.allCases {
            XCTAssertTrue(
                OutputDeliveryPolicy.retainsClipboardCopy(for: mode),
                "Expected \(mode.title) to retain a clipboard copy"
            )
        }
    }

    func testRegularModesRespectAutomaticInsertSetting() {
        XCTAssertEqual(
            OutputDeliveryPolicy.strategy(
                for: .transcribe,
                automaticallyInsert: true
            ),
            .automaticInsert
        )
        XCTAssertEqual(
            OutputDeliveryPolicy.strategy(
                for: .ask,
                automaticallyInsert: false
            ),
            .clipboard
        )
    }

    func testNoModeRequiresSelectionInTheThreeModeDesign() {
        for mode in InputMode.allCases {
            XCTAssertFalse(
                mode.requiresSelection,
                "Expected \(mode.title) not to require a selection"
            )
        }
    }

    func testAgentNeverTriggersAutomaticEnter() {
        XCTAssertFalse(
            OutputDeliveryPolicy.permitsAutomaticEnter(for: .agent)
        )
        XCTAssertTrue(
            OutputDeliveryPolicy.permitsAutomaticEnter(for: .transcribe)
        )
        XCTAssertTrue(
            OutputDeliveryPolicy.permitsAutomaticEnter(for: .ask)
        )
    }

    func testDoubleTapDetectorTriggersWithinThreshold() {
        var detector = DoubleTapDetector(threshold: 0.45)
        XCTAssertFalse(detector.registerTap(at: 10))
        XCTAssertTrue(detector.registerTap(at: 10.4))
        XCTAssertNil(detector.lastTap)
    }

    func testDoubleTapDetectorRejectsSlowSecondTap() {
        var detector = DoubleTapDetector(threshold: 0.45)
        XCTAssertFalse(detector.registerTap(at: 10))
        XCTAssertFalse(detector.registerTap(at: 10.6))
        XCTAssertEqual(detector.lastTap, 10.6)
    }

    func testHotKeyPresetsExposeConflictFreeControlShiftOption() {
        XCTAssertEqual(HotKeyPreset.controlShiftSpace.title, "⌃⇧ Space")
        XCTAssertEqual(
            HotKeyPreset.controlShiftSpace.keys,
            ["⌃", "⇧", "Space"]
        )
        XCTAssertFalse(HotKeyPreset.controlShiftSpace.usesDoubleModifierTap)
        XCTAssertTrue(HotKeyPreset.doubleControl.usesDoubleModifierTap)
        XCTAssertTrue(HotKeyPreset.leftOption.usesModifierOnlyEventTap)
        XCTAssertFalse(HotKeyPreset.leftOption.usesDoubleModifierTap)
        XCTAssertTrue(HotKeyPreset.leftOption.usesOptionHybridGesture)
        XCTAssertEqual(HotKeyPreset.leftOption.keys, ["左 Option"])
    }

    @MainActor
    func testSelectedHotKeyPersists() {
        let suiteName = "OpenTypeTests.HotKey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertEqual(configuration.hotKeyPreset, .leftOption)

        configuration.hotKeyPreset = .controlShiftSpace
        let reloaded = AppConfiguration(defaults: defaults)
        XCTAssertEqual(reloaded.hotKeyPreset, .controlShiftSpace)
    }

    @MainActor
    func testLegacySelectedEditModeFallsBackToDefaultMode() {
        let suiteName = "OpenTypeTests.SmartEditMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // "command" was a retired mode's raw value; an unrecognized legacy
        // string must fall back to the current default rather than crash.
        defaults.set("command", forKey: "selectedMode")

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertEqual(configuration.selectedMode, InputMode.visibleModes[0])
    }

    @MainActor
    func testFeedbackSoundSettingPersists() {
        let suiteName = "OpenTypeTests.Sound.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertTrue(configuration.playFeedbackSounds)
        configuration.playFeedbackSounds = false

        let reloaded = AppConfiguration(defaults: defaults)
        XCTAssertFalse(reloaded.playFeedbackSounds)
        XCTAssertTrue(reloaded.isMuted)
    }

    func testFeedbackSoundCuesCoverTheVoiceLifecycle() {
        XCTAssertEqual(
            FeedbackSoundCue.allCases.map(\.resourceName),
            [
                "OpenTypeReady",
                "OpenTypeRelease",
                "OpenTypeDone",
                "OpenTypeIssue"
            ]
        )
        XCTAssertEqual(
            Set(FeedbackSoundCue.allCases.map(\.resourceName)).count,
            FeedbackSoundCue.allCases.count
        )
        XCTAssertTrue(FeedbackSoundCue.allCases.allSatisfy { $0.volume < 0.75 })
    }

    @MainActor
    func testAgentMemorySettingPersists() {
        let suiteName = "OpenTypeTests.AgentMemorySetting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertTrue(configuration.agentMemoryEnabled)
        configuration.agentMemoryEnabled = false

        let reloaded = AppConfiguration(defaults: defaults)
        XCTAssertFalse(reloaded.agentMemoryEnabled)
    }

    @MainActor
    func testColorThemeDefaultsToOceanAndPersistsSelection() {
        let suiteName = "OpenTypeTests.ColorTheme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertEqual(configuration.colorTheme, .ocean)
        configuration.colorTheme = .violet

        let reloaded = AppConfiguration(defaults: defaults)
        XCTAssertEqual(reloaded.colorTheme, .violet)
        XCTAssertEqual(AppColorTheme.allCases.count, 6)
        XCTAssertEqual(
            Set(AppColorTheme.allCases.map(\.title)).count,
            AppColorTheme.allCases.count
        )
    }

    @MainActor
    func testInterfaceLanguageDefaultsToChineseAndPersistsEnglish() {
        let suiteName = "OpenTypeTests.InterfaceLanguage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            OpenTypeL10n.language = .chinese
        }

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertEqual(configuration.interfaceLanguage, .chinese)
        configuration.interfaceLanguage = .english

        let reloaded = AppConfiguration(defaults: defaults)
        XCTAssertEqual(reloaded.interfaceLanguage, .english)
        XCTAssertEqual(InputMode.transcribe.title, "Transcribe")
    }

    @MainActor
    func testAutomaticOwnerProfileUpdateSettingPersists() {
        let suiteName = "OpenTypeTests.AutoProfileSetting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertTrue(configuration.automaticOwnerProfileUpdates)
        configuration.automaticOwnerProfileUpdates = false

        let reloaded = AppConfiguration(defaults: defaults)
        XCTAssertFalse(reloaded.automaticOwnerProfileUpdates)
    }

    func testAutomaticLearningNeverMutatesConfirmedProfile() {
        let profile = OwnerProfile(
            identityAndWork: "我是 Rain，正在做 AI Agent 产品。\nOpenType 自动归纳的近期任务：内容写作。",
            communicationStyle: "简洁、直接。\nOpenType 自动归纳的表达偏好：主要使用中文。",
            importantTerms: "OpenType、OpenClaw\nOpenType 自动归纳的术语：Agent。",
            preferredLanguage: .chinese,
            updatedAt: nil
        )
        let insights = MemoryInsights(
            observedTaskCount: 100,
            commonTerms: ["Agent", "的话", "Open"],
            taskDomains: ["产品与 AI 工具", "内容写作与编辑"],
            languagePattern: "主要使用中文，经常混合英文专业词",
            stylePreferences: ["自然、口语化、低 AI 味"],
            updatedAt: Date()
        )

        let updated = OwnerProfileAutoUpdater.merging(
            profile: profile,
            insights: insights,
            personalDictionary: ["Rain", "OpenType", "OpenClaw"]
        )

        XCTAssertEqual(updated.identityAndWork, "我是 Rain，正在做 AI Agent 产品。")
        XCTAssertEqual(updated.communicationStyle, "简洁、直接。")
        XCTAssertEqual(updated.importantTerms, "OpenType、OpenClaw")
        XCTAssertEqual(updated.preferredLanguage, .chinese)
        XCTAssertFalse(updated.identityAndWork.contains("自动归纳"))
        XCTAssertFalse(updated.communicationStyle.contains("主要使用中文"))
    }

    func testLegacyProfileExtractsOnlyExplicitDefaultLanguage() {
        let explicit = OwnerProfileAutoUpdater.removingLegacyManagedLines(
            from: OwnerProfile(
                identityAndWork: "AI 产品经理",
                communicationStyle: "中文为主，简洁直接。",
                importantTerms: "OpenType"
            )
        )
        XCTAssertEqual(explicit.preferredLanguage, .chinese)

        let inferredOnly = OwnerProfileAutoUpdater.removingLegacyManagedLines(
            from: OwnerProfile(
                identityAndWork: "AI 产品经理",
                communicationStyle: "OpenType 自动归纳的表达偏好：主要使用中文。",
                importantTerms: "OpenType"
            )
        )
        XCTAssertEqual(inferredOnly.preferredLanguage, .followInput)
    }

    @MainActor
    func testAutomaticLearnedPreferencesUpdateAtOneHundredWithoutRewritingProfile() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenType-AutoProfile-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
            }
        }

        let store = AgentMemoryStore(fileURL: fileURL)
        let confirmedProfile = OwnerProfile(
            identityAndWork: "我在做 AI Agent 产品",
            communicationStyle: "简洁、直接",
            importantTerms: "OpenType",
            preferredLanguage: .chinese
        )
        XCTAssertTrue(store.updateOwnerProfile(confirmedProfile))
        let history = (0..<100).map { index in
            HistoryEntry(
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                mode: .transcribe,
                applicationName: "OpenType",
                transcript: "请帮我优化 OpenType 产品文案，要简洁直接",
                result: "完成 \(index)",
                contextPreview: nil
            )
        }
        store.importHistoryIfNeeded(history)

        XCTAssertEqual(store.eventCount, 100)
        XCTAssertTrue(
            store.refreshOwnerProfileIfNeeded(
                enabled: true,
                personalDictionary: ["OpenType"]
            )
        )
        XCTAssertEqual(store.lastAutomaticProfileEventCount, 100)
        XCTAssertEqual(store.ownerProfile.identityAndWork, confirmedProfile.identityAndWork)
        XCTAssertEqual(store.ownerProfile.communicationStyle, confirmedProfile.communicationStyle)
        XCTAssertEqual(store.ownerProfile.importantTerms, confirmedProfile.importantTerms)
        XCTAssertEqual(store.ownerProfile.preferredLanguage, .chinese)
        XCTAssertFalse(store.learnedPreferences.taskDomains.isEmpty)
        XCTAssertEqual(
            store.profileContextForPrompt().insights,
            store.learnedPreferences
        )
        XCTAssertFalse(
            store.refreshOwnerProfileIfNeeded(
                enabled: true,
                personalDictionary: ["OpenType"]
            )
        )

        let reloaded = AgentMemoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.ownerProfile.preferredLanguage, .chinese)
        XCTAssertEqual(reloaded.learnedPreferences, store.learnedPreferences)
    }

    func testLocalMemoryEmbeddingRoundTripPreservesVector() {
        let original: [Float] = [0.25, -0.5, 1.75, 0]
        let decoded = LocalMemoryEmbedding.decoded(
            LocalMemoryEmbedding.encoded(original)
        )
        XCTAssertEqual(decoded, original)
    }

    @MainActor
    func testMemoryRetrieverKeepsRecentContextAndFindsOlderRelevantTask() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenType-Retrieval-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
            }
        }

        let store = AgentMemoryStore(fileURL: fileURL)
        let relevant = MemoryEvent(
            createdAt: Date(timeIntervalSince1970: 100),
            mode: .agent,
            applicationName: "X",
            bundleIdentifier: nil,
            rawTranscript: "帮我写一条 OpenType 产品发布推文",
            effectiveInput: "帮我写一条 OpenType 产品发布推文",
            selectedContext: nil,
            result: "OpenType is live."
        )
        let unrelatedOld = MemoryEvent(
            createdAt: Date(timeIntervalSince1970: 200),
            mode: .agent,
            applicationName: "Calendar",
            bundleIdentifier: nil,
            rawTranscript: "安排下周团队会议",
            effectiveInput: "安排下周团队会议",
            selectedContext: nil,
            result: "会议计划"
        )
        let recentOne = MemoryEvent(
            createdAt: Date(timeIntervalSince1970: 300),
            mode: .ask,
            applicationName: "Notes",
            bundleIdentifier: nil,
            rawTranscript: "整理今天的待办事项",
            effectiveInput: "整理今天的待办事项",
            selectedContext: nil,
            result: "待办清单"
        )
        let recentTwo = MemoryEvent(
            createdAt: Date(timeIntervalSince1970: 400),
            mode: .ask,
            applicationName: "Mail",
            bundleIdentifier: nil,
            rawTranscript: "回复这封感谢邮件",
            effectiveInput: "回复这封感谢邮件",
            selectedContext: nil,
            result: "感谢邮件"
        )
        [relevant, unrelatedOld, recentOne, recentTwo].forEach(store.record)

        let retrieved = store.memoriesForPrompt(
            query: "再写一条 OpenType 上线的 X 推文",
            selectedContext: nil,
            applicationName: "X",
            maximumEntries: 3
        )
        let ids = Set(retrieved.map(\.id))

        XCTAssertTrue(ids.contains(relevant.id))
        XCTAssertTrue(ids.contains(recentOne.id))
        XCTAssertTrue(ids.contains(recentTwo.id))
        XCTAssertFalse(ids.contains(unrelatedOld.id))
        XCTAssertEqual(retrieved.map(\.id), [relevant.id, recentOne.id, recentTwo.id])
    }

    @MainActor
    func testAgentMemoryPersistsStructuredTasksAndUsesChronologicalPromptOrder() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenType-AgentMemory-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    atPath: fileURL.path + suffix
                )
            }
        }

        let store = AgentMemoryStore(fileURL: fileURL, maximumEntries: 3)
        let first = AgentTaskMemory(
            createdAt: Date(timeIntervalSince1970: 100),
            request: "先写第一条",
            outcome: "第一条结果",
            applicationName: "X",
            referencePreview: nil
        )
        let second = AgentTaskMemory(
            createdAt: Date(timeIntervalSince1970: 200),
            request: "再写第二条",
            outcome: "第二条结果",
            applicationName: "X",
            referencePreview: "参考内容"
        )
        store.add(first)
        store.add(second)

        XCTAssertEqual(store.entries.map(\.request), ["再写第二条", "先写第一条"])
        XCTAssertEqual(
            store.entriesForPrompt().map(\.request),
            ["先写第一条", "再写第二条"]
        )
        XCTAssertEqual(store.eventCount, 2)

        store.updateOwnerProfile(
            OwnerProfile(
                identityAndWork: "我在做 AI Agent 产品",
                communicationStyle: "简洁、直接、口语化",
                importantTerms: "OpenType, OpenClaw",
                preferredLanguage: .chinese,
                updatedAt: nil
            )
        )

        let reloaded = AgentMemoryStore(fileURL: fileURL, maximumEntries: 3)
        XCTAssertEqual(reloaded.entries, store.entries)
        XCTAssertEqual(
            reloaded.ownerProfile.identityAndWork,
            "我在做 AI Agent 产品"
        )
        XCTAssertEqual(reloaded.ownerProfile.preferredLanguage, .chinese)

        reloaded.clear()
        XCTAssertTrue(reloaded.entries.isEmpty)
        XCTAssertEqual(reloaded.eventCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(
            reloaded.ownerProfile.communicationStyle,
            "简洁、直接、口语化"
        )
    }

    @MainActor
    func testLegacyProfileDatabaseMigratesWithoutLosingConfirmedFields() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenType-LegacyProfile-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
            }
        }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fileURL.path, &database), SQLITE_OK)
        let legacySchema = """
        CREATE TABLE owner_profile (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            identity_and_work TEXT NOT NULL DEFAULT '',
            communication_style TEXT NOT NULL DEFAULT '',
            important_terms TEXT NOT NULL DEFAULT '',
            updated_at REAL
        );
        INSERT INTO owner_profile (
            id, identity_and_work, communication_style, important_terms, updated_at
        ) VALUES (
            1,
            'AI 产品经理\nOpenType 自动归纳的近期任务：写推文',
            '中文为主，简洁直接\nOpenType 自动归纳的表达偏好：口语化',
            'OpenType\nOpenType 自动归纳的术语：Mingle',
            100
        );
        """
        XCTAssertEqual(sqlite3_exec(database, legacySchema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        database = nil

        let migrated = AgentMemoryStore(fileURL: fileURL)

        XCTAssertTrue(migrated.databaseReady)
        XCTAssertEqual(migrated.ownerProfile.identityAndWork, "AI 产品经理")
        XCTAssertEqual(migrated.ownerProfile.communicationStyle, "中文为主，简洁直接")
        XCTAssertEqual(migrated.ownerProfile.importantTerms, "OpenType")
        XCTAssertEqual(migrated.ownerProfile.preferredLanguage, .chinese)

        let reloaded = AgentMemoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.ownerProfile.identityAndWork, "AI 产品经理")
        XCTAssertEqual(reloaded.ownerProfile.communicationStyle, "中文为主，简洁直接")
        XCTAssertEqual(reloaded.ownerProfile.importantTerms, "OpenType")
        XCTAssertEqual(reloaded.ownerProfile.preferredLanguage, .chinese)
    }

    func testMemoryInsightsLearnOnlyRepeatedSignals() {
        let events = [
            MemoryEvent(
                mode: .agent,
                applicationName: "OpenType",
                bundleIdentifier: nil,
                rawTranscript: "帮我写一个 OpenType 产品方案，要简洁直接",
                effectiveInput: "帮我写一个 OpenType 产品方案，要简洁直接",
                selectedContext: nil,
                result: "result 1"
            ),
            MemoryEvent(
                mode: .agent,
                applicationName: "OpenType",
                bundleIdentifier: nil,
                rawTranscript: "再写一个 OpenType Agent 的产品说明，语气简洁直接",
                effectiveInput: "再写一个 OpenType Agent 的产品说明，语气简洁直接",
                selectedContext: nil,
                result: "result 2"
            ),
            MemoryEvent(
                mode: .ask,
                applicationName: "Notes",
                bundleIdentifier: nil,
                rawTranscript: "我觉得 OpenType 这个 AI 输入工具还可以继续优化",
                effectiveInput: "我觉得 OpenType 这个 AI 输入工具还可以继续优化",
                selectedContext: nil,
                result: "result 3"
            )
        ]

        let insights = MemoryInsightsAnalyzer.analyze(events)
        XCTAssertTrue(insights.commonTerms.contains("OpenType"))
        XCTAssertTrue(insights.taskDomains.contains("产品与 AI 工具"))
        XCTAssertTrue(insights.stylePreferences.contains("简洁、直接"))
        XCTAssertFalse(insights.commonTerms.contains("方案"))
    }

    @MainActor
    func testLiveCaptionSettingPersists() {
        let suiteName = "OpenTypeTests.LiveCaptions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertTrue(configuration.liveCaptionsEnabled)
        configuration.liveCaptionsEnabled = false

        let reloaded = AppConfiguration(defaults: defaults)
        XCTAssertFalse(reloaded.liveCaptionsEnabled)
    }

    @MainActor
    func testTranscriptionLanguageSettingPersists() {
        let suiteName = "OpenTypeTests.TranscriptionLanguage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertEqual(configuration.transcriptionLanguage, .automatic)
        configuration.transcriptionLanguage = .japanese

        let reloaded = AppConfiguration(defaults: defaults)
        XCTAssertEqual(reloaded.transcriptionLanguage, .japanese)
    }

    func testMainstreamTranscriptionLanguagesCoverAppleLiveCaptionLocales() {
        // MLX-Whisper (the sidecar's ASR) auto-detects language on its own,
        // so `TranscriptionLanguage` only still drives the Apple on-device
        // live-caption preview's locale -- see `appleLocaleIdentifier`.
        XCTAssertGreaterThanOrEqual(TranscriptionLanguage.allCases.count, 25)
        XCTAssertEqual(TranscriptionLanguage.automatic.appleLocaleIdentifier, "zh-CN")
        XCTAssertEqual(TranscriptionLanguage.japanese.appleLocaleIdentifier, "ja-JP")
        XCTAssertEqual(TranscriptionLanguage.english.appleLocaleIdentifier, "en-US")
        XCTAssertEqual(TranscriptionLanguage.cantonese.appleLocaleIdentifier, "yue-Hant-HK")
    }

    func testImmutableAuditStoreAppendsWithoutRewritingEarlierEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenType-Audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let requestID = UUID()
        let timestamp = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        let first = ImmutableAuditEvent(
            requestId: requestID,
            createdAt: timestamp,
            status: .recognized,
            mode: .ask,
            rawTranscript: "为啥微信不行",
            effectiveInput: "为啥微信不行",
            selectedContext: nil,
            result: nil,
            provider: "dashScope",
            model: "qwen3-asr-flash",
            error: nil
        )
        let second = ImmutableAuditEvent(
            requestId: requestID,
            createdAt: timestamp,
            status: .completed,
            mode: .ask,
            rawTranscript: "为啥微信不行",
            effectiveInput: "为啥微信不行",
            selectedContext: nil,
            result: "为啥微信不行？",
            provider: nil,
            model: nil,
            error: nil
        )

        let store = ImmutableAuditStore(directoryURL: directory)
        try store.append(first)
        let firstBytes = try Data(contentsOf: store.fileURL)
        try store.append(second)
        let completeBytes = try Data(contentsOf: store.fileURL)

        XCTAssertTrue(completeBytes.starts(with: firstBytes))
        XCTAssertEqual(store.recent(limit: 10), [first, second])
        XCTAssertEqual(store.recent(limit: 1), [second])

        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.fileURL.path
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testImmutableAuditEventMatchesSharedSchemaFieldNamesAndModeIDs() throws {
        // Every remaining mode is a sidecar-backed mode whose audit "mode"
        // string is simply its InputMode raw value (no separate ID table).
        let allowedKeys: Set<String> = [
            "schemaVersion", "eventId", "requestId", "createdAt", "platform",
            "status", "mode", "rawTranscript", "effectiveInput",
            "selectedContext", "result", "provider", "model", "error",
            "supersedesEventId"
        ]

        for mode in InputMode.visibleModes {
            let event = ImmutableAuditEvent(
                requestId: UUID(),
                status: .completed,
                mode: mode,
                rawTranscript: "原始输入",
                effectiveInput: "有效输入",
                selectedContext: nil,
                result: "结果",
                provider: "dashScope",
                model: "qwen-plus",
                error: nil
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoder.encode(event))
                    as? [String: Any]
            )

            XCTAssertNotNil(object["eventId"])
            XCTAssertNil(object["id"])
            XCTAssertEqual(object["mode"] as? String, mode.rawValue)
            XCTAssertEqual(object["platform"] as? String, "macOS")
            XCTAssertEqual(object["schemaVersion"] as? Int, 1)
            XCTAssertTrue(Set(object.keys).isSubset(of: allowedKeys))
            XCTAssertNil(object["applicationName"])
            XCTAssertNil(object["applicationId"])
        }
    }

    func testImmutableAuditEventStillReadsLegacyMacRecords() throws {
        let eventID = UUID()
        let requestID = UUID()
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "id": "\(eventID.uuidString)",
          "requestId": "\(requestID.uuidString)",
          "createdAt": "2026-08-01T00:00:00Z",
          "platform": "macOS",
          "status": "completed",
          "mode": "raw",
          "rawTranscript": "旧记录",
          "applicationName": "Notes",
          "applicationId": "com.apple.Notes"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(
            ImmutableAuditEvent.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(event.id, eventID)
        XCTAssertEqual(event.requestId, requestID)
        XCTAssertEqual(event.mode, "raw")
        XCTAssertEqual(event.rawTranscript, "旧记录")
        XCTAssertNil(event.supersedesEventId)
    }

    // MARK: - SidecarClient

    func testSidecarClientLoadsBundledEnvironmentFileWhenPresent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ot-env-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let envFile = tempDir.appendingPathComponent("sidecar.env")
        try "DEEPSEEK_API_KEY=sk-test-from-bundle\nDEEPSEEK_MODEL=deepseek-v4-flash\n"
            .write(to: envFile, atomically: true, encoding: .utf8)

        let values = SidecarClient.loadBundledEnvironment(resourcePath: tempDir.path)
        XCTAssertEqual(values["DEEPSEEK_API_KEY"], "sk-test-from-bundle")
        XCTAssertEqual(values["DEEPSEEK_MODEL"], "deepseek-v4-flash")
    }

    func testSidecarClientLoadsEmptyEnvironmentWhenBundledFileMissing() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ot-env-missing-\(UUID().uuidString.prefix(8))")
        // Deliberately not created - exercises the "no bundled env file" path.
        let values = SidecarClient.loadBundledEnvironment(resourcePath: tempDir.path)
        XCTAssertTrue(values.isEmpty)
    }

    func testSidecarClientDecodesCannedHealthResponse() throws {
        struct HealthResponse: Decodable, Equatable {
            let status: String
        }

        let response: HealthResponse = try SidecarClient.decodeResponse(
            fromRawOutput: #"{"status":"ok"}"#
        )

        XCTAssertEqual(response, HealthResponse(status: "ok"))
    }

    func testSidecarClientThrowsOnEmptyOutput() {
        struct HealthResponse: Decodable {
            let status: String
        }

        XCTAssertThrowsError(
            try SidecarClient.decodeResponse(fromRawOutput: "") as HealthResponse
        ) { error in
            guard case SidecarClientError.emptyResponse = error else {
                return XCTFail("Expected emptyResponse, got \(error)")
            }
        }
    }

    func testSidecarClientThrowsOnMalformedOutput() {
        struct HealthResponse: Decodable {
            let status: String
        }

        XCTAssertThrowsError(
            try SidecarClient.decodeResponse(
                fromRawOutput: "not json at all"
            ) as HealthResponse
        ) { error in
            guard case SidecarClientError.responseDecodingFailed = error else {
                return XCTFail("Expected responseDecodingFailed, got \(error)")
            }
        }
    }

    func testSidecarClientDecodeFailureIncludesObservedHTTPStatus() {
        struct HealthResponse: Decodable {
            let status: String
        }

        XCTAssertThrowsError(
            try SidecarClient.decodeResponse(
                fromRawOutput: "<html>Internal Server Error</html>",
                status: 500
            ) as HealthResponse
        ) { error in
            guard case SidecarClientError.responseDecodingFailed(let status, _, let body) = error else {
                return XCTFail("Expected responseDecodingFailed, got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, "<html>Internal Server Error</html>")
        }
    }

    func testSidecarClientSplitsCurlBodyFromTrailingStatusLine() {
        let (body, status) = SidecarClient.splitBodyAndStatus(
            fromRawOutput: "{\"result\":\"hi\"}\n200"
        )
        XCTAssertEqual(body, "{\"result\":\"hi\"}")
        XCTAssertEqual(status, 200)
    }

    func testSidecarClientSplitsCurlBodyFromTrailingStatusLineOnErrorResponse() {
        let (body, status) = SidecarClient.splitBodyAndStatus(
            fromRawOutput: "{\"error\":\"missing_instruction\"}\n422"
        )
        XCTAssertEqual(body, "{\"error\":\"missing_instruction\"}")
        XCTAssertEqual(status, 422)
    }

    func testSidecarClientSplitBodyAndStatusFallsBackWhenNoStatusLinePresent() {
        // Defensive fallback if curl's `-w` output format ever changes shape
        // underneath us: treat the whole thing as body rather than crash.
        let (body, status) = SidecarClient.splitBodyAndStatus(
            fromRawOutput: "{\"result\":\"hi\"}"
        )
        XCTAssertEqual(body, "{\"result\":\"hi\"}")
        XCTAssertNil(status)
    }

    func testSidecarClientStartsHealthChecksAndStopsRealDevServer() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/bun") else {
            throw XCTSkip("bun is not installed at /opt/homebrew/bin/bun on this machine")
        }

        // Unix domain socket paths are capped at 104 bytes on Darwin, so this
        // deliberately avoids FileManager's (long) per-process temporary
        // directory in favor of a short, fixed /tmp path.
        let socketURL = URL(
            fileURLWithPath: "/tmp/ot-\(UUID().uuidString.prefix(8)).sock"
        )
        let client = await SidecarClient(socketURL: socketURL)

        try await client.start()

        let isHealthy = try await client.healthCheck()
        XCTAssertTrue(isHealthy)

        await client.stop()

        do {
            let stillHealthy = try await client.healthCheck()
            XCTAssertFalse(stillHealthy, "sidecar process should no longer respond after stop()")
        } catch {
            // Also acceptable: the request itself fails once the process
            // and its socket are gone.
        }
    }

    // MARK: - Agent run history (Part B: non-blocking Agent dispatch)

    func testAgentRunHistoryInsertsNewestFirst() {
        let older = AgentRunRecord(task: "older", applicationName: "Notes", contextPreview: nil)
        let newer = AgentRunRecord(task: "newer", applicationName: "Notes", contextPreview: nil)

        let history = AgentRunHistory.inserting(
            newer,
            into: AgentRunHistory.inserting(older, into: [])
        )

        XCTAssertEqual(history.map(\.task), ["newer", "older"])
    }

    func testAgentRunHistoryCapsAtCapacityByEvictingOldest() {
        var history: [AgentRunRecord] = []
        for index in 0..<(AgentRunHistory.capacity + 5) {
            history = AgentRunHistory.inserting(
                AgentRunRecord(task: "task-\(index)", applicationName: "Notes", contextPreview: nil),
                into: history
            )
        }

        XCTAssertEqual(history.count, AgentRunHistory.capacity)
        // Most recent run (last inserted) stays at the front...
        XCTAssertEqual(history.first?.task, "task-\(AgentRunHistory.capacity + 4)")
        // ...and the oldest 5 runs were evicted rather than the newest.
        XCTAssertFalse(history.contains { $0.task == "task-0" })
        XCTAssertTrue(history.contains { $0.task == "task-5" })
    }

    func testAgentRunHistoryUpdatingMutatesOnlyTheMatchingRecordInPlace() {
        let target = AgentRunRecord(task: "target", applicationName: "Notes", contextPreview: nil)
        let other = AgentRunRecord(task: "other", applicationName: "Notes", contextPreview: nil)
        let history = AgentRunHistory.inserting(
            other,
            into: AgentRunHistory.inserting(target, into: [])
        )

        let updated = AgentRunHistory.updating(id: target.id, in: history) { record in
            record.status = .completed("done")
            record.steps = [AgentStepSummary(type: "done", detail: "finished")]
        }

        XCTAssertEqual(updated.first(where: { $0.id == target.id })?.status, .completed("done"))
        XCTAssertEqual(updated.first(where: { $0.id == other.id })?.status, .running)
        // Order is preserved, not re-sorted by the update.
        XCTAssertEqual(updated.map(\.id), history.map(\.id))
    }

    func testAgentRunHistoryUpdatingIsANoOpForAnUnknownID() {
        let record = AgentRunRecord(task: "task", applicationName: "Notes", contextPreview: nil)
        let history = AgentRunHistory.inserting(record, into: [])

        let updated = AgentRunHistory.updating(id: UUID(), in: history) { record in
            record.status = .failed("should not apply")
        }

        XCTAssertEqual(updated, history)
    }

    func testAgentRunHistoryRunningCountOnlyCountsInFlightRuns() {
        let running = AgentRunRecord(task: "running", applicationName: "Notes", contextPreview: nil)
        var completed = AgentRunRecord(task: "completed", applicationName: "Notes", contextPreview: nil)
        completed.status = .completed("ok")
        var failed = AgentRunRecord(task: "failed", applicationName: "Notes", contextPreview: nil)
        failed.status = .failed("nope")

        XCTAssertEqual(
            AgentRunHistory.runningCount(in: [running, completed, failed]),
            1
        )
        XCTAssertEqual(AgentRunHistory.runningCount(in: [completed, failed]), 0)
    }

}
