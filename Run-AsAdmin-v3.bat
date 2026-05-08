@echo off
REM Run-AsAdmin-v3.bat
REM Double-click to launch HighlightLogger-v3.ps1 elevated.
REM v3 adds CTRL+R "read this selection" toggle with system-wide hotkey suppression.

setlocal
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%HighlightLogger-v3.ps1"

if not exist "%SCRIPT_PATH%" (
    echo ERROR: Cannot find "%SCRIPT_PATH%"
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -Verb RunAs powershell -ArgumentList '-NoProfile','-NoExit','-ExecutionPolicy','Bypass','-File','%SCRIPT_PATH%'"

endlocal
