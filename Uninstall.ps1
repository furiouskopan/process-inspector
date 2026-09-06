<#
  Removes Process Inspector for the current user: shortcuts, autostart, right-click menu,
  the Settings > Apps entry, and the program folder.
#>
param([switch]$Silent)

$ErrorActionPreference = 'SilentlyContinue'
$AppName = 'Process Inspector'
$Dest    = Join-Path $env:LOCALAPPDATA 'Programs\ProcessInspector'

if (-not $Silent) {
    Add-Type -AssemblyName PresentationFramework
    $ans = [System.Windows.MessageBox]::Show("Remove $AppName from this computer?", 'Uninstall', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { exit 1 }
}

Get-Process -Name ProcessInspector | Stop-Process -Force
Start-Sleep -Milliseconds 500

Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop'))  "$AppName.lnk") -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk") -Force
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ProcessInspector'
foreach ($k in 'HKCU:\Software\Classes\*\shell\WhosLocking','HKCU:\Software\Classes\Directory\shell\WhosLocking','HKCU:\Software\Classes\Drive\shell\WhosLocking') {
    Remove-Item $k -Recurse -Force
}
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ProcessInspector' -Recurse -Force

# The folder contains this script, so delete it after we exit.
Start-Process -FilePath 'cmd.exe' -ArgumentList "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"$Dest`"" -WindowStyle Hidden

if (-not $Silent) { [System.Windows.MessageBox]::Show("$AppName has been removed.", 'Uninstall', 'OK', 'Information') | Out-Null }
exit 0
