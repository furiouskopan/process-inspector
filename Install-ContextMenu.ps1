<#
  Portable use only (the installer has this as an option): adds "Who's locking this?" to the
  right-click menu of files, folders and drives for the current user. -Uninstall removes it.
  Uses the .NET registry API because the "*" key name would be a wildcard to PowerShell.
#>
param([switch]$Uninstall)

$exe    = Join-Path $PSScriptRoot 'ProcessInspector.exe'
$script = Join-Path $PSScriptRoot 'ProcessInspector.ps1'
$icon   = Join-Path $PSScriptRoot 'app.ico'
$cmd    = if (Test-Path $exe) { "`"$exe`" -Path `"%1`"" }
          else { "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Path `"%1`"" }

$hkcu = [Microsoft.Win32.Registry]::CurrentUser
foreach ($k in 'Software\Classes\*\shell\WhosLocking','Software\Classes\Directory\shell\WhosLocking','Software\Classes\Drive\shell\WhosLocking') {
    if ($Uninstall) { $hkcu.DeleteSubKeyTree($k, $false); Write-Host "Removed HKCU\$k"; continue }
    $key = $hkcu.CreateSubKey($k)
    $key.SetValue('', "Who's locking this?")
    if (Test-Path $icon) { $key.SetValue('Icon', "`"$icon`"") }
    $c = $key.CreateSubKey('command'); $c.SetValue('', $cmd); $c.Close(); $key.Close()
    Write-Host "Added HKCU\$k"
}
if ($Uninstall) { Write-Host 'Context menu entry removed.' } else { Write-Host "`nDone. Right-click any file or folder -> `"Who's locking this?`"" }
