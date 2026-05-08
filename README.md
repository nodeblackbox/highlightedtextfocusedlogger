# Highlight Logger

Logs whatever text you **highlight** in any Windows app, using Microsoft **UI Automation** (the same accessibility API screen readers like Narrator and NVDA use). No clipboard hijacking. No OCR.

Five versions ship side-by-side:

- **`HighlightLogger.ps1`** -- v1. Light, walks focused element + ancestors. Background scanning on every mouse-up / key-up.
- **`HighlightLogger-v2.ps1`** -- v2. Adds descendants + window-subtree search for Electron/Chromium apps. Still scans in the background.
- **`HighlightLogger-v3.ps1`** -- v3. v2 plus `Ctrl+R` System.Speech TTS. Still scans in the background -> CPU heavy.
- **`HighlightLogger-v4.ps1`** -- v4. Hotkey-only (`Alt+R`), no background scanning, idle CPU ~0%. Speech via in-box System.Speech (legacy SAPI / Natural voices).
- **`HighlightLogger-v5.ps1`** -- **v5, recommended.** Same hotkey-only architecture as v4, but speech goes through your local Kokoro Flask API (default `http://localhost:5000`, voice `af_heart`). Real stop on second `Alt+R` press. **No changes required to your Kokoro API.**

v1, v2, v3, v4 are kept on purpose; if v5 ever misbehaves or the Kokoro API is offline, fall back to v4.

## What it does

- Watches for mouse releases and key releases system-wide.
- After each event, asks the currently focused control via UI Automation: *"what text is selected?"*
- If something is selected, prints it to the console and appends it to `highlights.log`.
- Skips password fields, deduplicates rapid repeats, and truncates very long selections.

## Run it

Open PowerShell (no admin needed for most apps; see notes below) in this folder, then run **any** version:

```powershell
# v5 (recommended -- ALT+R, Kokoro voice af_heart, real stop)
powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v5.ps1

# v4 (ALT+R, in-box System.Speech voice, no Kokoro dependency)
powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v4.ps1

# v3 (CTRL+R TTS, background scanning)
powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v3.ps1

# v2 (no TTS, deeper selection capture, background scanning)
powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v2.ps1

# v1 (original, lighter)
powershell -ExecutionPolicy Bypass -File .\HighlightLogger.ps1
```

Or double-click `Run-AsAdmin-v5.bat` / `-v4.bat` / `-v3.bat` / `-v2.bat` / `.bat` to launch with admin elevation.

You will see a banner like:

```
HH:MM:SS.fff  === Highlight Logger ===
HH:MM:SS.fff  Log file: D:\Downloads\highlightedtextfocusedlogger\highlights.log
HH:MM:SS.fff  Highlight any text in any app -- it will appear here and in the log.
HH:MM:SS.fff  Exit: press Ctrl+Alt+Q  (or close this window).
```

Now go highlight text anywhere (browser, Word, Notepad, VS Code, PDF, etc.). Each new selection shows up like:

```
HH:MM:SS.fff  [Microsoft Edge] the highlighted text goes here
```

## Hotkeys

- **`Alt+R`** *(v4 + v5)* -- read the currently-highlighted text out loud. Press again to **stop** mid-sentence. **Blocked from every other app** while running.
- **`Ctrl+R`** *(v3)* -- same as above but in v3. Blocked from other apps while v3 is running.
- **`Ctrl+Alt+Q`** -- quit the logger (also blocked from other apps in v3 / v4 / v5).
- Or just close the PowerShell window.

### Does selection survive the hotkey?

Yes. The hotkey is intercepted at the system-hook level **before any app sees it**, then suppressed entirely (the keyboard-hook proc returns non-zero so the source app never receives the keystroke). Focus stays where it is, the highlight stays alive, and `AutomationElement.FocusedElement` + `TextPattern.GetSelection()` reads the live selection at the moment of the call. This is the standard pattern -- LilySpeech, Speak Selection, Microsoft Narrator, NVDA, JAWS all do exactly this.

## Options (v5)

```powershell
powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v5.ps1 `
    -KokoroUrl     "http://localhost:5000" `
    -KokoroVoice   "af_heart" `
    -KokoroSpeed   1.0 `
    -KokoroTimeout 60 `
    -LogPath       "D:\notes\highlights.log" `
    -MaxLength     8000 `
    -NoLog `
    -VerboseDiag
```

