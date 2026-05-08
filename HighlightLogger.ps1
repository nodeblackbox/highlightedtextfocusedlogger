# HighlightLogger.ps1
# ------------------------------------------------------------
# Logs whatever text you HIGHLIGHT in any Windows app, using
# Microsoft UI Automation (the API screen readers use).
#
# - No clipboard hijacking.
# - No OCR.
# - Works in most modern apps: Edge, Chrome, Firefox, VS Code,
#   Word, Notepad, Notepad++, PDF readers that expose a11y, etc.
# - Falls back gracefully when an app doesn't expose UIA text.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File .\HighlightLogger.ps1
#
# Exit:
#   Ctrl+Alt+Q  (or just close the PowerShell window)
# ------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$LogPath   = $null,
    [int]   $MinLength = 1,
    [int]   $MaxLength = 5000
)

$ErrorActionPreference = 'Stop'

# Resolve default log path next to the script (or cwd if dot-sourced)
if (-not $LogPath) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $LogPath = Join-Path $root 'highlights.log'
}

# Required assemblies (all in-box on Windows 10/11)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName WindowsBase

# --- Inline C# helper: hooks + UIA selection reader ---------
$cs = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Windows.Forms;

public static class HighlightLogger
{
    // ---- Configuration ----
    private static string _logPath = "highlights.log";
    private static int    _minLen  = 1;
    private static int    _maxLen  = 5000;

    // ---- State ----
    private static readonly object Sync = new object();
    private static string   _lastSel    = "";
    private static DateTime _lastSelAt  = DateTime.MinValue;
    private static int      _pending;
    private static volatile bool _running;

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

    // Keep delegates rooted so the GC does not collect them
    private static LowLevelProc _mouseProc;
    private static LowLevelProc _kbProc;
    private static IntPtr _mouseHook = IntPtr.Zero;
    private static IntPtr _kbHook    = IntPtr.Zero;

    public static void Configure(string logPath, int minLen, int maxLen)
    {
        _logPath = logPath;
        _minLen  = minLen;
        _maxLen  = maxLen;
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
        Log("=== Highlight Logger ===");
        Log("Log file: " + _logPath);
        Log("Highlight any text in any app -- it will appear here and in the log.");
        Log("Exit: press Ctrl+Alt+Q  (or close this window).");
        Log(new string('-', 60));

        // Pump messages; low-level hooks need a message loop on the installer thread.
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

    // ---- Hook callbacks (run on the message-pump thread; keep them fast) ----
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
                int vk = Marshal.ReadInt32(lParam); // KBDLLHOOKSTRUCT.vkCode is the first DWORD
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

    // Coalesce: at most one selection check pending at a time.
    private static void ScheduleCheck()
    {
        if (Interlocked.Exchange(ref _pending, 1) == 1) return;
        Task.Run(async delegate
        {
            try
            {
                // Brief delay so the foreground app commits its selection state
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

        // Skip password fields (security + privacy)
        try
        {
            object isPwd = focused.GetCurrentPropertyValue(AutomationElement.IsPasswordProperty);
            if (isPwd is bool && (bool)isPwd) return;
        }
        catch { }

        string text;
        try { text = TryGetSelection(focused); }
        catch { return; }
        if (string.IsNullOrEmpty(text)) return;
        if (text.Length < _minLen) return;
        if (text.Length > _maxLen) text = text.Substring(0, _maxLen) + "...[truncated]";

        // Suppress repeats of the same selection within a short window
        if (text == _lastSel && (DateTime.UtcNow - _lastSelAt).TotalMilliseconds < 1500) return;
        _lastSel   = text;
        _lastSelAt = DateTime.UtcNow;

        string app = SafeAppName(focused);
        Log("[" + app + "] " + Sanitize(text));
    }

    // Walk up to 5 ancestors looking for a TextPattern provider, then read its current selection.
    private static string TryGetSelection(AutomationElement el)
    {
        AutomationElement cur = el;
        TreeWalker walker = TreeWalker.ControlViewWalker;
        for (int i = 0; i < 5 && cur != null; i++)
        {
            object pat = null;
            try { cur.TryGetCurrentPattern(TextPattern.Pattern, out pat); } catch { }
            TextPattern tp = pat as TextPattern;
            if (tp != null)
            {
                TextPatternRange[] ranges = null;
                try { ranges = tp.GetSelection(); } catch { }
                if (ranges != null && ranges.Length > 0)
                {
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
                    if (sb.Length > 0) return sb.ToString();
                }
            }
            try { cur = walker.GetParent(cur); } catch { cur = null; }
            if (cur == null || cur == AutomationElement.RootElement) break;
        }
        return null;
    }

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

# Compile the inline C# (in-box compiler -- no SDK install required)
Add-Type -TypeDefinition $cs -ReferencedAssemblies `
    UIAutomationClient, UIAutomationTypes, System.Windows.Forms, WindowsBase

# Hand parameters to the C# class
[HighlightLogger]::Configure($LogPath, $MinLength, $MaxLength)

# Make sure we unhook on exit, even if PowerShell is closed via X
$exitAction = {
    try { [HighlightLogger]::Stop() } catch { }
}
Register-EngineEvent PowerShell.Exiting -Action $exitAction | Out-Null

try {
    [HighlightLogger]::Start()
}
finally {
    [HighlightLogger]::Stop()
}
