import Foundation

/// What actually gets pasted: whisper's output with blank lines and the
/// leading/trailing whitespace of each line removed, kept as multiple lines.
/// Pure, so the shape of the pasted text is covered by a test rather than by
/// reading one dictation's output.
func cleanTranscript(_ raw: String) -> String {
    raw.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}
