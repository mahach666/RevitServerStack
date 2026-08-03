@echo off
setlocal enableextensions
title Revit Server 2025

rem ============================================================
rem  Revit Server 2025 launcher
rem  - rs2025 runs on the Docker "desktop-windows" engine.
rem  - A reverse proxy (revit-proxy, Linux engine) publishes ALL
rem    versions on port 80, routing by the version year in the URL,
rem    so Revit connects by host name/IP with NO port.
rem  - Versions run side by side; this no longer stops other ones.
rem  Models are stored on the host in:  %~dp0rs2025
rem ============================================================

set "VERSION=2025"
set "CTX=desktop-windows"
set "COMPOSE=%~dp0docker-compose.%VERSION%.yml"
set "PROXY=%~dp0docker-compose.proxy.yml"
set "ADMIN=http://localhost/RevitServerAdmin%VERSION%/"
set "DATADIR=%~dp0rs%VERSION%"
set "DOCKERCLI=%ProgramFiles%\Docker\Docker\DockerCli.exe"
set "DOCKERDESKTOP=%ProgramFiles%\Docker\Docker\Docker Desktop.exe"

echo.
echo === Revit Server %VERSION% launcher ===
echo.

rem --- 1) Make sure Docker Desktop is running -----------------
echo [1/6] Checking Docker Desktop...
docker info >nul 2>&1
if not errorlevel 1 goto desktop_ok
echo       Docker not reachable - starting Docker Desktop...
if exist "%DOCKERDESKTOP%" start "" "%DOCKERDESKTOP%"
set /a tries=0
:wait_desktop
timeout /t 5 >nul
docker info >nul 2>&1
if not errorlevel 1 goto desktop_ok
set /a tries+=1
if %tries% geq 36 (
  echo ERROR: Docker Desktop did not start within ~3 minutes. Start it manually and retry.
  pause
  exit /b 1
)
goto wait_desktop
:desktop_ok

rem --- 2) Ensure the Windows engine context is reachable ------
echo [2/6] Checking Windows container engine (context: %CTX%)...
docker --context %CTX% version >nul 2>&1
if not errorlevel 1 goto engine_ok
echo       Windows engine not active yet - enabling it via Docker Desktop...
if exist "%DOCKERCLI%" "%DOCKERCLI%" -SwitchWindowsEngine
set /a tries=0
:wait_win
timeout /t 5 >nul
docker --context %CTX% version >nul 2>&1
if not errorlevel 1 goto engine_ok
set /a tries+=1
if %tries% geq 24 (
  echo ERROR: Windows engine unavailable. Enable Windows containers in Docker Desktop and retry.
  pause
  exit /b 1
)
goto wait_win
:engine_ok

rem --- 3) Build (first run only) and start this version -------
echo [3/6] Starting Revit Server %VERSION% (Windows engine)...
docker --context %CTX% image inspect samples-rs%VERSION%:latest >nul 2>&1
if errorlevel 1 (
  echo       First run: building the image. This downloads ~5 GB and may take 20-45 min...
  docker --context %CTX% compose -f "%COMPOSE%" up -d --build
) else (
  echo       Image already built - starting container...
  docker --context %CTX% compose -f "%COMPOSE%" up -d
)
if errorlevel 1 (
  echo ERROR: docker compose failed. See the output above.
  pause
  exit /b 1
)

rem --- 4) Ensure the reverse proxy on port 80 is up -----------
rem  Runs on the DEFAULT (Linux) engine - note: no --context here.
echo [4/6] Ensuring the reverse proxy (port 80) is up...
docker compose -f "%PROXY%" up -d
if errorlevel 1 (
  echo WARN: could not start the reverse proxy. Is port 80 free?
  echo       Direct fallback: http://localhost:%VERSION%/RevitServerAdmin%VERSION%/
)

rem --- 5) Wait for the admin page (via the proxy) ------------
echo [5/6] Waiting for the admin web page (via proxy)...
powershell -NoProfile -Command "$u='%ADMIN%'; for($i=0;$i -lt 60;$i++){ try{ if((Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200){ exit 0 } }catch{}; Start-Sleep 5 }; exit 1"
if errorlevel 1 (
  echo       Server started, but the admin page is not responding yet.
  echo       Give it another minute and open %ADMIN% manually.
) else (
  echo       Admin page is ready.
)

rem --- 6) Open the admin page --------------------------------
echo [6/6] Opening the admin page...
start "" "%ADMIN%"

echo.
echo ============================================================
echo  Revit Server %VERSION% is running.
echo  Admin (via proxy):  %ADMIN%
echo  Models:             %DATADIR%
echo.
echo  In Revit, connect by this machine's NAME or IP, with NO port.
echo  Multiple versions can run at once - the proxy routes each
echo  Revit version by the year in its URL path.
echo.
echo  Stop this version:  docker --context %CTX% compose -f "%COMPOSE%" stop
echo  Remove (keep data): docker --context %CTX% compose -f "%COMPOSE%" down
echo  Stop the proxy:     docker compose -f "%PROXY%" down
echo ============================================================
echo.
pause
endlocal
