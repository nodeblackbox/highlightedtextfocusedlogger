// SelectionHelper: reads the currently-selected text from whatever window has
// focus, via UI Automation -- the same trick as HighlightLogger v2-v5, ported
// from inline PowerShell/Add-Type C# to a standalone .NET 9 console app so an
// Electron/Node process can spawn it once and talk to it over stdio instead
// of paying PowerShell + Add-Type compile startup cost on every hotkey press.
//
// Protocol (line-delimited, stdin -> stdout, one JSON object per line):
//   in:  get
//   out: {"ok":true,"text":"...","app":"..."}
//   out: {"ok":false,"reason":"nothing-selected"}      (or "password-field")
//   in:  ping
//   out: {"ok":true,"pong":true}
//
// A persistent process (rather than spawn-per-hotkey) also lets us keep the
// per-window "which element actually had the TextPattern" cache from v2/v4/v5,
// so a second read in the same app is instant instead of re-walking the tree.

using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace SelectionHelper;

internal static class Program
{
    private static readonly Dictionary<IntPtr, AutomationElement> HintByWindow = new();
    private static readonly Condition CondTextPattern =
        new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true);

    private static int Main()
    {
        // Line-buffered stdin/stdout so Node's readline/child_process sees each
        // response as soon as it's written, and can pipe UTF-8 text safely.
        var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
        Console.SetOut(stdout);

        string? line;
        while ((line = Console.ReadLine()) != null)
        {
            line = line.Trim();
            if (line.Length == 0) continue;

            try
            {
                switch (line)
                {
                    case "ping":
                        Console.WriteLine(JsonSerializer.Serialize(new { ok = true, pong = true }));
                        break;
                    case "get":
                        Respond(GetSelection());
                        break;
                    default:
                        Console.WriteLine(JsonSerializer.Serialize(new { ok = false, reason = "unknown-command" }));
                        break;
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine(JsonSerializer.Serialize(new { ok = false, reason = "exception", message = ex.Message }));
            }
        }
        return 0;
    }

    private static void Respond(Result r)
    {
        if (r.Text is not null)
            Console.WriteLine(JsonSerializer.Serialize(new { ok = true, text = r.Text, app = r.App }));
        else
            Console.WriteLine(JsonSerializer.Serialize(new { ok = false, reason = r.Reason }));
    }

    private readonly record struct Result(string? Text, string? App, string? Reason);

    private static Result GetSelection()
    {
        AutomationElement? focused;
        try { focused = AutomationElement.FocusedElement; }
        catch { return new Result(null, null, "no-focus"); }
        if (focused is null) return new Result(null, null, "no-focus");

        try
        {
            var isPwd = focused.GetCurrentPropertyValue(AutomationElement.IsPasswordProperty);
            if (isPwd is true) return new Result(null, null, "password-field");
        }
        catch { /* property not supported on this element -- fine, keep going */ }

        var app = SafeAppName(focused);
        var fgHwnd = GetForegroundWindow();

        // 0. Cached hint for this window from a previous successful read.
        if (fgHwnd != IntPtr.Zero && HintByWindow.TryGetValue(fgHwnd, out var hint))
        {
            var hs = TryReadSelection(hint);
            if (!string.IsNullOrEmpty(hs)) return new Result(hs, app, null);
            HintByWindow.Remove(fgHwnd); // stale
        }

        // 1. Focused element + up to 5 ancestors (fast path -- most native apps).
        var fromAncestors = TrySelectionFromAncestors(focused);
        if (!string.IsNullOrEmpty(fromAncestors)) return new Result(fromAncestors, app, null);

        // 2. Descendants of the focused element (Electron/Chromium apps: focus
        //    lands on the WebView host, the real text element is a descendant).
        var descHit = TrySelectionFromTree(focused, TreeScope.Descendants, out var descEl);
        if (!string.IsNullOrEmpty(descHit))
        {
            if (fgHwnd != IntPtr.Zero && descEl is not null) HintByWindow[fgHwnd] = descEl;
            return new Result(descHit, app, null);
        }

        // 3. Whole foreground-window subtree (slow, last resort).
        if (fgHwnd != IntPtr.Zero)
        {
            AutomationElement? winRoot = null;
            try { winRoot = AutomationElement.FromHandle(fgHwnd); } catch { /* window may have closed */ }
            if (winRoot is not null && !Equals(winRoot, focused))
            {
                var winHit = TrySelectionFromTree(winRoot, TreeScope.Subtree, out var winEl);
                if (!string.IsNullOrEmpty(winHit))
                {
                    if (winEl is not null) HintByWindow[fgHwnd] = winEl;
                    return new Result(winHit, app, null);
                }
            }
        }

        return new Result(null, app, "nothing-selected");
    }

    private static string? TrySelectionFromAncestors(AutomationElement el)
    {
        AutomationElement? cur = el;
        var walker = TreeWalker.ControlViewWalker;
        for (var i = 0; i < 6 && cur is not null; i++)
        {
            var s = TryReadSelection(cur);
            if (!string.IsNullOrEmpty(s)) return s;
            try { cur = walker.GetParent(cur); } catch { cur = null; }
            if (cur is null || Equals(cur, AutomationElement.RootElement)) break;
        }
        return null;
    }

    private static string? TrySelectionFromTree(AutomationElement root, TreeScope scope, out AutomationElement? hit)
    {
        hit = null;
        AutomationElementCollection? elements;
        try { elements = root.FindAll(scope, CondTextPattern); }
        catch { return null; }
        if (elements is null) return null;

        foreach (AutomationElement e in elements)
        {
            var s = TryReadSelection(e);
            if (!string.IsNullOrEmpty(s)) { hit = e; return s; }
        }
        return null;
    }

    private static string? TryReadSelection(AutomationElement? el)
    {
        if (el is null) return null;
        object? pat = null;
        try { el.TryGetCurrentPattern(TextPattern.Pattern, out pat); } catch { /* no pattern */ }
        if (pat is not TextPattern tp) return null;

        TextPatternRange[]? ranges;
        try { ranges = tp.GetSelection(); } catch { return null; }
        if (ranges is null || ranges.Length == 0) return null;

        var sb = new StringBuilder();
        foreach (var range in ranges)
        {
            try
            {
                var s = range.GetText(-1);
                if (!string.IsNullOrEmpty(s)) sb.Append(s);
            }
            catch { /* range went stale mid-read */ }
        }
        return sb.Length > 0 ? sb.ToString() : null;
    }

    private static string SafeAppName(AutomationElement el)
    {
        try
        {
            AutomationElement? cur = el;
            var top = el;
            var walker = TreeWalker.ControlViewWalker;
            var safety = 0;
            while (cur is not null && !Equals(cur, AutomationElement.RootElement) && safety++ < 32)
            {
                top = cur;
                try { cur = walker.GetParent(cur); } catch { break; }
            }
            var name = top.Current.Name;
            if (string.IsNullOrWhiteSpace(name)) { try { name = el.Current.ClassName; } catch { /* ignore */ } }
            return string.IsNullOrWhiteSpace(name) ? "?" : name;
        }
        catch { return "?"; }
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
}
