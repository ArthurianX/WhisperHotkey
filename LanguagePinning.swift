import Foundation

/// Decides whether whisper's global language auto-detect (across its full
/// ~100-language vocabulary) should be overridden by a smaller pinned set.
/// See docs/superpowers/specs/2026-07-29-language-pinning-design.md.
///
/// `probabilities` and `pinned` both use whisper's short language codes
/// (e.g. "ro", "en") — never full names ("romanian", "english").
///
/// Returns nil when no retry is warranted: pinning disabled
/// (`pinned.count < 2`), an empty probabilities set, or the model's own
/// global top choice already matches the pinned winner. Otherwise returns
/// the language code to force-retry with. Ties within `pinned` resolve to
/// whichever entry appears first in `pinned`.
/// Which language to hand whisper, given the pinned set and whether the user
/// prefers speed over auto-detection.
///
/// `.autoDetectWithPinning` costs two passes when the model's own global guess
/// disagrees with the pinned winner — accurate but slow. `.forced` skips
/// detection entirely: one pass, correct whenever the primary language is the
/// one actually spoken.
enum LanguagePlan: Equatable {
    case autoDetect
    case autoDetectWithPinning(pinned: [String])
    case forced(primary: String)
}

func languagePlan(pinned: [String], forcePrimary: Bool) -> LanguagePlan {
    if forcePrimary, let primary = pinned.first { return .forced(primary: primary) }
    guard pinned.count >= 2 else { return .autoDetect }
    return .autoDetectWithPinning(pinned: pinned)
}

/// The `-l` argument for the whisper-cli fallback, mirroring `languagePlan`.
/// whisper-cli cannot see per-language probabilities, so pinning has no effect
/// there beyond forcing the primary language.
func CLILanguageSetting(pinned: [String], forcePrimary: Bool) -> String {
    if case .forced(let primary) = languagePlan(pinned: pinned, forcePrimary: forcePrimary) { return primary }
    return "auto"
}

func pickPinnedLanguage(probabilities: [String: Double], pinned: [String]) -> String? {
    guard pinned.count >= 2 else { return nil }
    guard let globalWinner = probabilities.max(by: { $0.value < $1.value })?.key else { return nil }

    var pinnedWinner = pinned[0]
    var bestScore = probabilities[pinned[0]] ?? 0
    for lang in pinned.dropFirst() {
        let score = probabilities[lang] ?? 0
        if score > bestScore {
            bestScore = score
            pinnedWinner = lang
        }
    }

    return globalWinner == pinnedWinner ? nil : pinnedWinner
}
