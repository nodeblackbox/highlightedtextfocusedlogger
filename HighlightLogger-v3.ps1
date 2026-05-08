# HighlightLogger-v3.ps1
# ------------------------------------------------------------
# v3 = v2 (full selection waterfall) + a global "read it to me" hotkey.
#
#   Highlight any text in any app.
#   Press CTRL+R     -> the current selection is read out loud.
#   Press CTRL+R     -> stops the speech mid-sentence.
#   Press CTRL+ALT+Q -> quits the logger.
#
# CTRL+R is captured at the system-hook level and BLOCKED from being
# delivered to any other app, exactly like LilySpeech's ALT+D. So even
# if the foreground app uses CTRL+R for "reload" or "refactor", that
# combo will NOT reach it while this logger is running.
#
# TTS uses System.Speech (in-box on Windows). The synthesizer auto-picks
# the highest-quality installed voice (Natural / Online voices first,
# then any). Use -Voice to override, -Rate -10..10, -Volume 0..100.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v3.ps1
# Or double-click Run-AsAdmin-v3.bat.
# ------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$LogPath     = $null,
    [int]   $MinLength   = 1,
    [int]   $MaxLength   = 5000,
    [string]$Voice       = $null,    # substring match against InstalledVoice.Name
    [int]   $Rate        = 0,        # -10 .. 10
    [int]   $Volume      = 100,      # 0 .. 100
    [switch]$NoLog,                  # skip selection logging (TTS still works)
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
Add-Type -AssemblyName System.Speech

$cs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Windows.Forms;
using System.Speech.Synthesis;

public static class HighlightLoggerV3
{
    // ---- Configuration ----
    private static string _logPath = "highlights.log";
    private static int    _minLen  = 1;
    private static int    _maxLen  = 5000;
    private static bool   _verbose;
    private static bool   _noLog;
    private static string _preferredVoice;
    private static int    _voiceRate;
    private static int    _voiceVolume = 100;

    // ---- Selection state ----
    private static readonly object Sync = new object();
    private static string   _lastSel    = "";
    private static DateTime _lastSelAt  = DateTime.MinValue;
    private static int      _pending;
    private static volatile bool _running;
    private static readonly Dictionary<IntPtr, AutomationElement> _hintByWindow =
        new Dictionary<IntPtr, AutomationElement>();
    private static readonly object _hintLock = new object();

    // ---- TTS state ----
    private static SpeechSynthesizer _synth;
    private static readonly object _ttsLock = new object();

    // ---- Hotkey state ----
    // While true, ignore further KEYDOWNs of R (auto-repeat) until we see KEYUP.
    private static volatile bool _ctrlRArmed;
    // Set of vk codes whose next KEYUP should be suppressed (because we
    // suppressed the matching KEYDOWN).
    private static readonly HashSet<int> _suppressKeyup = new HashSet<int>();
    private static readonly object _suppressLock = new object();

    // ---- Win32 ----
    private const int WH_MOUSE_LL    = 14;
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_LBUTTONUP   = 0x0202;
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

    private static LowLevelProc _mouseProc;
    private static LowLevelProc _kbProc;
    private static IntPtr _mouseHook = IntPtr.Zero;
    private static IntPtr _kbHook    = IntPtr.Zero;