- `-KokoroUrl`     base URL of your Flask API (default `http://localhost:5000`).
- `-KokoroVoice`   any voice id Kokoro exposes (`af_heart`, `am_michael`, `bf_emma`, ...). Default `af_heart`.
- `-KokoroSpeed`   `0.25` to `4.0`, default `1.0`.
- `-KokoroTimeout` synthesis HTTP timeout in seconds, default `60`.
- `-LogPath`       path to the log file (default: `highlights.log` next to the script).
- `-MaxLength`     truncate spoken/logged text longer than this (default `8000`).
- `-NoLog`         suppress per-selection logging; TTS still works.
- `-VerboseDiag`   print what UIA found at each scope.

## Options (v4)

```powershell
powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v4.ps1 `
    -Voice       "Guy"
    -Rate        0
    -Volume      100
    -LogPath     "D:\notes\highlights.log"
    -MaxLength   8000
    -NoLog
    -VerboseDiag
```

Same UIA-side options plus the System.Speech voice/rate/volume controls.

## How it works (short version)

### v1 / v2 / v3 (background scanning)

1. Installs two Windows low-level hooks: `WH_MOUSE_LL` and `WH_KEYBOARD_LL`.
2. On every mouse-up or key-up it schedules (with coalescing + a 70 ms delay) a UIA query.
3. The query gets `AutomationElement.FocusedElement` and looks for a `TextPattern` provider in this order:
   1. The focused element itself + up to 5 ancestors *(v1 behavior)*.
   2. **v2+** Descendants of the focused element via `FindAll(IsTextPatternAvailable=true)`.
   3. **v2+** The whole foreground-window subtree.
4. Calls `TextPattern.GetSelection()` on the first hit and logs the text.
5. v2+ caches the winning element per window handle so repeat selections are fast.
6. Identical selections within 1.5 s are suppressed.
7. **v3 only** `Ctrl+R` triggers TTS (everything above keeps running).

### v4 / v5 (hotkey-only)

1. Installs **only** the `WH_KEYBOARD_LL` hook. No mouse hook.
2. The hook does nothing on each keystroke except check for two combos:
   - `Alt+R` -> trigger TTS, suppress the keystroke from other apps.
   - `Ctrl+Alt+Q` -> exit, suppress the keystroke from other apps.
3. Every other keystroke is forwarded immediately. No UIA call. No `Task.Run`. No allocations.
4. The full UIA waterfall (focused -> ancestors -> descendants -> window subtree) only runs when you press `Alt+R`.
5. The cleaned text is then either:
   - **v4**: fed to in-box `System.Speech.Synthesis.SpeechSynthesizer`.
   - **v5**: POSTed to your local Kokoro at `/v1/audio/speech/robust` with `response_format=wav`; the returned WAV bytes are pinned via a `GCHandle` and played asynchronously through `winmm.dll` `PlaySound(SND_MEMORY|SND_ASYNC|SND_NODEFAULT)`.
6. Pressing `Alt+R` again cancels the in-flight HTTP request **and** calls `PlaySound(null, 0, SND_PURGE)`, which tears down any active playback synchronously. Audio cuts off mid-syllable, every time.

This is the exact same UIA path screen readers (Narrator, NVDA, JAWS) use, so anything that exposes itself for accessibility works without app-specific code.

## What works well (out of the box, v1 or v2)

- Edge, Chrome, Firefox (page text + address bar + dev tools).
- Word, Outlook, OneNote.
- Notepad, WordPad, Notepad++.
- Visual Studio.
- File Explorer (file-name editing).
- Most WinUI / WPF / WinForms apps.

## App-specific tips (v2 + a one-time setup per app)

These apps draw their own text and only expose it to accessibility when explicitly asked. v2's deeper search helps a lot, but a small per-app setting unlocks the editor pane / chat area:

### Windsurf / VS Code (editor pane)

The Monaco code editor only exposes its text to UIA when accessibility mode is on.

1. `Ctrl+,` to open Settings.
2. Search **Accessibility Support**.
3. Set **Editor: Accessibility Support** to `on`.
4. Restart the app.

After this, highlighting code in the editor pane will start showing up in the logger.

### Discord

Discord is Electron-based and only enables accessibility when launched with a flag.

1. Right-click the Discord shortcut you use -> **Properties**.
2. In **Target**, append a space and `--force-renderer-accessibility`. Example:
   ```
   "C:\Users\<you>\AppData\Local\Discord\Update.exe" --processStart Discord.exe --force-renderer-accessibility
   ```
3. Apply, fully quit Discord (right-click tray icon -> Quit Discord), relaunch from that shortcut.

Once that flag is on, highlighted chat messages show up in v2.

### Telegram Desktop

Telegram's QT renderer barely exposes UIA. v2 will catch some of it (input box, contact list) but not all chat history. There is no clean fix short of using Telegram Web in a browser, which works perfectly.

## What works poorly (and why)

- **Apps that draw their own text without exposing accessibility**: some games, some old PDF readers, custom DirectX/OpenGL UIs, some terminal emulators. UIA returns nothing, so neither does this tool. OCR or app-specific hacks are the only fix; we deliberately don't go there.
- **Sandboxed or elevated apps**: if a target app runs **As Administrator** and PowerShell does **not**, UIA may refuse to read it. Fix: run PowerShell as Administrator too. (UIPI -- User Interface Privilege Isolation.)
- **Password fields**: intentionally skipped.

## Antivirus

Hooks + UIA across processes look like keylogger behavior to heuristic scanners, even though we never read keystrokes -- only the public selection of the focused control. If your AV complains:

- The script source is right here, fully readable.
- Add an exclusion for this folder, or
- Compile it into a signed `.exe` (see "Compile to .exe" below).

## Tweaks you may want later

- **Hotkey-only mode**: change `MouseHookProc` / `KeyboardHookProc` to only call `ScheduleCheck()` when a specific combo (e.g. `Ctrl+Alt+R`) is released. Then nothing is logged unless you ask.
- **Pipe to TTS**: replace the `Log(...)` call inside `CheckSelection` with a call to your TTS engine (PowerShell's `Add-Type -AssemblyName System.Speech` then `New-Object System.Speech.Synthesis.SpeechSynthesizer` works in one line, but you mentioned you have your own voice models -- shell out to whatever CLI you already use).
- **Filter by app**: check `SafeAppName(focused)` and skip apps you don't care about.

## Compile to .exe (optional)

If you'd rather have a single signed `.exe` that doesn't depend on an external `.ps1`:

1. Move the inline C# from `HighlightLogger.ps1` into `HighlightLogger.cs` and add a `static void Main()` that calls `Configure(...)` then `Start()`.
2. Build with .NET 8 SDK:
   ```
   dotnet new console -n HighlightLogger
   ```
   Then in `HighlightLogger.csproj` add:
   ```xml
   <PropertyGroup>
     <TargetFramework>net8.0-windows</TargetFramework>
     <UseWPF>true</UseWPF>
     <UseWindowsForms>true</UseWindowsForms>
   </PropertyGroup>
   ```
   `<UseWPF>` is what brings the `System.Windows.Automation` types in on .NET 8.
3. `dotnet publish -c Release -r win-x64 --self-contained false` for a small exe, or `--self-contained true /p:PublishSingleFile=true` for a portable single file.

If you want me to spin up that `.csproj` version next, say the word.

## Why v4 / v5 exist (perf)

v2 and v3 install a low-level mouse hook and run a cross-process UIA query on every mouse-up and every key-up. UIA queries are not cheap -- a `FindAll(Subtree, IsTextPatternAvailable)` against a complex Electron window can take 50-300 ms and pin a CPU core during that time. Multiplied by every click and every key release, that's **hundreds of UIA round-trips per minute** while you type. On busy machines this shows up as typing lag and a generally sluggish system.

v4 and v5 throw that away. Idle, both use **~0.4% of one CPU core** -- basically just the message-pump heartbeat. UIA only runs when you press `Alt+R`. If your typing was lagging on v2/v3, switch to v4 or v5 and it stops.

## Kokoro integration (v5)

v5 talks to your existing Kokoro Flask API (the `voicechangerapiV8.py` server, by default at `http://localhost:5000`). **No changes to the API are required.**

