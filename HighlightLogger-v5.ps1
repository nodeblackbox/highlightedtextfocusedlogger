# HighlightLogger-v5.ps1
# ------------------------------------------------------------
# v5 = v4 (hotkey-only, no background scanning) + Kokoro TTS backend.
#
# Same architecture as v4: NO background scanning, the keyboard hook
# only checks for ALT+R and CTRL+ALT+Q. UIA is queried only when you
# press the hotkey. Idle CPU is effectively 0%.
#
# What's different from v4:
#   - Speech goes through your local Kokoro Flask API (default
#     http://localhost:5000) instead of System.Speech.
#   - Default voice: af_heart.
#   - Real stop: pressing ALT+R while audio is playing immediately
#     stops it, because we play the WAV locally with SoundPlayer
#     and call Stop() on it. (Your API's /play+/stop endpoints have
#     a broken interrupt; we sidestep that entirely by doing client
#     side playback.)
#   - NO changes required to your API.
#
# Flow:
#   1. Highlight text in any app.
#   2. Press ALT+R.
#      -> v5 grabs the selection via UIA (full v2 waterfall).
#      -> Cleans it (markdown / urls / orphan punctuation).
#      -> POSTs it to /v1/audio/speech/robust (response_format=wav).
#      -> Receives WAV bytes, plays them locally via SoundPlayer.
#   3. Press ALT+R again -> cancels the HTTP request AND stops
#      the local playback instantly.
#   4. CTRL+ALT+Q -> exit.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v5.ps1
# Or:
#   powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v5.ps1 `
#       -KokoroVoice "am_michael" -KokoroSpeed 1.1
# ------------------------------------------------------------

[CmdletBinding()]
param(
    # PERF NOTE: default to 127.0.0.1 instead of localhost. On Windows, .NET
    # HttpClient resolves "localhost" to ::1 first (IPv6) and waits ~2 s for
    # that to fail (Werkzeug binds 0.0.0.0 = IPv4 only) before falling back
    # to IPv4. Using 127.0.0.1 directly skips that completely. Round-trip
    # for a 12-character utterance drops from ~2050 ms to ~10-300 ms.
    [string]$KokoroUrl     = 'http://127.0.0.1:5000',
    [string]$KokoroVoice   = 'af_heart',
    [double]$KokoroSpeed   = 1.0,
    [int]   $KokoroTimeout = 60,         # seconds
    [string]$LogPath       = $null,
    [int]   $MaxLength     = 8000,
    [switch]$NoLog,
    [switch]$VerboseDiag
)

$ErrorActionPreference = 'Stop'

if (-not $LogPath) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $LogPath = Join-Path $root 'highlights.log'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Net.Http

$cs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Windows.Forms;

public static class HighlightLoggerV5
{
    // ---- Configuration ----
    private static string _logPath = "highlights.log";
    private static int    _maxLen  = 8000;
    private static bool   _verbose;
    private static bool   _noLog;
    private static string _kokoroUrl   = "http://localhost:5000";
    private static string _kokoroVoice = "af_heart";
    private static double _kokoroSpeed = 1.0;
    private static int    _kokoroTimeout = 60;

    // ---- Selection cache ----
    private static readonly object Sync = new object();
    private static volatile bool _running;
    private static readonly Dictionary<IntPtr, AutomationElement> _hintByWindow =
        new Dictionary<IntPtr, AutomationElement>();
    private static readonly object _hintLock = new object();

    // ---- TTS session state ----
    //
    // We deliberately do NOT use System.Media.SoundPlayer. Its Stop() can fail
    // to interrupt a PlaySync() that's already in progress (the audio subsystem
    // has buffered the whole short WAV, so there's nothing left to interrupt).
    // Instead we drive winmm.dll PlaySound directly:
    //   - PlaySound(buf, 0, SND_MEMORY|SND_ASYNC|SND_NODEFAULT)  -> non-blocking
    //   - PlaySound(null, 0, SND_PURGE)                          -> instant stop
    // The byte[] is pinned via a GCHandle for the lifetime of playback so the
    // audio engine's pointer into it stays valid.
    private sealed class TtsSession
    {
        public CancellationTokenSource Cts;
        public byte[] WavBytes;
        public GCHandle PinHandle;
        public bool Pinned;
        public int DurationMs;
        public volatile bool IsPlaying;
    }
    private static volatile TtsSession _session;
    private static readonly object _ttsLock = new object();
    private static HttpClient _http;

