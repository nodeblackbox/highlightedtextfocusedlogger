# HighlightLogger-v2.ps1
# ------------------------------------------------------------
# v2 changes vs v1:
#   * After failing to find a TextPattern on the focused element
#     and its ancestors, v2 also searches DESCENDANTS of the focused
#     element, then falls back to the entire foreground-window tree.
#     This recovers text from Electron / Chromium-based apps where
#     focus lands on the WebView host and the actual text element is
#     buried as a descendant (Discord, Telegram, Windsurf/VS Code
#     editor pane, etc.).
#   * Per-window cache of the last successful TextPattern element so
#     repeat selections in the same app are instant instead of doing
#     a full subtree search every time.
#   * -Verbose switch prints WHY a check failed (focus class, scope
#     tried, candidate count) -- handy when an app refuses to expose.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File .\HighlightLogger-v2.ps1
#
# Exit:
#   Ctrl+Alt+Q  (or just close this window).
# ------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$LogPath   = $null,
    [int]   $MinLength = 1,
    [int]   $MaxLength = 5000,
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

$cs = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Windows.Forms;

public static class HighlightLoggerV2
{
    // ---- Configuration ----
    private static string _logPath = "highlights.log";
    private static int    _minLen  = 1;
    private static int    _maxLen  = 5000;
    private static bool   _verbose;

    // ---- State ----
    private static readonly object Sync = new object();
    private static string   _lastSel    = "";
    private static DateTime _lastSelAt  = DateTime.MinValue;
    private static int      _pending;
    private static volatile bool _running;

    // Per-window cache of the last element that successfully gave us a selection.
    private static readonly Dictionary<IntPtr, AutomationElement> _hintByWindow =
        new Dictionary<IntPtr, AutomationElement>();
    private static readonly object _hintLock = new object();

    // ---- Win32 ----
    private const int WH_MOUSE_LL    = 14;
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_LBUTTONUP   = 0x0202;
    private const int WM_KEYUP       = 0x0101;
    private const int WM_SYSKEYUP    = 0x0105;
    private const int VK_CONTROL = 0x11;
    private const int VK_MENU    = 0x12; // Alt
    private const int VK_Q       = 0x51;

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

