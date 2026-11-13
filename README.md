# WhisperHotkey

Hold **⌃⌥⌘R**, talk, release. Your words land in the field you were talking
into, and a countdown then presses the app's submit key for you — Enter
everywhere, ⌘↩ in Slack, whatever `config.json` says.

Nothing leaves the machine: transcription runs locally through
[whisper.cpp](https://github.com/ggml-org/whisper.cpp).

## How a dictation flows

```
press hotkey ─► record (waveform overlay) ─► release
              └► warm the model if it has been idle
              └► transcribe: resident whisper-server, whisper-cli as fallback
              └► transcript → clipboard, then ⌘V into the focused app
              └► countdown overlay (Esc / click / typing cancels)
              └► submit chord for the frontmost app
```

The countdown length follows the transcript's word count, so a one-word
correction submits quickly and a paragraph gives you time to read it.

## Install

```sh
./setup.sh      # whisper.cpp + model + settings + signing identity + LaunchAgent
./build.sh      # runs the tests, builds WhisperHotkey.app, signs it, restarts it
```

`setup.sh` is idempotent and non-interactive; it prints what it did and what
still needs a human. `--skip-whisper`, `--skip-model`, `--skip-agent` and
`--cert` pick individual steps.

### The two permission grants

macOS will not let a script grant these, so do it once in System Settings →
Privacy & Security:

- **Microphone** — without it nothing records.
- **Accessibility** — without it the transcript goes to the clipboard only, and
  there is no auto-paste or auto-submit. The app tells you in the log which one
  is missing rather than pretending it worked.

### Signing

`build.sh` signs with a self-signed identity, `WhisperHotkey Local Signing`.
TCC grants (Accessibility, microphone) are keyed to the code-signing identity,
so a stable identity keeps them across rebuilds; ad-hoc signing resets them
every build. `setup.sh` creates the identity if it is missing; override with
`WHISPER_HOTKEY_SIGNING_IDENTITY`.

## Settings

Settings live in `~/.config/whisper-hotkey/config.json` (first run writes
defaults; `config.json.example` in the repo is the same shape with examples).
Override the path with `WHISPER_HOTKEY_CONFIG`, and the checkout's `config.json`
still works as the developer path. Edit it, then choose **Reload config** in the
menu-bar item — no restart needed.

| Key | Meaning |
| --- | --- |
| `countdown.shortWordMax/mediumWordMax` | Word counts where the short/medium timers apply |
| `countdown.shortSeconds/mediumSeconds/longSeconds` | Countdown length by transcript size |
| `messages.titleFormat` | Countdown text; `{seconds}` and `{key}` are substituted |
| `messages.cancelHint` | The line under the progress bar |
| `glass.style/cornerRadius/width/height/tintColorHex/fillColorHex` | Overlay appearance (`style` is `regular` or `clear`; on macOS before 26 it falls back to a dark rounded panel) |
| `whisper.root` | Where whisper.cpp lives (`~/whisper.cpp` by default) |
| `whisper.model` | Model file name under `<root>/models` |
| `server.enabled` | Use the resident `whisper-server`; off means one `whisper-cli` process per dictation |
| `server.port` | Local port for the server |
| `server.warmUpAfterSeconds` | Idle seconds after which recording fires a warm-up inference; `0` disables it |
| `submitKeys` | Bundle id → chord (`enter`, `cmd+enter`, `shift+enter`…); `default` covers everything else |
| `pinnedLanguages` | Two or more language codes (`["ro", "en"]`) to override whisper's global auto-detect |
| `forcePrimaryLanguage` | Skip detection and force `pinnedLanguages[0]`: one pass instead of two |
| `text.maxSegmentChars` | How long a whisper segment may get before it is cut. `-1` = no cap (whisper-server's own default is a 60-character wrap that can cut mid-word) |
| `text.joinSegments` | Merge whisper's segment lines into one line before pasting. On by default: in chat fields a newline is the send key |
| `hotkey.key/modifiers` | The hold-to-dictate binding, e.g. `{"key": "h", "modifiers": ["cmd", "shift"]}` |
| `paste.requireUnchangedFocus` | Don't type into an app you switched to mid-dictation (text stays on the clipboard) |
| `debug.overlayDiagnostics` | Verbose overlay-visibility logging |

Malformed values are reported in the log and fall back to defaults — a typo
never silently turns settings off.

## The menu-bar item

`waveform` icon in the menu bar: current state (Ready / Recording… /
Transcribing… / Auto-submitting…), **Pause hotkey**, **Reload config**, **Open
settings**, **Open log folder**, **Quit**.

## Where things live

| Path | What |
| --- | --- |
| `~/Library/Caches/whisper-hotkey/whisper-hotkey.log` | Everything the app did, incl. timings |
| `~/Library/Caches/whisper-hotkey/whisper-server.log` | The resident server's own output |
| `~/Library/Caches/whisper-hotkey/recording.wav` | The dictation audio — deleted as soon as the transcript is in hand |
| `~/.config/whisper-hotkey/config.json` | Settings |
| `~/Library/LaunchAgents/com.arthur.whisper-hotkey.plist` | Start at login (written by `setup.sh`) |

## Warm-up, in one paragraph

ggml's Metal backend keeps the model's ~1.6 GB of buffers wired only ~180s after
the last compute; past that the OS can swap them out and the next request stalls
while they fault back in. So when recording starts and the model has been idle
past `server.warmUpAfterSeconds`, a throwaway silent inference runs in parallel
with the recording — the real request finds the weights resident. `WarmUp.swift`
has the details and the log line pairs each warm-up with the dictation it was
meant to speed up.

## Language pinning

`pinnedLanguages: ["ro", "en"]` asks whisper for `verbose_json`, compares its
per-language probabilities with the pinned set, and if the model's global guess
came from outside that set, retries once forced to the best pinned language.
That retry is a second full pass; `forcePrimaryLanguage` trades detection for a
single forced pass when one language dominates. See
`docs/superpowers/specs/2026-07-29-language-pinning-design.md`.

## Tests

```sh
./test.sh
```

Compiles and runs the pure parts — config parsing and warnings, chords, hotkey
bindings, language planning, warm-up timing, transcript cleanup, the paste
decision, the transcription pipeline's fallback, WAV writing, clipboard
restore. `build.sh` runs it before shipping. GitHub Actions runs it on every push
(`.github/workflows/test.yml`).

## Layout

| File | Responsibility |
| --- | --- |
| `main.swift` | Entry point, one line |
| `AppBootstrap.swift` | App wiring: permissions, hotkey registration, status item, SIGTERM |
| `WhisperController.swift` | The dictation flow |
| `Config.swift` / `RuntimePaths.swift` | Settings and paths |
| `Transcriber.swift` / `WhisperServer.swift` | Server + CLI transcription and fallback |
| `TextInjector.swift` / `Clipboard.swift` / `FocusGuard.swift` | Keystrokes, pasteboard, focus decision |
| `Notifier.swift` / `Logger.swift` | Notifications, log |
| `CountdownOverlay.swift` / `RecordingOverlay.swift` / `OverlayPanel.swift` / `OverlayDebug.swift` | Overlays |
| `StatusMenu.swift` | Menu-bar item |
| `SubmitChord.swift` / `HotKey.swift` / `LanguagePinning.swift` / `WarmUp.swift` / `TranscriptText.swift` | Pure, tested logic |
| `tests/` | Unit tests (`main.swift` is the runner) |

Design docs and plans: `docs/superpowers/specs/` and `docs/superpowers/plans/`.

## Troubleshooting

- **Nothing happens when I press the hotkey** — check the log: a failed
  registration says so (`Could not register hotkey ⌃⌥⌘R; OSStatus …`), which
  usually means another app owns that chord. Also check the menu-bar item isn't
  paused.
- **The transcript never appears in the field** — Accessibility is not granted;
  the text is on the clipboard and the log says why.
- **"Focus changed during transcription"** — you switched apps mid-dictation, so
  the app refused to type into the new frontmost window; use the clipboard, or
  set `paste.requireUnchangedFocus: false`.
- **Line breaks or half-words in the pasted text** — this is whisper-server's
  segmentation, not the model improvising: `server.cpp` maps `max_len 0` to a
  hard 60-character wrap with `split_on_word false`, and emits one line per
  segment, so a long sentence gets a newline every ~60 characters and can be cut
  inside a word (`it` / `'s`). The app now sends `max_len=-1` and
  `split_on_word=true` on every request, and joins the segments into one line
  before pasting (`text.joinSegments`). Pauses still produce real segment
  boundaries, which become spaces once joining is on; set
  `text.joinSegments: false` when you dictate multi-line text.
- **Wrong language** — set `pinnedLanguages`, and `forcePrimaryLanguage` if one
  language dominates.
- **The overlay doesn't appear** — set `debug.overlayDiagnostics: true`,
  reproduce, and read the `[overlay]` lines in the log. There is an open
  long-uptime bug here: `orderFrontRegardless()` sometimes leaves panels
  invisible while everything else keeps working. `OverlayDebug.swift` records
  exactly the fields needed to split the remaining causes.

## Known limitations

- The auto-submit chord is resolved against whatever is frontmost when the
  countdown fires — that is deliberate (spec §5 Q2), but it means switching apps
  during the countdown moves the submit elsewhere.
- `whisper-cli` cannot see per-language probabilities, so `pinnedLanguages`
  only takes effect on the server path (beyond forcing the primary language).
- Overlays are placed on the main screen; multi-screen setups follow the main
  display.
