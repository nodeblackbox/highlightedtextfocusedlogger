# Highlight Reader (Electron / TypeScript)

The Electron/TypeScript port of `HighlightLogger-v4/v5.ps1`. Same core trick
(highlight text anywhere, press a hotkey, hear it read aloud, press again to
stop), rebuilt so the app itself is a normal cross-platform-shaped desktop
app instead of an elevated PowerShell window, with Edge TTS instead of
System.Speech/Kokoro.

## What's ported from the PowerShell versions, and how

| v4/v5 (PowerShell + inline C#) | this app | why |
|---|---|---|
| `WH_KEYBOARD_LL` hook checking only ALT+R / CTRL+ALT+Q, swallows them from every other app | `globalShortcut.register("Alt+R", ...)` | Windows' `RegisterHotKey` (which `globalShortcut` uses) already intercepts the combo system-wide — the foreground app never sees it. No raw hook needed. |
| UI Automation waterfall: focused element → 5 ancestors → descendants → foreground-window subtree, with a per-window "which element had it" cache | `selection-helper/Program.cs`, same waterfall, same cache | UI Automation (`System.Windows.Automation`) has no equivalent in Node; kept as compiled .NET 9, talked to over stdin/stdout so the process stays warm and the cache persists between hotkey presses (`selectionClient.ts`) |
| `CleanForSpeech()` regex pipeline (markdown/HTML/URLs/bullets/orphan punctuation) | `cleanForSpeech.ts` | direct line-for-line port |
| System.Speech / Kokoro HTTP + `winmm.dll PlaySound` for instant-stop playback | `edge-tts` (Python CLI) → mp3 → Electron `<audio>` in the renderer | Chromium's own audio pipeline gives instant `pause()` and a free volume slider via `.volume` — no native audio library needed |
| "press again to stop" breaker-loop | same state machine, `toggle()` in `main.ts`, plus a generation counter so a stale synthesis result arriving after a cancel is ignored | |
| `Run-AsAdmin*.bat` (needed for UIPI — reading selections from elevated windows) | in-app "Restart as Administrator" button (`elevate.ts`) | same `Start-Process -Verb RunAs` trick, no separate file to remember |

**Deliberately not ported (yet):** karaoke-style word-by-word highlighting.
Edge TTS does emit `WordBoundary` events with per-word offsets, so it's
possible — deferred because it either steals focus to draw an overlay, or
needs continuous scroll-position tracking to keep it aligned with scrolling
text, and v1 is about "read this selection well," not that.

## Run

```
npm install
npm run start      # builds the .NET helper + TypeScript, then launches
```

(`npm run dev` skips rebuilding the helper if you haven't touched `Program.cs`.)

Requires: Node/npm, .NET 9 SDK (for `selection-helper`), Python with
`edge-tts` installed (`pip install edge-tts`) on PATH as `python`.

- **Alt+R** — read the current selection; press again to stop.
- **Ctrl+Alt+Q** — quit. Both are blocked from every other app while running.
- Closing the window hides it to the tray; the hotkey keeps working.
- If a selection is empty, check whether the source window is elevated
  (Task Manager, anything "Run as administrator") — use the in-app
  "Restart as Administrator" button if so.

## Files

- `src/main.ts` — app lifecycle, hotkey, the toggle/cancel state machine, IPC
- `src/selectionClient.ts` — talks to the persistent helper process
- `src/edgeTts.ts` — shells out to `python -m edge_tts`, plus `--list-voices`
- `src/cleanForSpeech.ts` — the regex cleanup pipeline (ported from v3-v5)
- `src/elevate.ts` — admin-status check + UAC relaunch
- `src/index.html` / `renderer.ts` — the small control window (voice, volume, log)
- `selection-helper/` — the .NET 9 console app doing the actual UI Automation read

## Known gaps for a v1.1

- Settings (voice/volume) aren't persisted across restarts yet — add a small
  JSON file next to the app, same pattern as elsewhere in this project.
- No packaging (`electron-builder`) yet — runs from source via `npm start`.
- Selection reading happens once per hotkey press, not continuously — by
  design (see v4's rationale docstring), but means the text is snapshotted
  the instant you press Alt+R, not "whatever you highlight from now on."
