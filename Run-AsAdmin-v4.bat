@echo off
REM Run-AsAdmin-v4.bat
REM Double-click to launch HighlightLogger-v4.ps1 elevated.
REM v4 = hotkey-only mode (ALT+R). No background scanning, low CPU.

setlocal
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%HighlightLogger-v4.ps1"

if not exist "%SCRIPT_PATH%" (
    echo ERROR: Cannot find "%SCRIPT_PATH%"
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -Verb RunAs powershell -ArgumentList '-NoProfile','-NoExit','-ExecutionPolicy','Bypass','-File','%SCRIPT_PATH%'"

endlocal
