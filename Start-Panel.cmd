@echo off
setlocal enableextensions
title Revit Server Stack

rem ============================================================
rem  Revit Server Stack control panel launcher.
rem
rem  Starts a local web UI (http://localhost:8787/ by default)
rem  that starts, stops, rebuilds and configures every rs<year>
rem  container and the reverse proxy.
rem
rem  Requirements: Windows PowerShell 5.1 (ships with Windows)
rem  and Docker Desktop. Nothing else to install.
rem
rem  Keep this window open while you use the panel.
rem  Closing it stops the panel, not the containers.
rem ============================================================

rem UTF-8 console so the panel's Russian messages render correctly.
chcp 65001 >nul

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0panel\server.ps1" %*
if errorlevel 1 (
  echo.
  echo The panel exited with an error. See the output above.
  pause
)

endlocal
