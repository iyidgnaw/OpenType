import Foundation

struct RoutedTranscript: Equatable {
    let mode: InputMode
    let text: String
}

enum VoiceModeRouter {
    /// The 3-mode cut removed the routes for the retired
    /// polish/translate/xReply modes; only the spoken trigger for switching
    /// into Agent mode mid-recording remains.
    private static let routes: [(mode: InputMode, prefixes: [String])] = [
        (
            .agent,
            ["agent模式", "agent 模式", "agent mode", "命令输入", "创作模式", "command input"]
        )
    ]

    static func route(
        _ transcript: String,
        currentMode: InputMode
    ) -> RoutedTranscript {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        for route in routes {
            for prefix in route.prefixes {
                guard lowered.hasPrefix(prefix) else { continue }
                let boundaryIndex = lowered.index(lowered.startIndex, offsetBy: prefix.count)
                guard boundaryIndex < lowered.endIndex else { continue }

                let boundary = lowered[boundaryIndex]
                guard boundary.isVoiceCommandBoundary else { continue }

                let remainder = trimmed[boundaryIndex...]
                    .trimmingCharacters(
                        in: CharacterSet.whitespacesAndNewlines
                            .union(.punctuationCharacters)
                    )
                guard !remainder.isEmpty else { continue }
                return RoutedTranscript(mode: route.mode, text: remainder)
            }
        }

        return RoutedTranscript(mode: currentMode, text: trimmed)
    }
}

private extension Character {
    var isVoiceCommandBoundary: Bool {
        unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.punctuationCharacters.contains($0)
        }
    }
}
