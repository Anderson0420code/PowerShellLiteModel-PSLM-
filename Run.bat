@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Start-AI-Daemon.ps1"
if errorlevel 1 (
  echo.
  echo [PSLM] Daemon terminated with an error.
  pause
)
