import Foundation

/// What actually gets pasted: whisper's output with blank lines and the
/// leading/trailing whitespace of each line removed. whisper emits one line per
/// segment, so `joinSegments` collapses them into a single flowing line — worth
/// doing for chat fields, where a newline is the send key. Pure, so the shape of
/// the pasted text is covered by a test rather than by reading a dictation.
func cleanTranscript(_ raw: String, joinSegments: Bool = false) -> String {
    let lines = raw.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return lines.joined(separator: joinSegments ? " " : "\n")
}