    private static readonly Condition CondTextPattern =
        new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true);

    public static void Configure(string logPath, int minLen, int maxLen, bool verbose,
                                 bool noLog, string preferredVoice, int rate, int volume)
    {
        _logPath        = logPath;
        _minLen         = minLen;
        _maxLen         = maxLen;
        _verbose        = verbose;
        _noLog          = noLog;
        _preferredVoice = preferredVoice;
        _voiceRate      = rate;
        _voiceVolume    = volume;
    }

    public static void Start()
    {
        InitTts();

        _mouseProc = new LowLevelProc(MouseHookProc);
        _kbProc    = new LowLevelProc(KeyboardHookProc);
        IntPtr hmod = GetModuleHandle(null);

        _mouseHook = SetWindowsHookEx(WH_MOUSE_LL,    _mouseProc, hmod, 0);
        _kbHook    = SetWindowsHookEx(WH_KEYBOARD_LL, _kbProc,    hmod, 0);

        if (_mouseHook == IntPtr.Zero || _kbHook == IntPtr.Zero)
            throw new InvalidOperationException("Failed to install hooks. Win32 error: " + Marshal.GetLastWin32Error());

        _running = true;
        Log("=== Highlight Logger v3 ===");
        Log("Log file: " + _logPath);
        Log("Highlight any text -> press CTRL+R to read it -> press CTRL+R again to stop.");
        Log("CTRL+R is suppressed from all other apps while this is running.");
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
        try { if (_synth != null) _synth.SpeakAsyncCancelAll(); } catch { }
        if (_mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(_mouseHook); _mouseHook = IntPtr.Zero; }
        if (_kbHook    != IntPtr.Zero) { UnhookWindowsHookEx(_kbHook);    _kbHook    = IntPtr.Zero; }
        try { Application.Exit(); } catch { }
    }

    // ---- TTS init ----
    private static void InitTts()
    {
        try
        {
            _synth = new SpeechSynthesizer();
            _synth.SetOutputToDefaultAudioDevice();
            int r = _voiceRate;   if (r < -10) r = -10; if (r > 10) r = 10;   _synth.Rate   = r;
            int v = _voiceVolume; if (v < 0)   v = 0;   if (v > 100) v = 100; _synth.Volume = v;

            System.Collections.ObjectModel.ReadOnlyCollection<InstalledVoice> voices = _synth.GetInstalledVoices();
            Log("[TTS] " + voices.Count + " installed voice(s):");
            foreach (InstalledVoice iv in voices)
            {
                string state = iv.Enabled ? "" : " (disabled)";
                Log("       - " + iv.VoiceInfo.Name + " [" + iv.VoiceInfo.Gender + ", " + iv.VoiceInfo.Culture + "]" + state);
            }

            string picked = null;
            // Explicit override
            if (!string.IsNullOrEmpty(_preferredVoice))
            {
                picked = FindVoice(voices, _preferredVoice);
                if (picked != null) Log("[TTS] -Voice match: " + picked);
                else                Log("[TTS] -Voice '" + _preferredVoice + "' not found, falling back to auto-pick.");
            }
            // Auto-pick: prefer high-quality natural voices, then sane defaults
            if (picked == null)
            {
                string[] keywords = new string[] {
                    "Natural", "Online",
                    "Guy", "Aria", "Davis", "Jenny", "Sonia", "Eric",
                    "Zira", "David", "Mark"
                };
                foreach (string kw in keywords)
                {
                    picked = FindVoice(voices, kw);
                    if (picked != null) { Log("[TTS] auto-picked: " + picked); break; }
                }
            }
            if (picked != null)
            {
                try { _synth.SelectVoice(picked); }
                catch (Exception ex) { Log("[TTS] SelectVoice failed: " + ex.Message); }
            }
            else
            {
                try { Log("[TTS] using default voice: " + _synth.Voice.Name); }
                catch { Log("[TTS] using default voice"); }
            }

            _synth.SpeakStarted   += delegate(object s, SpeakStartedEventArgs e)   { if (_verbose) Log("[TTS] started"); };
            _synth.SpeakCompleted += delegate(object s, SpeakCompletedEventArgs e) { if (_verbose) Log("[TTS] completed"); };
        }
        catch (Exception ex)
        {
            Log("[TTS ERROR] init failed: " + ex.Message);
            _synth = null;
        }
    }

    private static string FindVoice(System.Collections.ObjectModel.ReadOnlyCollection<InstalledVoice> voices, string substr)
    {
        foreach (InstalledVoice iv in voices)
        {
            if (!iv.Enabled) continue;
            if (iv.VoiceInfo.Name.IndexOf(substr, StringComparison.OrdinalIgnoreCase) >= 0)
                return iv.VoiceInfo.Name;
        }
        return null;
    }

    // ---- Hook callbacks ----
    private static IntPtr MouseHookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && wParam.ToInt32() == WM_LBUTTONUP)
            ScheduleCheck();
        return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    private static IntPtr KeyboardHookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int m  = wParam.ToInt32();
            int vk = Marshal.ReadInt32(lParam);

            // ---- KEYDOWN ----
            if (m == WM_KEYDOWN || m == WM_SYSKEYDOWN)
            {
                // Exit hotkey: CTRL+ALT+Q (block from other apps)
                if (vk == VK_Q && IsDown(VK_CONTROL) && IsDown(VK_MENU))
                {
                    MarkSuppressKeyup(VK_Q);
                    Task.Run(new Action(Stop));
                    return (IntPtr)1;
                }
                // TTS toggle: CTRL+R alone (no Alt, no Shift) -- block from other apps
                if (vk == VK_R && IsDown(VK_CONTROL) && !IsDown(VK_MENU) && !IsDown(VK_SHIFT))
                {
                    MarkSuppressKeyup(VK_R);
                    if (!_ctrlRArmed)
                    {
                        _ctrlRArmed = true;
                        Task.Run(new Action(ToggleSpeech));
                    }
                    return (IntPtr)1;
                }
            }

            // ---- KEYUP ----
            if (m == WM_KEYUP || m == WM_SYSKEYUP)
            {
                bool suppress = false;
                lock (_suppressLock) { suppress = _suppressKeyup.Remove(vk); }
                if (vk == VK_R) _ctrlRArmed = false;
                if (suppress) return (IntPtr)1;
                ScheduleCheck();
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
        if (_synth == null)
        {
            Log("[TTS] synthesizer not initialised");
            return;
        }

        lock (_ttsLock)
        {
            SynthesizerState state;
            try { state = _synth.State; } catch { state = SynthesizerState.Ready; }

            if (state != SynthesizerState.Ready)
            {
                try { _synth.SpeakAsyncCancelAll(); } catch { }
                Log("[TTS] stopped (was " + state + ")");
                return;
            }

            string raw = QueryCurrentSelection();
            if (string.IsNullOrWhiteSpace(raw))
            {
                Log("[TTS] no highlighted text found -- highlight something first.");
                return;
            }

            string clean = CleanForSpeech(raw);
            if (string.IsNullOrWhiteSpace(clean))
            {
                Log("[TTS] cleaned text was empty (looked like punctuation noise).");
                return;
            }

            string preview = clean.Length > 80 ? clean.Substring(0, 80) + "..." : clean;
            Log("[TTS] speaking " + clean.Length + " chars: " + preview);
            try { _synth.SpeakAsync(clean); }
            catch (Exception ex) { Log("[TTS ERROR] " + ex.Message); }
        }
    }

    // Query the current selection: try fresh, fall back to the last one we logged.
    private static string QueryCurrentSelection()
    {
        AutomationElement focused = null;
        try { focused = AutomationElement.FocusedElement; } catch { }
        IntPtr fg = IntPtr.Zero;
        try { fg = GetForegroundWindow(); } catch { }

        string fresh = null;
        if (focused != null) fresh = TryGetSelection(focused, fg);
        if (!string.IsNullOrEmpty(fresh)) return fresh;

        string cached;
        lock (Sync) { cached = _lastSel; }
        return cached;
    }

    // ---- Speech text cleanup (fast, regex-only, no LLM) ----
    private static string CleanForSpeech(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        string s = text;

        // 1) Defensive: undo our log-time " / " separators if they sneak in.
        s = s.Replace(" / ", ". ");

        // 2) Strip markdown emphasis / inline code / links.
        s = Regex.Replace(s, @"\*\*([^\*]+)\*\*", "$1");
        s = Regex.Replace(s, @"\*([^\*]+)\*",     "$1");
        s = Regex.Replace(s, @"__([^_]+)__",      "$1");
        s = Regex.Replace(s, @"~~([^~]+)~~",      "$1");
        s = Regex.Replace(s, @"`([^`]+)`",        "$1");
        s = Regex.Replace(s, @"\[([^\]]+)\]\([^)]+\)", "$1");

        // 3) Strip HTML tags.
        s = Regex.Replace(s, @"<[^>]+>", " ");

        // 4) URLs read as the word "link".
        s = Regex.Replace(s, @"https?://\S+", "link");

        // 5) Decorative bullets / arrows -> period (sentence break).
        s = Regex.Replace(s, "[\u2022\u00B7\u25AA\u25AB\u25BA\u25B6\u25B8\u25B9\u2192\u21D2\u2794]", ".");

        // 6) Normalise newlines to a sentence break.
        s = s.Replace("\r\n", ". ").Replace("\n", ". ").Replace("\r", ". ");

        // 7) Collapse repeated punctuation.
        s = Regex.Replace(s, @"\?+", "?");
        s = Regex.Replace(s, @"!+",  "!");
        s = Regex.Replace(s, @"\.{2,}", ".");

        // 8) Drop orphan question marks left over from empty UIA placeholders
        //    (e.g. "? . ? . ? ." becomes nothing useful).
        s = Regex.Replace(s, @"(?:\s*[\?\.]\s*){2,}", ". ");

        // 9) Collapse whitespace.
        s = Regex.Replace(s, @"\s+", " ");

        s = s.Trim().TrimEnd('.', ' ', '\t');

        // 10) If after all that it's mostly punctuation, treat as garbage.
        int meaningful = 0;
        for (int i = 0; i < s.Length; i++)
        {
            if (char.IsLetterOrDigit(s[i])) meaningful++;
            if (meaningful >= 3) break;
        }
        if (meaningful < 3) return "";

        return s;
    }

    // ---- Selection logic (carried over from v2) ----
    private static void ScheduleCheck()
    {
        if (Interlocked.Exchange(ref _pending, 1) == 1) return;
        Task.Run(async delegate
        {
            try
            {
                await Task.Delay(70).ConfigureAwait(false);
                CheckSelection();
            }
            catch (Exception ex) { Log("[ERROR] " + ex.Message); }
            finally { Interlocked.Exchange(ref _pending, 0); }
        });
    }

    private static void CheckSelection()
    {
        AutomationElement focused = null;
        try { focused = AutomationElement.FocusedElement; } catch { return; }
        if (focused == null) return;

        try
        {
            object isPwd = focused.GetCurrentPropertyValue(AutomationElement.IsPasswordProperty);
            if (isPwd is bool && (bool)isPwd) return;
        }
        catch { }

        IntPtr fgHwnd = IntPtr.Zero;
        try { fgHwnd = GetForegroundWindow(); } catch { }

        string text = TryGetSelection(focused, fgHwnd);
        if (string.IsNullOrEmpty(text)) return;
        if (text.Length < _minLen) return;
        string forLog = text;
        if (forLog.Length > _maxLen) forLog = forLog.Substring(0, _maxLen) + "...[truncated]";

        bool sameAsLast;
        lock (Sync)
        {
            sameAsLast = (forLog == _lastSel) && (DateTime.UtcNow - _lastSelAt).TotalMilliseconds < 1500;
            _lastSel   = forLog;
            _lastSelAt = DateTime.UtcNow;
        }
        if (sameAsLast) return;

        if (_noLog) return;
        string app = SafeAppName(focused);
        Log("[" + app + "] " + Sanitize(forLog));
    }

    private static string TryGetSelection(AutomationElement focused, IntPtr fgHwnd)
    {
        // Cached hint
        if (fgHwnd != IntPtr.Zero)
        {
            AutomationElement hint = null;
            lock (_hintLock) { _hintByWindow.TryGetValue(fgHwnd, out hint); }
            if (hint != null)
            {
                string hs = TryReadSelection(hint);
                if (!string.IsNullOrEmpty(hs))
                {
                    if (_verbose) Log("[verbose] hit cached hint for hwnd " + fgHwnd);
                    return hs;
                }
                lock (_hintLock) { _hintByWindow.Remove(fgHwnd); }
            }
        }

        // 1. Element + ancestors
        string s1 = TrySelectionFromAncestors(focused);
        if (!string.IsNullOrEmpty(s1)) return s1;
        if (_verbose) Log("[verbose] no selection in focused/ancestors. Focus class=" + SafeClassName(focused));

        // 2. Descendants of focused
        AutomationElement descHit;
        string s2 = TrySelectionFromTree(focused, TreeScope.Descendants, out descHit);
        if (!string.IsNullOrEmpty(s2))
        {
            RememberHint(fgHwnd, descHit);
            if (_verbose) Log("[verbose] descendant scope -> " + SafeClassName(descHit));
            return s2;
        }

        // 3. Foreground-window subtree
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
                return s3;
            }
            if (_verbose) Log("[verbose] window subtree had no TextPattern with selection. Window class=" + SafeClassName(winRoot));
        }
        return null;
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

    // For LOG output only; speech uses CleanForSpeech instead.
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
    UIAutomationClient, UIAutomationTypes, System.Windows.Forms, WindowsBase, System.Speech

[HighlightLoggerV3]::Configure($LogPath, $MinLength, $MaxLength,
    [bool]$VerboseDiag, [bool]$NoLog,
    $Voice, $Rate, $Volume)

$exitAction = { try { [HighlightLoggerV3]::Stop() } catch { } }
Register-EngineEvent PowerShell.Exiting -Action $exitAction | Out-Null

try {
    [HighlightLoggerV3]::Start()
}
finally {
    [HighlightLoggerV3]::Stop()
}