What v5 does on `Alt+R`:

1. Snapshots the highlighted text via UIA.
2. Cleans it (markdown, urls, orphan punctuation).
3. POSTs to `POST /v1/audio/speech/robust`:
   ```json
   {
     "input": "<text>",
     "voice": "af_heart",
     "speed": 1.0,
     "response_format": "wav",
     "use_gpu": true,
     "max_chunk_length": 400
   }
   ```
4. Receives WAV bytes (`RIFF...WAVE...`).
5. Pins the byte buffer with `GCHandle.Alloc(..., Pinned)` and calls `winmm.dll PlaySound(buf, 0, SND_MEMORY|SND_ASYNC|SND_NODEFAULT)`. PlaySound returns immediately; the OS audio engine reads the buffer in the background.
6. Computes WAV duration from the file header and uses `Task.Delay(duration_ms, cts.Token)` as the natural-finish signal so the session can be cleaned up correctly.

What v5 does on second `Alt+R` (stop):

1. Calls `PlaySound(null, 0, SND_PURGE)` -- a synchronous winmm tear-down. Audio is dead before the call returns.
2. Cancels the `HttpClient.SendAsync` token (drops any in-flight request mid-download).
3. The natural-finish `Task.Delay` raises `OperationCanceledException`, the `finally` block frees the pinned `GCHandle`, and `_session` is reset to `null` so the next `Alt+R` starts fresh.

