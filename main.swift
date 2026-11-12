import AppKit

// Entry point only. Everything else lives in its own file: the dictation flow in
// `WhisperController`, the wiring in `AppBootstrap`, the overlays, the config.
// (Swift allows top-level code in exactly one file, which is this one.)
AppBootstrap().run()
