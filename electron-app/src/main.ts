/**
 * Highlight Reader -- main process.
 *
 * Architecture, ported from HighlightLogger v4/v5 (PowerShell) to Electron/TS:
 *
 *   v4/v5 (PowerShell)                          this app (Electron/TS)
 *   ---------------------------------------     -----------------------------
 *   WH_KEYBOARD_LL hook, checks ALT+R/CTRL+     globalShortcut.register --
 *     ALT+Q only, returns 1 to swallow it         Windows itself intercepts the
 *     from every other app                        accelerator system-wide; the
 *                                                  foreground app never sees it.
 *   UI Automation waterfall (ancestors ->       SelectionHelper.exe (same
 *     descendants -> window subtree), inline      waterfall, compiled .NET 9)
 *     Add-Type C#, per-window element cache       talked to over stdio, same
 *                                                  per-window cache
 *   CleanForSpeech() regex pipeline             cleanForSpeech.ts (direct port)
 *   System.Speech / Kokoro HTTP + winmm         edge-tts (Python CLI) -> mp3
 *     PlaySound for instant-stop playback         file -> Electron <audio> in
 *                                                  the renderer (pause() is
 *                                                  instant, gives a free
 *                                                  volume slider via .volume)
 *   "press again to stop" breaker-loop logic    same state machine, see
 *                                                  toggle() below
 *
 * No karaoke word-highlighting in this version (deliberately deferred -- see
 * chat notes: focus-stealing + continuous scroll-position tracking to keep an
 * overlay aligned with scrolling text was judged not worth it for v1).
 */
import { app, BrowserWindow, globalShortcut, ipcMain, Tray, Menu, nativeImage } from "electron";
import * as path from "path";
import * as fs from "fs/promises";
import { SelectionClient } from "./selectionClient";
import { cleanForSpeech } from "./cleanForSpeech";
import { synthesize, listVoices, SynthesisCancelled, EdgeVoice } from "./edgeTts";
import { isElevated, relaunchElevated } from "./elevate";

const READ_HOTKEY = "Alt+R";
const QUIT_HOTKEY = "Control+Alt+Q";
const DEFAULT_VOICE = "en-US-AvaNeural"; // matches the getVoices()/"Ava" snippet this was modelled on

type AppState = "idle" | "reading-selection" | "synthesizing" | "speaking";

let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let selectionClient: SelectionClient;
let state: AppState = "idle";
let currentAbort: AbortController | null = null;
let currentCleanup: (() => Promise<void>) | null = null;
let generation = 0; // bumped on every cancel so a late synth result is ignored
let lastToggleAt = 0;
const TOGGLE_DEBOUNCE_MS = 250; // guards against a single physical press producing
  // two globalShortcut callbacks -- Electron doesn't expose Windows' MOD_NOREPEAT

let settings = {
  voice: DEFAULT_VOICE,
  volume: 100, // 0-100, UI slider
  rate: "+0%",
};

function send(channel: string, ...args: unknown[]) {
  mainWindow?.webContents.send(channel, ...args);
}

function log(msg: string) {
  const line = `[${new Date().toLocaleTimeString()}] ${msg}`;
  console.log(line);
  send("log", line);
}

function setState(next: AppState) {
  state = next;
  send("state", state);
}

function helperExePath(): string {
  // Dev layout: electron-app/selection-helper/bin/Release/net9.0-windows/SelectionHelper.exe
  return path.join(
    __dirname,
    "..",
    "selection-helper",
    "bin",
    "Release",
    "net9.0-windows",
    "SelectionHelper.exe"
  );
}

/** The core breaker-loop: press once to start reading, press again to stop --
 * whichever phase (grabbing the selection, synthesizing, or already
 * speaking) it's currently in. */
