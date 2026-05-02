@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Start-NetworkBeagle-GUI.ps1"
if errorlevel 1 (
  echo.
  echo NetworkBeagle launcher ended with an error.
  pause
)
endlocal
