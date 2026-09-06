<#
.SYNOPSIS
  Lists the files each process currently has open (command-line version).

.EXAMPLE
  .\OpenFiles.ps1                      # every process, every open file
  .\OpenFiles.ps1 -Pid 11808           # one process
  .\OpenFiles.ps1 -Name sqlservr       # processes whose name contains "sqlservr"
  .\OpenFiles.ps1 -File "KNI_EKO"      # only files whose path contains this text
  .\OpenFiles.ps1 -Modules             # also list loaded DLL/EXE files
  .\OpenFiles.ps1 -Csv out.csv

.NOTES
  Run as Administrator to see files held by services and other users' processes.
#>
[CmdletBinding()]
param(
    [Alias('Pid')][int]$ProcessId = -1,
    [string]$Name,
    [string]$File,
    [switch]$Modules,
    [string]$Csv
)

$ErrorActionPreference = 'Stop'
if (-not ('WhosLocking.HandleEnum' -as [type])) {
    $dll = Join-Path $PSScriptRoot 'ProcessInspector.Native.dll'
    if (Test-Path $dll) { Add-Type -AssemblyName PresentationCore, WindowsBase; Add-Type -Path $dll }
    else { Add-Type -Path (Join-Path $PSScriptRoot 'HandleEnum.cs') }
}

$names = @{}
Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $names[[int]$_.Id] = $_.ProcessName }

$targetPid = $ProcessId
if ($Name) {
    $matches_ = @($names.GetEnumerator() | Where-Object { $_.Value -like "*$Name*" })
    if ($matches_.Count -eq 0) { Write-Error "No process matches '$Name'."; exit 1 }
}

Write-Host "Scanning open handles..." -ForegroundColor Cyan
$rows = New-Object System.Collections.Generic.List[object]
foreach ($f in [WhosLocking.HandleEnum]::GetFiles($targetPid)) {
    $pn = $names[$f.Pid]
    if ($Name -and $pn -notlike "*$Name*") { continue }
    $rows.Add([pscustomobject]@{ PID = $f.Pid; Process = $pn; Kind = 'Open file'; File = $f.Path })
}
if ($Modules) {
    $pids = if ($targetPid -ge 0) { @($targetPid) } elseif ($Name) { $matches_ | ForEach-Object { $_.Key } } else { $names.Keys }
    foreach ($p in $pids) {
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        try { foreach ($m in $proc.Modules) { $rows.Add([pscustomobject]@{ PID = $p; Process = $proc.ProcessName; Kind = 'Loaded DLL/EXE'; File = $m.FileName }) } } catch {}
    }
}
if ($File) { $rows = @($rows | Where-Object { $_.File -like "*$File*" }) }

$rows = @($rows | Sort-Object Process, PID, Kind, File)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "$($rows.Count) file(s) across $(@($rows | Select-Object -ExpandProperty PID -Unique).Count) process(es)" -ForegroundColor Cyan
if (-not $isAdmin) { Write-Host "(not elevated: files held by services / other users are not visible)" -ForegroundColor DarkGray }

if ($Csv) { $rows | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8; Write-Host "Saved to $Csv" -ForegroundColor Green }
$rows | Format-Table PID, Process, Kind, File -AutoSize | Out-String -Width 250 | Write-Host