async function toggle(): Promise<void> {
  const now = Date.now();
  if (now - lastToggleAt < TOGGLE_DEBOUNCE_MS) {
    log(`ignored a toggle within ${TOGGLE_DEBOUNCE_MS}ms of the last one (debounce)`);
    return;
  }
  lastToggleAt = now;

  if (state !== "idle") {
    log(`stopping (was ${state})`);
    generation++; // any in-flight synth result from here on is stale
    currentAbort?.abort();
    currentAbort = null;
    const cleanup = currentCleanup;
    currentCleanup = null;
    send("audio:stop");
    setState("idle");
    if (cleanup) await cleanup();
    return;
  }

  setState("reading-selection");
  const myGen = generation;
  const result = await selectionClient.getSelection();
  if (myGen !== generation) return; // cancelled while we were awaiting

  if (!result.ok || !result.text) {
    log(`nothing to read (${result.reason ?? "unknown"}) -- highlight text first, then press ${READ_HOTKEY}.`);
    setState("idle");
    return;
  }

  const clean = cleanForSpeech(result.text);
  if (!clean) {
    log("selection was mostly punctuation after cleanup -- nothing to say.");
    setState("idle");
    return;
  }

  const preview = clean.length > 80 ? clean.slice(0, 80) + "..." : clean;
  log(`[${result.app ?? "?"}] "${preview}" (${clean.length} chars)`);

  setState("synthesizing");
  const abort = new AbortController();
  currentAbort = abort;
  try {
    const volumePct = settings.volume - 100; // edge-tts wants a delta like "-20%"
    const { mp3Path, cleanup } = await synthesize(clean, settings.voice, {
      rate: settings.rate,
      volume: `${volumePct >= 0 ? "+" : ""}${volumePct}%`,
      signal: abort.signal,
    });
    if (myGen !== generation) {
      await cleanup();
      return;
    }
    currentCleanup = cleanup;
    setState("speaking");
    const data = await fs.readFile(mp3Path);
    send("audio:play", data.buffer, settings.volume / 100);
  } catch (err) {
    if (err instanceof SynthesisCancelled) return; // toggle() already reset state
    log(`TTS error: ${(err as Error).message}`);
    setState("idle");
  }
}

/** Renderer tells us natural playback finished (as opposed to us cancelling it). */
ipcMain.on("audio:ended", async () => {
  if (state !== "speaking") return;
  setState("idle");
  const cleanup = currentCleanup;
  currentCleanup = null;
  if (cleanup) await cleanup();
});

ipcMain.on("settings:set", (_evt, partial: Partial<typeof settings>) => {
  settings = { ...settings, ...partial };
  send("settings", settings);
});

ipcMain.handle("settings:get", () => settings);
ipcMain.handle("elevation:status", () => isElevated());
ipcMain.on("elevation:relaunch", () => relaunchElevated());
ipcMain.handle("voices:list", async (): Promise<EdgeVoice[]> => {
  try {
    const voices = await listVoices();
    return voices.filter((v) => v.locale.startsWith("en-"));
  } catch (err) {
    log(`could not list voices: ${(err as Error).message}`);
    return [{ name: DEFAULT_VOICE, gender: "Female", locale: "en-US" }];
  }
});

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 420,
    height: 560,
    resizable: false,
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  mainWindow.loadFile(path.join(__dirname, "index.html")); // dist/index.html, copied from src/ at build time
  mainWindow.on("close", (e) => {
    // Closing the window just hides it -- the hotkey should keep working
    // from the tray, matching "runs in the background" expectations.
    if (!(app as any).isQuitting) {
      e.preventDefault();
      mainWindow?.hide();
    }
  });
}

function createTray(): void {
  const icon = nativeImage.createEmpty();
  tray = new Tray(icon.isEmpty() ? nativeImage.createFromNamedImage("NSApplicationIcon", []) : icon);
  tray.setToolTip("Highlight Reader");
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: "Show", click: () => mainWindow?.show() },
      { label: `Read selection (${READ_HOTKEY})`, click: () => toggle() },
      { type: "separator" },
      {
        label: "Quit",
        click: () => {
          (app as any).isQuitting = true;
          app.quit();
        },
      },
    ])
  );
  tray.on("click", () => mainWindow?.show());
}

app.whenReady().then(() => {
  selectionClient = new SelectionClient(helperExePath(), log);
  selectionClient.start();

  createWindow();
  createTray();

  const readOk = globalShortcut.register(READ_HOTKEY, () => {
    toggle().catch((err) => log(`toggle() error: ${err.message}`));
  });
  if (!readOk) log(`WARNING: could not register ${READ_HOTKEY} -- another app may already own it.`);
  else log(`${READ_HOTKEY} registered globally -- blocked from every other app while this runs.`);

  const quitOk = globalShortcut.register(QUIT_HOTKEY, () => {
    (app as any).isQuitting = true;
    app.quit();
  });
  if (!quitOk) log(`WARNING: could not register ${QUIT_HOTKEY}.`);

  if (isElevated()) {
    log("Running elevated -- can read selections from admin-only windows (Task Manager, etc).");
  } else {
    log("Running as a normal user. Selections in elevated windows will read as empty (UIPI) -- " +
        "use \"Restart as Administrator\" in the window if you need those.");
  }
  log("Highlight Reader ready. Highlight text anywhere, then press Alt+R.");
});

app.on("will-quit", () => {
  globalShortcut.unregisterAll();
  selectionClient?.stop();
});

app.on("window-all-closed", () => {
  // Keep running (tray + hotkey) even with the window closed, like v4/v5's
  // "runs until Ctrl+Alt+Q" model -- don't quit on Windows/Linux here.
});
