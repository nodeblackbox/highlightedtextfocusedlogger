@echo off
REM Start-Kokoro.bat
REM Launches voicechangerapiV8.py in the right conda env with the user-site
REM shadowing disabled. Without PYTHONNOUSERSITE=1 the kokoro/spacy chain
REM imported from %APPDATA%\Roaming\Python\Python312\site-packages clobbers
REM the env's clean install and breaks the API.
REM
REM Edit ENV_PYTHON if your env moves.

setlocal
set "ENV_PYTHON=C:\Users\nasan\.conda\envs\randnameko3\python.exe"
set "API_FILE=%~dp0voicechangerapiV8.py"
set "PYTHONNOUSERSITE=1"

if not exist "%ENV_PYTHON%" (
    echo ERROR: Cannot find env Python at "%ENV_PYTHON%"
    pause
    exit /b 1
)
if not exist "%API_FILE%" (
    echo ERROR: Cannot find API at "%API_FILE%"
    pause
    exit /b 1
)

echo Launching Kokoro API...
echo   python: %ENV_PYTHON%
echo   api:    %API_FILE%
echo   PYTHONNOUSERSITE=%PYTHONNOUSERSITE%
echo.

"%ENV_PYTHON%" "%API_FILE%"
endlocal
