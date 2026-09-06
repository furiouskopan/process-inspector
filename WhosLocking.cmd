@echo off
:: Drag a file, folder or .exe onto this .cmd (or double-click it and type a path).
:: Shows which processes are holding it open.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WhosLocking.ps1" %*
echo.
pause
