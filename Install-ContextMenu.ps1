<#
  Adds a "Who's locking this?" entry to the right-click menu of files, folders
  and drives (current user only - no admin needed).
  Run with -Uninstall to remove it again.
#>
param([switch]$Uninstall)

$script = Join-Path $PSScriptRoot 'ProcessInspector.ps1'
$label  = "Who's locking this?"
$cmd    = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Path `"%1`""

$keys = @(
    'HKCU:\Software\Classes\*\shell\WhosLocking',
    'HKCU:\Software\Classes\Directory\shell\WhosLocking',
    'HKCU:\Software\Classes\Drive\shell\WhosLocking'
)

foreach ($k in $keys) {
    if ($Uninstall) {
        if (Test-Path $k) { Remove-Item $k -Recurse -Force; Write-Host "Removed $k" }
        continue
    }
    New-Item -Path "$k\command" -Force | Out-Null
    Set-ItemProperty -Path $k -Name '(default)' -Value $label
    Set-ItemProperty -Path $k -Name 'Icon' -Value 'imageres.dll,-5302'
    Set-ItemProperty -Path "$k\command" -Name '(default)' -Value $cmd
    Write-Host "Added $k"
}

if ($Uninstall) { Write-Host "Context menu entry removed." }
else { Write-Host "`nDone. Right-click any file or folder -> `"$label`"" }