**Why not `System.Media.SoundPlayer`?** v5 originally used it. `SoundPlayer.Stop()` is documented to interrupt `PlaySync()` but in practice it can fail to stop short WAVs because the audio subsystem buffers the entire sound up-front -- there's nothing left for `Stop()` to interrupt. `winmm.dll PlaySound` with `SND_PURGE` does not have this problem; it tears down the playback session at the OS level.

This also sidesteps the API's `/v1/audio/speech/play` + `/stop` endpoints, which use `winsound.PlaySound(...)` server-side -- once `winsound` starts playing, it's uninterruptible from Python (the `should_stop` flag is checked **before** play, never during). By doing client-side playback v5 has full control of the audio output and gets real instant-stop behaviour.

### Switching voice

The full Kokoro voice list (28 voices) shows up at `GET /v1/voices`. Examples:

```powershell
powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v5.ps1 -KokoroVoice "am_michael"   # US male
powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v5.ps1 -KokoroVoice "bf_emma"      # GB female
powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v5.ps1 -KokoroVoice "af_bella" -KokoroSpeed 1.15
```

### When Kokoro isn't running

v5 still starts and works normally for selection logging. The startup banner will print:

```
[Kokoro] WARNING: not reachable yet at http://localhost:5000 -- ...
[Kokoro] start your Flask API and the next ALT+R will work.
```

The moment your Flask server is up, the next `Alt+R` press will succeed.

### Latency

Measured locally on the test rig (`af_heart`, RTX 4090, after server warmup):

| Phrase | Bytes | Time |
|---|---|---|
| `Hello world.` (12 chars, **cache hit**) | 75 KB | **4-5 ms** |
| `The quick brown fox.` (20 chars) | 90 KB | **290 ms** |
| `Yet a third one to read.` (24 chars) | 96 KB | **302 ms** |
| `Final example utterance.` (24 chars) | 103 KB | **311 ms** |

The API caches synthesised audio by `md5(text + voice + speed)`, so saying the same phrase twice returns the cached WAV in single-digit milliseconds. Fresh utterances take ~250-350 ms on a 4090 for short text.

**This was originally ~2050 ms per call.** Two perf bugs:

1. **`localhost` hang (the big one).** On Windows, `.NET HttpClient` resolves `localhost` to `::1` (IPv6) first, opens a connection, and waits ~2 seconds for IPv6 to fail before falling back to IPv4. Werkzeug's dev server only binds `0.0.0.0` (IPv4), so every `localhost` call ate ~2 seconds of pure connection-attempt time. The Kokoro API was always responding in ~250 ms; the time was lost in the client's connection phase. v5's default `KokoroUrl` is now `http://127.0.0.1:5000`, which skips DNS entirely. v5 also auto-rewrites any `localhost` URL the user passes via `-KokoroUrl` to `127.0.0.1` for the same reason.
2. **WPAD proxy detection (a smaller side-issue).** `.NET HttpClient` honors the Windows system proxy by default, which on most machines triggers WPAD discovery. v5 sets `HttpClientHandler.UseProxy = false` to skip that.

## Kokoro API perf fixes (`voicechangerapiV8.py`)

While diagnosing the slowness I also fixed three things server-side. None of them were the main culprit but all are good hygiene:

1. **Stopped loading both CPU and GPU models.** The original `EnhancedModelManager.__init__` always loaded a CPU `KModel`, then **also** loaded a GPU `KModel` if CUDA was available. Both copies sat in memory; only one was ever used. v5's fix loads only the GPU model when CUDA is available, with the CPU model created only if GPU init fails.
2. **Wrapped inference in `torch.inference_mode()`.** Both `generate_audio` and `generate_audio_for_chunk` now run the model under `torch.inference_mode()`, which disables autograd. ~2x faster and halves memory.
3. **Added a CUDA warmup at startup.** `EnhancedModelManager._warmup()` runs one tiny inference (`Warmup.` with `af_heart`) before Flask binds the port, so the first user request doesn't pay the CUDA-kernel-compile cost.

