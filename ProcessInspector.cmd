@echo off
:: Double-click to open Process Inspector.
:: Drag a file/folder onto this .cmd to open straight on the "Who's locking" tab.
if "%~1"=="" (
  start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ProcessInspector.ps1"
) else (
  start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ProcessInspector.ps1" -Path "%~1"
)
