@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Carter-Overlay.ps1"
set "ERR=%ERRORLEVEL%"

echo.
if not "%ERR%"=="0" (
    echo Carter update failed with exit code %ERR%.
)

pause
exit /b %ERR%
