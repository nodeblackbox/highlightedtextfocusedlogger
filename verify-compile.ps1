# verify-compile.ps1
# Compile-only sanity check for HighlightLogger*.ps1.
# Extracts the embedded C# block and runs it through Add-Type without calling Start(),
# so no global hooks are installed.
param(
    [string]$Script = 'HighlightLogger.ps1'
)
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot $Script
$src = Get-Content -Raw -LiteralPath $scriptPath

# Match the single-quoted here-string assigned to $cs
$pattern = "(?s)\`$cs\s*=\s*@'(?<body>.+?)'@"
$m = [regex]::Match($src, $pattern)
if (-not $m.Success) { throw "Could not find embedded C# block in $scriptPath" }
$cs = $m.Groups['body'].Value

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Speech
Add-Type -AssemblyName System.Net.Http

Add-Type -TypeDefinition $cs -ReferencedAssemblies `
    UIAutomationClient, UIAutomationTypes, System.Windows.Forms, WindowsBase, System.Speech, System.Net.Http, System

Write-Host "OK: $Script C# compiled cleanly."
$loaded = [AppDomain]::CurrentDomain.GetAssemblies() |
    ForEach-Object { try { $_.GetTypes() } catch {} } |
    Where-Object { $_.Name -like 'HighlightLogger*' } |
    Select-Object -ExpandProperty FullName -Unique
Write-Host ("Types loaded: " + ($loaded -join ', '))