    // ---- winmm.dll PlaySound ----
    [DllImport("winmm.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern bool PlaySound(IntPtr pszSound, IntPtr hMod, uint fdwSound);

    private const uint SND_ASYNC     = 0x0001;
    private const uint SND_NODEFAULT = 0x0002;
    private const uint SND_MEMORY    = 0x0004;
    private const uint SND_PURGE     = 0x0040;

    // ---- Hotkey state ----
    private static readonly HashSet<int> _suppressKeyup = new HashSet<int>();
    private static readonly object _suppressLock = new object();
    private static volatile bool _altRArmed;

    // ---- Win32 ----
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN     = 0x0100;
    private const int WM_SYSKEYDOWN  = 0x0104;
    private const int WM_KEYUP       = 0x0101;
    private const int WM_SYSKEYUP    = 0x0105;

    private const int VK_CONTROL = 0x11;
    private const int VK_MENU    = 0x12; // Alt
    private const int VK_SHIFT   = 0x10;
    private const int VK_Q       = 0x51;
    private const int VK_R       = 0x52;

    public delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    private static LowLevelProc _kbProc;
    private static IntPtr _kbHook = IntPtr.Zero;

    private static readonly Condition CondTextPattern =
        new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true);

    public static void Configure(string logPath, int maxLen, bool verbose, bool noLog,
                                 string kokoroUrl, string kokoroVoice, double kokoroSpeed,
                                 int kokoroTimeout)
    {
        _logPath        = logPath;
        _maxLen         = maxLen;
        _verbose        = verbose;
        _noLog          = noLog;
        _kokoroUrl      = NormalizeKokoroUrl(kokoroUrl);
        _kokoroVoice    = string.IsNullOrEmpty(kokoroVoice) ? "af_heart" : kokoroVoice;
        _kokoroSpeed    = kokoroSpeed;
        _kokoroTimeout  = kokoroTimeout > 0 ? kokoroTimeout : 60;
    }

    private static string NormalizeKokoroUrl(string url)
    {
        if (string.IsNullOrEmpty(url)) return "http://127.0.0.1:5000";
        url = url.TrimEnd('/');
        // Auto-rewrite localhost -> 127.0.0.1 to dodge the Windows IPv6-first
        // 2 s hang against Werkzeug (which binds IPv4 only).
        try
        {
            var uri = new Uri(url);
            if (string.Equals(uri.Host, "localhost", StringComparison.OrdinalIgnoreCase))
            {
                var fixedUrl = uri.Scheme + "://127.0.0.1" + (uri.IsDefaultPort ? "" : ":" + uri.Port) + uri.PathAndQuery;
                return fixedUrl.TrimEnd('/');
            }
        }
        catch { }
        return url;
    }

    public static void Start()
    {
        InitHttp();
        ProbeKokoro();

        _kbProc = new LowLevelProc(KeyboardHookProc);
        IntPtr hmod = GetModuleHandle(null);
        _kbHook = SetWindowsHookEx(WH_KEYBOARD_LL, _kbProc, hmod, 0);
        if (_kbHook == IntPtr.Zero)
            throw new InvalidOperationException("Failed to install keyboard hook. Win32 error: " + Marshal.GetLastWin32Error());

        _running = true;
        Log("=== Highlight Logger v5 (Kokoro TTS, hotkey-only) ===");
        Log("Log file:   " + _logPath);
        Log("Kokoro:     " + _kokoroUrl + "  voice=" + _kokoroVoice + "  speed=" + _kokoroSpeed.ToString("0.00"));
        Log("Highlight text -> press ALT+R to read it -> press ALT+R again to STOP.");
        Log("ALT+R is suppressed from all other apps while this is running.");
        Log("Exit: CTRL+ALT+Q  (or close this window).");
        if (_noLog)   Log("[mode] selection logging disabled (-NoLog)");
        if (_verbose) Log("[mode] verbose diagnostics enabled (-VerboseDiag)");
        Log(new string('-', 60));

        Application.Run();
    }

    public static void Stop()
    {
        if (!_running) return;
        _running = false;
        StopCurrentSession("shutting down");
        if (_kbHook != IntPtr.Zero) { UnhookWindowsHookEx(_kbHook); _kbHook = IntPtr.Zero; }
        try { Application.Exit(); } catch { }
    }

    // ---- HTTP client setup ----
    private static void InitHttp()
    {
        try
        {
            // PERF FIX: HttpClient defaults to honoring the Windows system proxy,
            // which on most machines triggers WPAD (Web Proxy Auto-Discovery) on
            // every request. With no proxy configured, WPAD silently times out
            // and adds ~2 seconds of pure overhead per call. Killing the proxy
            // path entirely takes round-trip time from ~2300ms to ~260ms for a
            // 12-character utterance against local Kokoro on a 4090.
            var handler = new HttpClientHandler();
            handler.UseProxy = false;
            handler.Proxy = null;
            _http = new HttpClient(handler);
            _http.Timeout = TimeSpan.FromSeconds(_kokoroTimeout);
            // Avoid the Expect:100-continue dance with werkzeug's dev server.
            _http.DefaultRequestHeaders.ExpectContinue = false;
            _http.DefaultRequestHeaders.UserAgent.ParseAdd("HighlightLogger-v5/1.0");
        }
        catch (Exception ex)
        {
            Log("[HTTP ERROR] init failed: " + ex.Message);
        }
    }

    private static void ProbeKokoro()
    {
        if (_http == null) return;
        try
        {
            // 5s tolerates HttpClient first-call cold start (CLR + JIT) on fresh process.
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
            {
                var resp = _http.GetAsync(_kokoroUrl + "/ping", cts.Token).GetAwaiter().GetResult();
                if (resp.IsSuccessStatusCode)
                    Log("[Kokoro] reachable at " + _kokoroUrl + " (HTTP " + (int)resp.StatusCode + ")");
                else
                    Log("[Kokoro] WARNING: " + _kokoroUrl + "/ping returned HTTP " + (int)resp.StatusCode);
            }
        }
        catch (Exception ex)
        {
            Log("[Kokoro] WARNING: not reachable yet at " + _kokoroUrl + " -- " + ex.GetType().Name + ": " + ex.Message);
            Log("[Kokoro] start your Flask API and the next ALT+R will work.");
        }
    }

    // ---- Hook callback (hot path) ----
    private static IntPtr KeyboardHookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int m  = wParam.ToInt32();
            int vk = Marshal.ReadInt32(lParam);

            if (m == WM_KEYDOWN || m == WM_SYSKEYDOWN)
            {
                if (vk == VK_Q && IsDown(VK_CONTROL) && IsDown(VK_MENU))
                {
                    MarkSuppressKeyup(VK_Q);
                    Task.Run(new Action(Stop));
                    return (IntPtr)1;
                }
                if (vk == VK_R && IsDown(VK_MENU) && !IsDown(VK_CONTROL) && !IsDown(VK_SHIFT))
                {
                    MarkSuppressKeyup(VK_R);
                    if (!_altRArmed)
                    {
                        _altRArmed = true;
                        Task.Run(new Action(ToggleSpeech));
                    }
                    return (IntPtr)1;
                }
            }
            else if (m == WM_KEYUP || m == WM_SYSKEYUP)
            {
                bool suppress = false;
                lock (_suppressLock) { suppress = _suppressKeyup.Remove(vk); }
                if (vk == VK_R) _altRArmed = false;
                if (suppress) return (IntPtr)1;
            }
        }
        return CallNextHookEx(_kbHook, nCode, wParam, lParam);
    }

    private static void MarkSuppressKeyup(int vk)
    {
        lock (_suppressLock) { _suppressKeyup.Add(vk); }
    }

    private static bool IsDown(int vk)
    {
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }

    // ---- TTS toggle ----
    private static void ToggleSpeech()
    {
        TtsSession existing;
        lock (_ttsLock)
        {
            existing = _session;
            if (existing != null) _session = null;
        }
        if (existing != null)
        {
            StopSession(existing, "user pressed ALT+R");
            return;
        }

        string raw, app;
        QueryCurrentSelection(out raw, out app);
        if (string.IsNullOrWhiteSpace(raw))
        {
            Log("[TTS] nothing highlighted -- highlight text first then press ALT+R.");
            return;
        }

        if (!_noLog)
        {
            string forLog = raw;
            if (forLog.Length > _maxLen) forLog = forLog.Substring(0, _maxLen) + "...[truncated]";
            Log("[" + (app ?? "?") + "] " + Sanitize(forLog));
        }

        string clean = CleanForSpeech(raw);
        if (string.IsNullOrWhiteSpace(clean))
        {
            Log("[TTS] cleaned text was empty (looked like punctuation noise).");
            return;
        }
        if (clean.Length > _maxLen) clean = clean.Substring(0, _maxLen);

        string preview = clean.Length > 80 ? clean.Substring(0, 80) + "..." : clean;
        Log("[TTS] requesting " + clean.Length + " chars from Kokoro (" + _kokoroVoice + "): " + preview);

        var session = new TtsSession { Cts = new CancellationTokenSource() };
        lock (_ttsLock) { _session = session; }

        Task.Run(new Func<Task>(delegate { return RunSession(session, clean); }));
    }

    private static async Task RunSession(TtsSession session, string text)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            byte[] wavBytes = await PostKokoroSynth(text, session.Cts.Token).ConfigureAwait(false);
            sw.Stop();
            if (session.Cts.IsCancellationRequested) return;
            if (wavBytes == null || wavBytes.Length < 44)
            {
                Log("[TTS] Kokoro returned no audio (got " + (wavBytes == null ? 0 : wavBytes.Length) + " bytes).");
                return;
            }

            int durMs = WavDurationMs(wavBytes);
            session.DurationMs = durMs;
            Log("[TTS] received " + wavBytes.Length + " bytes (~" + (durMs / 1000.0).ToString("0.00") + " s) in " + sw.ElapsedMilliseconds + " ms, playing...");

            if (session.Cts.IsCancellationRequested) return;

            // Pin the WAV buffer so the audio engine can read it asynchronously.
            session.WavBytes = wavBytes;
            session.PinHandle = GCHandle.Alloc(wavBytes, GCHandleType.Pinned);
            session.Pinned = true;

            // Make sure no prior PlaySound is still running (defensive).
            try { PlaySound(IntPtr.Zero, IntPtr.Zero, SND_PURGE); } catch { }

            session.IsPlaying = true;
            bool ok = PlaySound(session.PinHandle.AddrOfPinnedObject(), IntPtr.Zero,
                                SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
            if (!ok)
            {
                int err = Marshal.GetLastWin32Error();
                Log("[TTS ERROR] PlaySound failed (Win32 error " + err + ")");
                return;
            }

            // Wait for natural finish OR cancellation. PlaySound is fire-and-forget,
            // so we use the precomputed WAV duration as the natural-finish signal.
            // 100 ms padding covers small jitter between the engine timestamp and
            // when the speakers actually go quiet.
            int waitMs = durMs > 0 ? durMs + 100 : 60000;
            try
            {
                await Task.Delay(waitMs, session.Cts.Token).ConfigureAwait(false);
                Log("[TTS] playback finished");
            }
            catch (OperationCanceledException)
            {
                // ALT+R hit -> StopSession already called SND_PURGE, nothing to do.
            }
        }
        catch (TaskCanceledException)
        {
            Log("[TTS] cancelled");
        }
        catch (OperationCanceledException)
        {
            Log("[TTS] cancelled");
        }
        catch (HttpRequestException ex)
        {
            Log("[TTS ERROR] Kokoro unreachable at " + _kokoroUrl + " -- " + ex.Message);
            if (ex.InnerException != null) Log("[TTS ERROR] inner: " + ex.InnerException.Message);
        }
        catch (Exception ex)
        {
            Log("[TTS ERROR] " + ex.GetType().Name + ": " + ex.Message);
        }
        finally
        {
            // Make absolutely sure the audio engine has released our pinned buffer
            // before we free the GCHandle, otherwise it could read freed memory.
            if (session.IsPlaying)
            {
                try { PlaySound(IntPtr.Zero, IntPtr.Zero, SND_PURGE); } catch { }
                session.IsPlaying = false;
            }
            if (session.Pinned)
            {
                try { session.PinHandle.Free(); } catch { }
                session.Pinned = false;
            }
            try { session.Cts.Dispose(); } catch { }
            lock (_ttsLock)
            {
                if (_session == session) _session = null;
            }
        }
    }

    private static void StopSession(TtsSession session, string reason)
    {
        Log("[TTS] stopping (" + reason + ")");
        // Order matters: stop audio FIRST (instant), then cancel HTTP/wait.
        // SND_PURGE tears down any in-flight PlaySound playback synchronously.
        try { PlaySound(IntPtr.Zero, IntPtr.Zero, SND_PURGE); } catch { }
        try { session.Cts.Cancel(); } catch { }
    }

    // Parse a standard PCM WAV header to compute duration in milliseconds.
    // Walks chunks so it works with files that have extra chunks before "data".
    private static int WavDurationMs(byte[] wav)
    {
        try
        {
            if (wav == null || wav.Length < 44) return 0;
            if (wav[0] != (byte)'R' || wav[1] != (byte)'I' || wav[2] != (byte)'F' || wav[3] != (byte)'F') return 0;
            if (wav[8] != (byte)'W' || wav[9] != (byte)'A' || wav[10] != (byte)'V' || wav[11] != (byte)'E') return 0;

            int byteRate = 0;
            int dataSize = 0;
            int p = 12;
            while (p + 8 <= wav.Length)
            {
                string id = Encoding.ASCII.GetString(wav, p, 4);
                int sz = BitConverter.ToInt32(wav, p + 4);
                if (sz < 0 || p + 8 + sz > wav.Length) break;
                if (id == "fmt ")
                {
                    if (sz >= 16) byteRate = BitConverter.ToInt32(wav, p + 8 + 8); // sampleRate field is at +12, byteRate at +16 from chunk start
                }
                else if (id == "data")
                {
                    dataSize = sz;
                    break;
                }
                p += 8 + sz + (sz & 1); // chunks are word-aligned
            }
            if (byteRate <= 0 || dataSize <= 0) return 0;
            long ms = (long)dataSize * 1000L / (long)byteRate;
            if (ms > int.MaxValue) return int.MaxValue;
            return (int)ms;
        }
        catch { return 0; }
    }

    private static void StopCurrentSession(string reason)
    {
        TtsSession s;
        lock (_ttsLock)
        {
            s = _session;
            _session = null;
        }
        if (s != null) StopSession(s, reason);
    }

    // ---- Kokoro POST ----
    private static async Task<byte[]> PostKokoroSynth(string text, CancellationToken ct)
    {
        if (_http == null) throw new InvalidOperationException("HttpClient not initialised.");

        string speedStr = _kokoroSpeed.ToString("0.000", System.Globalization.CultureInfo.InvariantCulture);
        string body = "{"
            + "\"input\":" + JsonEscape(text) + ","
            + "\"voice\":" + JsonEscape(_kokoroVoice) + ","
            + "\"speed\":" + speedStr + ","
            + "\"response_format\":\"wav\","
            + "\"use_gpu\":true,"
            + "\"max_chunk_length\":400"
            + "}";

        using (var content = new StringContent(body, Encoding.UTF8, "application/json"))
        using (var req = new HttpRequestMessage(HttpMethod.Post, _kokoroUrl + "/v1/audio/speech/robust"))
        {
            req.Content = content;
            using (var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct).ConfigureAwait(false))
            {
                if (!resp.IsSuccessStatusCode)
                {
                    string errBody = "";
                    try { errBody = await resp.Content.ReadAsStringAsync().ConfigureAwait(false); } catch { }
                    if (errBody.Length > 200) errBody = errBody.Substring(0, 200) + "...";
                    throw new Exception("Kokoro returned HTTP " + (int)resp.StatusCode + " " + resp.ReasonPhrase + ": " + errBody);
                }
                return await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
            }
        }
    }

    private static string JsonEscape(string s)
    {
        if (s == null) return "null";
        var sb = new StringBuilder(s.Length + 2);
        sb.Append('"');
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            switch (c)
            {
                case '\\': sb.Append("\\\\"); break;
                case '"':  sb.Append("\\\""); break;
                case '\b': sb.Append("\\b");  break;
                case '\f': sb.Append("\\f");  break;
                case '\n': sb.Append("\\n");  break;
                case '\r': sb.Append("\\r");  break;
                case '\t': sb.Append("\\t");  break;
                default:
                    if (c < 0x20) sb.AppendFormat("\\u{0:X4}", (int)c);
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
        return sb.ToString();
    }

    // ---- One-shot UIA selection query (same waterfall as v4) ----
    private static void QueryCurrentSelection(out string text, out string appName)
    {
        text = null;
        appName = null;

        AutomationElement focused = null;
        try { focused = AutomationElement.FocusedElement; } catch { }
        if (focused == null) return;

        try
        {
            object isPwd = focused.GetCurrentPropertyValue(AutomationElement.IsPasswordProperty);
            if (isPwd is bool && (bool)isPwd) { Log("[TTS] focus is a password field -- skipped."); return; }
        }
        catch { }

        appName = SafeAppName(focused);

        IntPtr fgHwnd = IntPtr.Zero;
        try { fgHwnd = GetForegroundWindow(); } catch { }

        if (fgHwnd != IntPtr.Zero)
        {
            AutomationElement hint = null;
            lock (_hintLock) { _hintByWindow.TryGetValue(fgHwnd, out hint); }
            if (hint != null)
            {
                string hs = TryReadSelection(hint);
                if (!string.IsNullOrEmpty(hs))
                {
                    if (_verbose) Log("[verbose] cached hint hit for hwnd " + fgHwnd);
                    text = hs; return;
                }
                lock (_hintLock) { _hintByWindow.Remove(fgHwnd); }
            }
        }

        string s1 = TrySelectionFromAncestors(focused);
        if (!string.IsNullOrEmpty(s1)) { text = s1; return; }
        if (_verbose) Log("[verbose] no selection in focused/ancestors. Focus class=" + SafeClassName(focused));

        AutomationElement descHit;
        string s2 = TrySelectionFromTree(focused, TreeScope.Descendants, out descHit);
        if (!string.IsNullOrEmpty(s2))
        {
            RememberHint(fgHwnd, descHit);
            if (_verbose) Log("[verbose] descendant scope -> " + SafeClassName(descHit));
            text = s2; return;
        }

        AutomationElement winRoot = null;
        if (fgHwnd != IntPtr.Zero) { try { winRoot = AutomationElement.FromHandle(fgHwnd); } catch { } }
        if (winRoot != null && winRoot != focused)
        {
            AutomationElement winHit;
            string s3 = TrySelectionFromTree(winRoot, TreeScope.Subtree, out winHit);
            if (!string.IsNullOrEmpty(s3))
            {
                RememberHint(fgHwnd, winHit);
                if (_verbose) Log("[verbose] window subtree -> " + SafeClassName(winHit));
                text = s3; return;
            }
            if (_verbose) Log("[verbose] window subtree had no TextPattern with selection. Window class=" + SafeClassName(winRoot));
        }
    }

    private static void RememberHint(IntPtr hwnd, AutomationElement el)
    {
        if (hwnd == IntPtr.Zero || el == null) return;
        lock (_hintLock) { _hintByWindow[hwnd] = el; }
    }

    private static string TrySelectionFromAncestors(AutomationElement el)
    {
        AutomationElement cur = el;
        TreeWalker walker = TreeWalker.ControlViewWalker;
        for (int i = 0; i < 6 && cur != null; i++)
        {
            string s = TryReadSelection(cur);
            if (!string.IsNullOrEmpty(s)) return s;
            try { cur = walker.GetParent(cur); } catch { cur = null; }
            if (cur == null || cur == AutomationElement.RootElement) break;
        }
        return null;
    }

    private static string TrySelectionFromTree(AutomationElement root, TreeScope scope, out AutomationElement hit)
    {
        hit = null;
        if (root == null) return null;

        AutomationElementCollection elements = null;
        try { elements = root.FindAll(scope, CondTextPattern); }
        catch (Exception ex)
        {
            if (_verbose) Log("[verbose] FindAll(" + scope + ") threw: " + ex.GetType().Name);
            return null;
        }
        if (elements == null || elements.Count == 0)
        {
            if (_verbose) Log("[verbose] FindAll(" + scope + ") -> 0 candidates.");
            return null;
        }
        if (_verbose) Log("[verbose] FindAll(" + scope + ") -> " + elements.Count + " candidates.");

        for (int i = 0; i < elements.Count; i++)
        {
            AutomationElement e = elements[i];
            string s = TryReadSelection(e);
            if (!string.IsNullOrEmpty(s)) { hit = e; return s; }
        }
        return null;
    }

    private static string TryReadSelection(AutomationElement el)
    {
        if (el == null) return null;
        object pat = null;
        try { el.TryGetCurrentPattern(TextPattern.Pattern, out pat); } catch { }
        TextPattern tp = pat as TextPattern;
        if (tp == null) return null;

        TextPatternRange[] ranges = null;
        try { ranges = tp.GetSelection(); } catch { return null; }
        if (ranges == null || ranges.Length == 0) return null;

        StringBuilder sb = new StringBuilder();
        for (int j = 0; j < ranges.Length; j++)
        {
            try
            {
                string s = ranges[j].GetText(-1);
                if (!string.IsNullOrEmpty(s)) sb.Append(s);
            }
            catch { }
        }
        return sb.Length > 0 ? sb.ToString() : null;
    }

    // ---- Speech text cleanup (same fast regex pipeline as v3/v4) ----
    private static string CleanForSpeech(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        string s = text;

        s = s.Replace(" / ", ". ");
        s = Regex.Replace(s, @"\*\*([^\*]+)\*\*", "$1");
        s = Regex.Replace(s, @"\*([^\*]+)\*",     "$1");
        s = Regex.Replace(s, @"__([^_]+)__",      "$1");
        s = Regex.Replace(s, @"~~([^~]+)~~",      "$1");
        s = Regex.Replace(s, @"`([^`]+)`",        "$1");
        s = Regex.Replace(s, @"\[([^\]]+)\]\([^)]+\)", "$1");
        s = Regex.Replace(s, @"<[^>]+>", " ");
        s = Regex.Replace(s, @"https?://\S+", "link");
        s = Regex.Replace(s, "[\u2022\u00B7\u25AA\u25AB\u25BA\u25B6\u25B8\u25B9\u2192\u21D2\u2794]", ".");
        s = s.Replace("\r\n", ". ").Replace("\n", ". ").Replace("\r", ". ");
        s = Regex.Replace(s, @"\?+", "?");
        s = Regex.Replace(s, @"!+",  "!");
        s = Regex.Replace(s, @"\.{2,}", ".");
        s = Regex.Replace(s, @"(?:\s*[\?\.]\s*){2,}", ". ");
        s = Regex.Replace(s, @"\s+", " ");
        s = s.Trim().TrimEnd('.', ' ', '\t');

        int meaningful = 0;
        for (int i = 0; i < s.Length; i++)
        {
            if (char.IsLetterOrDigit(s[i])) meaningful++;
            if (meaningful >= 3) break;
        }
        if (meaningful < 3) return "";
        return s;
    }

    private static string SafeAppName(AutomationElement el)
    {
        try
        {
            AutomationElement cur = el; AutomationElement top = el;
            TreeWalker walker = TreeWalker.ControlViewWalker;
            int safety = 0;
            while (cur != null && cur != AutomationElement.RootElement && safety++ < 32)
            {
                top = cur;
                try { cur = walker.GetParent(cur); } catch { break; }
            }
            string name = (top != null) ? top.Current.Name : null;
            if (string.IsNullOrWhiteSpace(name)) { try { name = el.Current.ClassName; } catch { } }
            return string.IsNullOrWhiteSpace(name) ? "?" : name;
        }
        catch { return "?"; }
    }

    private static string SafeClassName(AutomationElement el)
    {
        if (el == null) return "<null>";
        try { return el.Current.ClassName ?? ""; } catch { return "?"; }
    }

    private static string Sanitize(string s)
    {
        return s.Replace("\r\n", " / ").Replace("\n", " / ").Replace("\r", " / ");
    }

    private static void Log(string line)
    {
        string stamped = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + line;
        lock (Sync)
        {
            try { Console.WriteLine(stamped); } catch { }
            try { File.AppendAllText(_logPath, stamped + Environment.NewLine, Encoding.UTF8); } catch { }
        }
    }
}
'@

Add-Type -TypeDefinition $cs -ReferencedAssemblies `
    UIAutomationClient, UIAutomationTypes, System.Windows.Forms, WindowsBase, System.Net.Http, System

[HighlightLoggerV5]::Configure($LogPath, $MaxLength,
    [bool]$VerboseDiag, [bool]$NoLog,
    $KokoroUrl, $KokoroVoice, [double]$KokoroSpeed, [int]$KokoroTimeout)

$exitAction = { try { [HighlightLoggerV5]::Stop() } catch { } }
Register-EngineEvent PowerShell.Exiting -Action $exitAction | Out-Null

try {
    [HighlightLoggerV5]::Start()
}
finally {
    [HighlightLoggerV5]::Stop()
}
