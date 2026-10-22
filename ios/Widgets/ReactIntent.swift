import AppIntents
import WidgetKit

/// A tap on the medium widget's character: the next reaction pose and line. WidgetKit reloads the timeline after it.
struct ReactIntent: AppIntent {
    static let title: LocalizedStringResource = "캐릭터 쓰다듬기"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        SharedState.react()
        return .result()
    }
}
