import Foundation

/// Whether the transcript should be typed into the focused field.
///
/// The user dictated into one app and may have switched during the
/// transcription. Typing a paragraph into whatever is frontmost by then writes
/// text into the wrong window, which is worse than not pasting at all — so when
/// focus moved, the caller leaves the text on the clipboard and says so.
func shouldAutoPaste(startBundleID: String?, currentBundleID: String?) -> Bool {
    if startBundleID == nil { return true }  // focus unknown when recording started: paste
    return startBundleID == currentBundleID
}
