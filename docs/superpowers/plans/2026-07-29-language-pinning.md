# Romanian/English Language Pinning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop whisper's language auto-detect from occasionally decoding short Romanian utterances as Russian/French/Spanish, by restricting the effective language choice to a configured set (Romanian + English) and retrying with the forced winner only when the model's own global choice disagrees.

**Architecture:** `WhisperServer.transcribe(wav:)` gains a `pinnedLanguages` parameter. It requests `response_format=verbose_json` only when pinning is enabled (2+ pinned languages configured), reads back `language_probabilities`, and compares the global argmax against the argmax restricted to the pinned set via a new pure function `pickPinnedLanguage`. On disagreement it issues exactly one more request forced to the pinned winner. When pinning is disabled the request is byte-for-byte identical to today (`response_format=text`, no JSON parsing) — zero behavior change.

**Tech Stack:** Swift, Foundation (`URLSession`, `JSONSerialization`), whisper-server's `/inference` endpoint.

**Spec:** `docs/superpowers/specs/2026-07-29-language-pinning-design.md`

## Global Constraints

- Server path only — `whisper-cli` fallback (`WhisperController.runWhisperCLI()`) is untouched.
- `language` and `detected_language` fields in the server's JSON response are **full language names** (`whisper_lang_str_full`, e.g. `"english"`) — never compare them to short codes. `language_probabilities` keys are **short codes** (`whisper_lang_str`, e.g. `"en"`, `"ro"`). This plan derives the global winner from `language_probabilities` itself, never from the `language`/`detected_language` fields, specifically to avoid this format mismatch.
- Pinning is opt-in: `pinnedLanguages.count < 2` must produce behavior byte-identical to today (plain `response_format=text`, `language=auto`, no retry logic engaged).
- No confidence floor — the higher-scoring pinned language always wins the tie/comparison, per spec's accepted-limitation note.
- Retry-request failure must fall back to the **first** response's text, never to `nil` (spec: "a wrong-but-present transcript beats none").
- Unit tests: `swiftc SubmitChord.swift Config.swift LanguagePinning.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests` (from repo root; note `LanguagePinning.swift` joins the existing compile list). Manual app verification: `./build.sh` then dictate via the hotkey.
- Config key: `"pinnedLanguages": ["ro", "en"]` (array of short codes) at the top level of `config.json`, alongside `countdown`/`messages`/`glass`/`server`/`submitKeys`.

---

### Task 1: `pickPinnedLanguage` pure function (TDD)

**Files:**
- Create: `LanguagePinning.swift`
- Modify: `tests/main.swift` (append tests)

**Interfaces:**
- Produces: `func pickPinnedLanguage(probabilities: [String: Double], pinned: [String]) -> String?`. Task 3's `WhisperServer.transcribe(wav:pinnedLanguages:)` consumes this.

- [ ] **Step 1: Append failing tests to tests/main.swift**

Insert before the final `if failures > 0` block:

```swift
// --- pickPinnedLanguage ---
expect(pickPinnedLanguage(probabilities: ["ro": 0.9, "en": 0.05, "ru": 0.9], pinned: []) == nil, "empty pinned list disables pinning")
expect(pickPinnedLanguage(probabilities: ["ro": 0.9, "en": 0.05], pinned: ["ro"]) == nil, "single-entry pinned list disables pinning")
expect(pickPinnedLanguage(probabilities: ["ro": 0.9, "en": 0.05], pinned: ["ro", "en"]) == nil, "global winner already matches pinned winner")
expect(pickPinnedLanguage(probabilities: ["ru": 0.6, "ro": 0.3, "en": 0.1], pinned: ["ro", "en"]) == "ro", "global winner is a third language; retries to higher-scoring pinned language")
expect(pickPinnedLanguage(probabilities: ["fr": 0.5, "en": 0.4, "ro": 0.1], pinned: ["ro", "en"]) == "en", "global winner is a third language; retries to en when en scores higher than ro")
expect(pickPinnedLanguage(probabilities: ["ru": 0.6, "ro": 0.3], pinned: ["ro", "en"]) == "ro", "missing pinned entry (en absent) treated as 0")
expect(pickPinnedLanguage(probabilities: ["ru": 1.0], pinned: ["ro", "en"]) == "ro", "both pinned entries missing; ro wins tie as first in pinned order")
expect(pickPinnedLanguage(probabilities: [:], pinned: ["ro", "en"]) == nil, "empty probabilities dict; nothing to compare, no retry")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swiftc SubmitChord.swift Config.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests`
Expected: FAIL — swiftc error, `cannot find 'pickPinnedLanguage' in scope`.