    // Reused condition: "this element supports TextPattern".
    private static readonly Condition CondTextPattern =
        new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true);

    public static void Configure(string logPath, int minLen, int maxLen, bool verbose)
    {
        _logPath = logPath;
        _minLen  = minLen;
        _maxLen  = maxLen;
        _verbose = verbose;
    }

    public static void Start()
    {
        _mouseProc = new LowLevelProc(MouseHookProc);
        _kbProc    = new LowLevelProc(KeyboardHookProc);
        IntPtr hmod = GetModuleHandle(null);

        _mouseHook = SetWindowsHookEx(WH_MOUSE_LL,    _mouseProc, hmod, 0);
        _kbHook    = SetWindowsHookEx(WH_KEYBOARD_LL, _kbProc,    hmod, 0);

        if (_mouseHook == IntPtr.Zero || _kbHook == IntPtr.Zero)
            throw new InvalidOperationException("Failed to install hooks. Win32 error: " + Marshal.GetLastWin32Error());

        _running = true;
        Log("=== Highlight Logger v2 ===");
        Log("Log file: " + _logPath);
        Log("Highlight any text in any app -- ancestors + descendants + window scopes are tried.");
        Log("Exit: press Ctrl+Alt+Q  (or close this window).");
        if (_verbose) Log("[verbose] diagnostics enabled.");
        Log(new string('-', 60));

        Application.Run();
    }

    public static void Stop()
    {
        if (!_running) return;
        _running = false;
        if (_mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(_mouseHook); _mouseHook = IntPtr.Zero; }
        if (_kbHook    != IntPtr.Zero) { UnhookWindowsHookEx(_kbHook);    _kbHook    = IntPtr.Zero; }
        try { Application.Exit(); } catch { }
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
            int m = wParam.ToInt32();
            if (m == WM_KEYUP || m == WM_SYSKEYUP)
            {
                int vk = Marshal.ReadInt32(lParam);
                if (vk == VK_Q && IsDown(VK_CONTROL) && IsDown(VK_MENU))
                {
                    Log("Exit hotkey received. Shutting down...");
                    Task.Run(new Action(Stop));
                }
                else
                {
                    ScheduleCheck();
                }
            }
        }
        return CallNextHookEx(_kbHook, nCode, wParam, lParam);
    }

    private static bool IsDown(int vk)
    {
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }

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
        try { focused = AutomationElement.FocusedElement; }
        catch { return; }
        if (focused == null) return;

        // Skip password fields
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
        if (text.Length > _maxLen) text = text.Substring(0, _maxLen) + "...[truncated]";

        if (text == _lastSel && (DateTime.UtcNow - _lastSelAt).TotalMilliseconds < 1500) return;
        _lastSel   = text;
        _lastSelAt = DateTime.UtcNow;

        string app = SafeAppName(focused);
        Log("[" + app + "] " + Sanitize(text));
    }

    // ---- Selection finding waterfall ----
    private static string TryGetSelection(AutomationElement focused, IntPtr fgHwnd)
    {
        // Step 0: cached hint for the current foreground window.
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
                // hint went stale -- drop it.
                lock (_hintLock) { _hintByWindow.Remove(fgHwnd); }
            }
        }

        // Step 1: focused element + up to 5 ancestors.
        string s1 = TrySelectionFromAncestors(focused);
        if (!string.IsNullOrEmpty(s1))
        {
            return s1;
        }
        if (_verbose) Log("[verbose] no selection in focused/ancestors. Focus class=" + SafeClassName(focused));

        // Step 2: descendants of the focused element.
        AutomationElement descHit;
        string s2 = TrySelectionFromTree(focused, TreeScope.Descendants, out descHit);
        if (!string.IsNullOrEmpty(s2))
        {
            RememberHint(fgHwnd, descHit);
            if (_verbose) Log("[verbose] descendant scope produced selection from " + SafeClassName(descHit));
            return s2;
        }

        // Step 3: whole foreground-window subtree.
        AutomationElement winRoot = null;
        if (fgHwnd != IntPtr.Zero)
        {
            try { winRoot = AutomationElement.FromHandle(fgHwnd); } catch { }
        }
        if (winRoot != null && winRoot != focused)
        {
            AutomationElement winHit;
            string s3 = TrySelectionFromTree(winRoot, TreeScope.Subtree, out winHit);
            if (!string.IsNullOrEmpty(s3))
            {
                RememberHint(fgHwnd, winHit);
                if (_verbose) Log("[verbose] window subtree produced selection from " + SafeClassName(winHit));
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

    // Try the element + 5 ancestors (v1's logic).
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

    // Walk a tree (descendants or subtree) for any element supporting TextPattern
    // with a non-empty selection.
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
            if (_verbose) Log("[verbose] FindAll(" + scope + ") returned 0 candidates.");
            return null;
        }

        if (_verbose) Log("[verbose] FindAll(" + scope + ") returned " + elements.Count + " TextPattern candidates.");

        for (int i = 0; i < elements.Count; i++)
        {
            AutomationElement e = elements[i];
            string s = TryReadSelection(e);
            if (!string.IsNullOrEmpty(s)) { hit = e; return s; }
        }
        return null;
    }

    // Read the current selection from a single element (if it supports TextPattern).
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

    // ---- App / class name helpers ----
    private static string SafeAppName(AutomationElement el)
    {
        try
        {
            AutomationElement cur = el;
            AutomationElement top = el;
            TreeWalker walker = TreeWalker.ControlViewWalker;
            int safety = 0;
            while (cur != null && cur != AutomationElement.RootElement && safety++ < 32)
            {
                top = cur;
                try { cur = walker.GetParent(cur); } catch { break; }
            }
            string name = (top != null) ? top.Current.Name : null;
            if (string.IsNullOrWhiteSpace(name))
            {
                try { name = el.Current.ClassName; } catch { }
            }
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
        // v1 behaviour preserved: collapse newlines to " / " for one-line log output.
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
    UIAutomationClient, UIAutomationTypes, System.Windows.Forms, WindowsBase

[HighlightLoggerV2]::Configure($LogPath, $MinLength, $MaxLength, [bool]$VerboseDiag)

$exitAction = {
    try { [HighlightLoggerV2]::Stop() } catch { }
}
Register-EngineEvent PowerShell.Exiting -Action $exitAction | Out-Null

try {
    [HighlightLoggerV2]::Start()
}
finally {
    [HighlightLoggerV2]::Stop()
}
