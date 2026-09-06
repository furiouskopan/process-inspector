@echo off
:: Double-click: opens a searchable window listing every process and what it is used by.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ListProcesses.ps1" -Grid