- [ ] **Step 3: Implement LanguagePinning.swift**

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swiftc SubmitChord.swift Config.swift LanguagePinning.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests`
Expected: `ALL TESTS PASSED` (all prior SubmitChord/OverlayConfig tests plus the 8 new ones above).

- [ ] **Step 5: Verify the app still builds**

Run: `./build.sh`
Expected: success (`LanguagePinning.swift` joins the app compile via `build.sh`'s `"$DIR"/*.swift` glob; nothing references it yet).

- [ ] **Step 6: Commit**

```bash
git add LanguagePinning.swift tests/main.swift && git commit -m "feat: pickPinnedLanguage pure function for language-pinning decision"
```

---

### Task 2: `pinnedLanguages` config field (TDD)

**Files:**
- Modify: `Config.swift`
- Modify: `tests/main.swift` (append tests)
- Modify: `config.json` (live, gitignored — not committed)

**Interfaces:**
- Produces: `OverlayConfig.pinnedLanguages: [String]` (default `[]`), parsed by `OverlayConfig.load(from:)`. Task 3's `WhisperController.runTranscription()` consumes this.

- [ ] **Step 1: Append failing tests to tests/main.swift**

Insert before the final `if failures > 0` block (after the existing `OverlayConfig` tests):

```swift
// --- OverlayConfig.pinnedLanguages ---
let tmpPinnedConfig = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-test-pinned-config.json")
try! """
{ "pinnedLanguages": ["ro", "en"] }
""".write(to: tmpPinnedConfig, atomically: true, encoding: .utf8)

let pinnedCfg = OverlayConfig.load(from: tmpPinnedConfig)
expect(pinnedCfg.pinnedLanguages == ["ro", "en"], "pinnedLanguages parsed from config")
expect(defaults.pinnedLanguages == [], "default pinnedLanguages is empty (pinning disabled)")
```

(`defaults` here reuses the existing `OverlayConfig.load(from: URL(fileURLWithPath: "/nonexistent.json"))` binding already defined earlier in this file by Task 3 of the prior plan — do not redeclare it.)

- [ ] **Step 2: Run tests to verify the new one fails**

Run: `swiftc SubmitChord.swift Config.swift LanguagePinning.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests`
Expected: FAIL — swiftc error, `OverlayConfig` has no member `pinnedLanguages`.

- [ ] **Step 3: Implement in Config.swift**

Add the new stored property next to `submitKeys`:

```swift
    // bundle-id → chord string; "default" applies to unmapped apps
    var submitKeys: [String: String] = ["default": "enter"]
    // language codes (e.g. "ro", "en") to restrict auto-detect to; empty/single-entry = disabled
    var pinnedLanguages: [String] = []
```

In `load(from:)`, add after the `submitKeys` block:

```swift
        if let langs = json["pinnedLanguages"] as? [String] {
            config.pinnedLanguages = langs
        }
```

In `writeDefaultIfMissing()`, add to the JSON template (after the `"submitKeys"` line, comma-separated):

```json
  "submitKeys": { "default": "enter" },
  "pinnedLanguages": []
```

(Template defaults to disabled — pinning is opt-in per fresh install; this user's own already-existing `config.json` is configured separately in Step 5 below.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swiftc SubmitChord.swift Config.swift LanguagePinning.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests`
Expected: `ALL TESTS PASSED`

- [ ] **Step 5: Enable pinning in the live config.json**

`config.json` is gitignored (the user's untracked live config) — edit it directly on disk, do not commit. Add a top-level key:

```json
  "pinnedLanguages": ["ro", "en"]
```

- [ ] **Step 6: Verify the app still builds**

Run: `./build.sh`
Expected: success.

- [ ] **Step 7: Commit**

```bash
git add Config.swift tests/main.swift && git commit -m "feat: pinnedLanguages config field"
```

---

### Task 3: Wire language pinning into WhisperServer, verify end-to-end

**Files:**
- Modify: `WhisperServer.swift` (`transcribe(wav:)` restructured into `transcribe(wav:pinnedLanguages:)` + new `performInference` helper)
- Modify: `main.swift` — `WhisperController.runTranscription()` call site

**Interfaces:**
- Consumes: `pickPinnedLanguage(probabilities:pinned:)` (Task 1), `OverlayConfig.pinnedLanguages` (Task 2).
- Produces: `WhisperServer.transcribe(wav: URL, pinnedLanguages: [String] = []) -> String?` (replaces the old `transcribe(wav:)` — same return type, new optional parameter, default `[]` keeps any other future caller source-compatible).

- [ ] **Step 1: Replace transcribe(wav:) in WhisperServer.swift**

Replace the existing `func transcribe(wav: URL) -> String?` method (everything from its `func transcribe` line through its closing `}`) with:

```swift
    /// Synchronous call to /inference. Applies language pinning when
    /// `pinnedLanguages` has 2+ entries — see
    /// docs/superpowers/specs/2026-07-29-language-pinning-design.md.
    /// Returns nil on any failure (caller falls back to whisper-cli).
    func transcribe(wav: URL, pinnedLanguages: [String] = []) -> String? {
        let pinningEnabled = pinnedLanguages.count >= 2
        guard let first = performInference(wav: wav, language: "auto", verboseJSON: pinningEnabled) else {
            return nil
        }
        guard pinningEnabled,
              let probabilities = first.languageProbabilities,
              let pinnedWinner = pickPinnedLanguage(probabilities: probabilities, pinned: pinnedLanguages)
        else {
            return first.text
        }

        log("Language pinning: global auto-detect disagreed with pinned set \(pinnedLanguages); retrying forced to \(pinnedWinner).")
        guard let retry = performInference(wav: wav, language: pinnedWinner, verboseJSON: false) else {
            log("Language pinning retry failed; using original (possibly wrong-language) transcript.")
            return first.text
        }
        return retry.text
    }

    private struct InferenceResult {
        let text: String
        let languageProbabilities: [String: Double]?
    }

    /// One synchronous multipart POST to /inference. Call from a background queue.
    private func performInference(wav: URL, language: String, verboseJSON: Bool) -> InferenceResult? {
        guard let audio = try? Data(contentsOf: wav),
              let url = URL(string: "http://127.0.0.1:\(port)/inference") else { return nil }

        let boundary = "whisper-hotkey-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        appendField("response_format", verboseJSON ? "verbose_json" : "text")
        appendField("language", language)
        appendField("temperature", "0.0")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var result: InferenceResult?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { self.log("whisper-server request failed: \(error.localizedDescription)"); return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                self.log("whisper-server bad response: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            if verboseJSON {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String else {
                    self.log("whisper-server verbose_json response missing text field")
                    return
                }
                result = InferenceResult(text: text, languageProbabilities: json["language_probabilities"] as? [String: Double])
            } else {
                guard let text = String(data: data, encoding: .utf8) else {
                    self.log("whisper-server response not valid UTF-8")
                    return
                }
                result = InferenceResult(text: text, languageProbabilities: nil)
            }
        }.resume()
        semaphore.wait()
        return result
    }
```

- [ ] **Step 2: Update the call site in main.swift**

In `WhisperController.runTranscription()`, change:

```swift
            if let text = server.transcribe(wav: wavFile) {
```

to:

```swift
            if let text = server.transcribe(wav: wavFile, pinnedLanguages: config.pinnedLanguages) {
```

(`config` is already in scope — `runTranscription()` starts with `let config = OverlayConfig.load()`.)

- [ ] **Step 3: Build**

Run: `./build.sh`
Expected: success.

- [ ] **Step 4: Verify pinning is inert when disabled**

Temporarily confirm the zero-cost-when-disabled behavior: with `pinnedLanguages` still `["ro", "en"]` in `config.json` from Task 2 (so this really tests the *enabled* path — see Step 5 for the disabled-path check), dictate one clearly-English phrase and one clearly-Romanian phrase that you know detects correctly. Check the log:

Run: `tail -20 "$TMPDIR/whisper-hotkey/whisper-hotkey.log" | grep -i "language pinning\|transcribed in"`
Expected: `whisper-server transcribed in` lines present, **no** "Language pinning: ... retrying" lines (both dictations already agreed with the pinned set, so no retry fired) — and both transcripts are correct.

- [ ] **Step 5: Verify the disabled path is untouched**

Edit `config.json` to temporarily set `"pinnedLanguages": []`, run `./build.sh`, dictate one phrase, confirm it still transcribes correctly and the log shows no pinning-related lines at all (proves the `verboseJSON: pinningEnabled` branch correctly falls back to the original plain-text request). Then restore `"pinnedLanguages": ["ro", "en"]` in `config.json` and `./build.sh` again.

- [ ] **Step 6: Verify the retry path actually fires and fixes a misdetection**

Dictate a short Romanian phrase similar in length/content to one that previously misdetected as Russian/French/Spanish (per the earlier manual testing in the fast-transcription-waveform-overlay work). Repeat a few times if needed to catch a misfire, since the underlying LID flakiness is probabilistic.

Run: `tail -20 "$TMPDIR/whisper-hotkey/whisper-hotkey.log" | grep -i "language pinning"`
Expected on a misfire: a line like `Language pinning: global auto-detect disagreed with pinned set ["ro", "en"]; retrying forced to ro.` followed by the corrected Romanian transcript actually being pasted (not the wrong-language garbage).

- [ ] **Step 7: Run the full unit suite once more**

Run: `swiftc SubmitChord.swift Config.swift LanguagePinning.swift tests/main.swift -o /tmp/whisper-hotkey-tests && /tmp/whisper-hotkey-tests`
Expected: `ALL TESTS PASSED`

- [ ] **Step 8: Commit**

```bash
git add WhisperServer.swift main.swift && git commit -m "feat: apply Romanian/English language pinning in whisper-server path"
```
