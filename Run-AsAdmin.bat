@echo off
REM Run-AsAdmin.bat
REM Double-click this file to launch HighlightLogger.ps1 with administrator
REM rights. UAC will prompt -- click Yes. A new elevated PowerShell window
REM will open and start logging highlighted text.
REM
REM Why admin? UIPI (User Interface Privilege Isolation) blocks a normal
REM process from reading text out of elevated apps (Task Manager, Registry
REM Editor, anything you launched As Administrator). Running this elevated
REM lets it read selections from those apps too.

setlocal
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%HighlightLogger.ps1"

if not exist "%SCRIPT_PATH%" (
    echo ERROR: Cannot find "%SCRIPT_PATH%"
    echo Make sure Run-AsAdmin.bat sits next to HighlightLogger.ps1.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -Verb RunAs powershell -ArgumentList '-NoProfile','-NoExit','-ExecutionPolicy','Bypass','-File','%SCRIPT_PATH%'"

endlocal
