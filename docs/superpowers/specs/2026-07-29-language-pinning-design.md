# WhisperHotkey — Romanian/English Language Pinning

**Date:** 2026-07-29
**Status:** Approved design, pending implementation plan

## Problem

Whisper's language auto-detect (`-l auto`) picks the single highest-probability
language across its full ~100-language vocabulary. On short dictated
utterances this occasionally misfires: a Romanian phrase gets decoded as
Russian, French, or Spanish instead, producing a nonsense transcript in the
wrong language. English detection has not shown this problem in testing.

Verified via direct comparison: the same recorded audio produces the same
(correct or incorrect) transcript whether run through `whisper-cli` or the
resident `whisper-server` — this is a whisper.cpp language-ID limitation on
short clips, not something introduced by the whisper-server work
(`docs/superpowers/specs/2026-07-29-fast-transcription-waveform-overlay-design.md`).
A prior attempt at constraining detection to two languages reportedly had
problems, but no specifics were recoverable; this design proceeds from
current, verified facts about whisper.cpp's actual API rather than that
memory.

## How whisper.cpp actually exposes this (verified against source)

whisper.cpp has no native "restrict auto-detect to N languages" flag — it is
either a single forced language or full open-vocabulary `auto`. However,
`whisper-server`'s `/inference` endpoint, when called with
`response_format=verbose_json`, returns:

- `text` — the transcript, decoded using whichever language `auto` picked
- `language` — that decoded-with language (the actual global argmax)
- `language_probabilities` — a `{lang_code: probability}` object covering
  every language with non-negligible probability (source:
  `examples/server/server.cpp`, `whisper_lang_auto_detect`)

Both `language` and `language_probabilities` are computed from the same
deterministic encoder pass, so they're always consistent with each other for
a given recording — **but their formats differ**: `language` and
`detected_language` are full names (`whisper_lang_str_full`, e.g.
`"english"`, `"romanian"`), while `language_probabilities` keys are short
codes (`whisper_lang_str`, e.g. `"en"`, `"ro"`). This design compares only
within `language_probabilities` (see below) specifically to avoid needing a
full-name-to-short-code mapping — a mismatch caught during spec self-review
that the original draft got wrong. This gives the app enough information to
override the model's global choice with our own choice restricted to a
smaller language set, without needing any changes to whisper.cpp itself.

## Design

### Config

New `OverlayConfig` field, following the existing `submitKeys` pattern —
config-driven, degrades gracefully when absent:

```json
"pinnedLanguages": ["ro", "en"]
```

`var pinnedLanguages: [String] = []`. Empty or single-entry lists disable
pinning entirely (nothing to choose between) — behavior is then identical to
today's plain `-l auto`, so the feature is strictly opt-in.

### WhisperServer.transcribe(wav:) — conditional retry

1. Request `response_format=verbose_json` (instead of today's `text`).
2. Parse `text` and `language_probabilities` from the JSON body. (`language`
   and `detected_language` are not used — see format note above; the global
   winner is derived from `language_probabilities` instead, so everything
   is compared in the same short-code format.)
3. If pinning is disabled (config check above), return `text` unchanged —
   no behavior change from the existing implementation.
4. Otherwise, within `language_probabilities`: let `globalWinner` be the
   key with the single highest probability across **all** entries (this is
   the same choice the model already made to decode `text`, just read back
   in short-code form instead of re-deriving it from the full-name field).
   Let `pinnedWinner` be the key with the highest probability among only
   the configured `pinnedLanguages` (missing/negligible entries count as
   `0`).
5. If `globalWinner == pinnedWinner`, the model's own top choice already
   agrees with the pinned decision — return `text` as-is. This is the
   common case and costs nothing extra.
6. If they differ, issue **one** more request with `language=<pinnedWinner>`
   forced (not `auto`) and `response_format=text` (no probabilities needed
   this time), and return that transcript instead.

This logic lives entirely inside `WhisperServer`; `WhisperController` is
unaware a retry ever happens — it just gets back a transcript, same as
today.

A pure decision function is factored out for testability:

```swift
func pickPinnedLanguage(probabilities: [String: Double], pinned: [String]) -> String?
```

Computes `globalWinner` (argmax over all entries) and `pinnedWinner` (argmax
over `pinned` entries only) internally. Returns `nil` when no retry is
warranted (`pinned.count < 2`, or `globalWinner == pinnedWinner`); otherwise
returns `pinnedWinner` — the language code to force-retry with.

### Scope

Server path only. The `whisper-cli` fallback keeps today's plain `-l auto`
behavior unchanged — it is an already-rare safety net, and plumbing JSON
parsing through the CLI's output format for a path this infrequently hit
isn't worth the complexity.

### Error handling

- Retry request itself fails (network error, server down mid-retry): fall
  back to the **first** response's `text` rather than losing the transcript
  — a wrong-but-present transcript beats none, and the existing
  `whisper-cli` fallback is still one layer further out if the server has
  gone down entirely.
- Malformed or missing JSON fields (e.g. `language_probabilities` absent
  from the response): treated as "no pinning data available" — return the
  original `text` unchanged, same as if pinning were disabled.
- No confidence floor is applied to the pinned-language comparison — if
  both Romanian and English score negligibly (a genuinely different
  language was spoken), the higher of the two still wins and is force-
  retried. This is accepted as a known limitation given the app's real
  usage pattern (this user dictates only Romanian and English).

## Non-goals

- No change to the `whisper-cli` fallback path.
- No confidence-floor/escape-hatch for genuinely-out-of-set languages.
- No attempt to fix language detection for languages other than the
  configured pinned set.
- If this design still lets misdetections through in practice, the
  documented escalation path is Approach C from the design discussion
  (force-decode with each pinned language and pick by the decoder's own
  `avg_logprob` confidence instead of the language-ID head) — not built
  now, noted for future reference only.

## Testing

- `pickPinnedLanguage(probabilities:pinned:)` is a pure function,
  unit-tested via the existing swiftc test binary
  (`tests/main.swift`) — no network required. Cases: pinning disabled
  (empty/single-entry list), global winner already matches pinned winner
  (no retry), global winner is a third language entirely (retry to
  whichever of ro/en scores higher), missing/negligible probability
  entries (treated as 0), tie between pinned languages (deterministic
  pick, e.g. first in `pinned` order).
- Manual verification: dictate several Romanian and English phrases against
  the live app; confirm the log shows a retry only on genuine mismatches
  (not on every dictation), and confirm a short Romanian phrase similar to
  the one that previously misdetected as Russian/French/Spanish now comes
  back correct.