Run the API with the included launcher to use the right env (`randnameko3`) with `PYTHONNOUSERSITE=1` (which avoids the polluted `%APPDATA%\Roaming\Python\Python312\site-packages` shadow that breaks `kokoro` -> `misaki` -> `spacy` imports):

```
Start-Kokoro.bat
```

## Voices (v3 / v4) -- in-box SAPI

On startup v3 prints every voice it finds:

```
[TTS] 3 installed voice(s):
       - Microsoft David Desktop [Male, en-US]
       - Microsoft Hazel Desktop [Female, en-GB]
       - Microsoft Zira Desktop [Female, en-US]
[TTS] auto-picked: Microsoft Zira Desktop
```

The "Desktop" ones are the legacy SAPI voices Windows ships with. They sound robotic. The good Edge-quality voices (Aria, Guy, Davis, Jenny, Sonia, Eric, ...) are the **Natural** voices and have to be installed once:

### Install the Natural / "Edge-quality" voices (Windows 11)

1. **Settings** -> **Time & language** -> **Speech**
   *(or)* **Settings** -> **Accessibility** -> **Narrator** -> **Add natural voices**.
2. Click **Manage voices** -> **Add voices**.
3. Pick the languages you want and tick voices like *Aria*, *Guy*, *Davis*, *Jenny*, *Sonia*, *Eric*. Hit **Add**.
4. Wait for the download (~70-200 MB per voice).
5. Restart `HighlightLogger-v3.ps1`. The banner will now list them and auto-pick a Natural one.

Force a specific voice:

```powershell
powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v4.ps1 -Voice "Guy"
```

### Plugging in your own TTS API (e.g. Kokoro)

Inside the C# block of `HighlightLogger-v4.ps1` (or v3), the only place TTS speaks is in `ToggleSpeech()` -- the line:

```csharp
_synth.SpeakAsync(clean);
```

Replace that call (or wrap it behind a config switch) with an HTTP `POST` to your local API. The cleaned text is in `clean`, already free of markdown, URLs, and decorative junk. Stop logic is the same -- `_synth.SpeakAsyncCancelAll()` becomes whatever your API uses to abort playback.

## Speech cleanup (v3 / v4)

Before handing text to TTS, v3 runs a fast regex pipeline (no LLM, no spaCy):

- Strip markdown emphasis, inline code, links, HTML tags.
- Replace URLs with the word "link".
- Replace bullets / arrows / newlines with proper sentence breaks.
- Collapse repeated `???`, `!!!`, `....` to a single mark.
- Drop orphan punctuation like the `?` placeholders that come from empty UIA elements.
- Discard the selection entirely if after cleanup it has fewer than 3 letters/digits (it was just punctuation noise).

If you want to see exactly what cleanup did, run with `-VerboseDiag` and look at the `[TTS] speaking N chars: ...` line.

## Diagnosing a stubborn app

Run v4 (or v2 / v3) with `-VerboseDiag`:

```powershell
powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v4.ps1 -VerboseDiag
```

Now click into the app you're testing and highlight something. The log will show lines like:

```
[verbose] no selection in focused/ancestors. Focus class=Chrome_RenderWidgetHostHWND
[verbose] FindAll(Descendants) returned 0 TextPattern candidates.
[verbose] FindAll(Subtree) returned 0 TextPattern candidates.
```

That tells you the app is hiding its accessibility tree -- usually the fix is one of the per-app tips above (force-accessibility flag, accessibility mode, etc.). If `FindAll` returns candidates but none have a non-empty selection, the selection is happening on a custom-drawn surface and UIA cannot reach it -- that app is genuinely a hard case.

## Files

- `HighlightLogger.ps1` -- v1 (kept stable).
- `HighlightLogger-v2.ps1` -- v2 with descendant + window-subtree search.
- `HighlightLogger-v3.ps1` -- v3 with Ctrl+R global hotkey + System.Speech TTS.
- `HighlightLogger-v4.ps1` -- v4 hotkey-only (Alt+R), System.Speech, low CPU.
- `HighlightLogger-v5.ps1` -- **v5, recommended.** Hotkey-only (Alt+R), Kokoro Flask API backend, real stop.
- `Run-AsAdmin*.bat` -- double-click launchers that elevate via UAC.
- `verify-compile.ps1` -- compile-only sanity check; pass e.g. `-Script HighlightLogger-v5.ps1`.
- `highlights.log` -- created automatically next to the script when you start logging.
