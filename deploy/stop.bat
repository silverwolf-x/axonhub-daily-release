@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM AxonHub Windows wrapper: runs stop.ps1 next to this file.
REM The whole body is one parenthesized block so cmd parses it once up front:
REM upgrade.bat may be overwritten by the upgrade while it is still running.
REM The window stays open when started by double-click (cmd /c "...\stop.bat");
REM set AXONHUB_NO_PAUSE=1 to disable that.
(
  set "AXONHUB_PAUSE="
  set "AXONHUB_CMDLINE=!cmdcmdline!"
  set "AXONHUB_CMDREST=!AXONHUB_CMDLINE:%~nx0=!"
  if not defined AXONHUB_NO_PAUSE if /i not "!AXONHUB_CMDREST!"=="!AXONHUB_CMDLINE!" set "AXONHUB_PAUSE=1"
  where powershell >nul 2>nul
  if errorlevel 1 (
    echo [ERROR] PowerShell is required to run this script.
    set "AXONHUB_RC=1"
  ) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dpn0.ps1" %*
    set "AXONHUB_RC=!ERRORLEVEL!"
  )
  if defined AXONHUB_PAUSE (
    echo.
    pause
  )
  exit /b !AXONHUB_RC!
)
