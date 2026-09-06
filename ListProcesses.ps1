<#
.SYNOPSIS
  Lists every running process and what it belongs to / is used by.

.DESCRIPTION
  For each process shows: PID, name, friendly description, company, the user
  account it runs as, the parent process that started it, the Windows services
  it hosts (e.g. which services live inside each svchost), memory, start time,
  and the exe path.

.EXAMPLE
  .\ListProcesses.ps1              # table in the console
  .\ListProcesses.ps1 -Grid        # searchable / sortable / filterable window
  .\ListProcesses.ps1 -Tree        # indented parent -> child tree
  .\ListProcesses.ps1 -Name sql    # only processes whose name/description/services match
  .\ListProcesses.ps1 -Csv out.csv # export

.NOTES
  Run as Administrator to see the path and user of system processes.
#>
[CmdletBinding()]
param(
    [string]$Name,        # filter: matches name, description, services or path
    [switch]$Grid,
    [switch]$Tree,
    [string]$Csv
)

$ErrorActionPreference = 'SilentlyContinue'

Write-Host "Collecting processes..." -ForegroundColor Cyan

# Fast process-owner lookup (the CIM GetOwner method is ~0.2 s per process).
if (-not ('WhosLocking.ProcUser' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WhosLocking {
public static class ProcUser {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr tok);
    public static string Get(int pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);      // PROCESS_QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) return null;
        try {
            IntPtr tok;
            if (!OpenProcessToken(h, 0x0008, out tok)) return null;   // TOKEN_QUERY
            try { using (var id = new System.Security.Principal.WindowsIdentity(tok)) return id.Name; }
            finally { CloseHandle(tok); }
        } finally { CloseHandle(h); }
    }
}
}
'@
}

# --- Raw data --------------------------------------------------------------
$cim   = Get-CimInstance Win32_Process
$procs = @{}
Get-Process | ForEach-Object { $procs[$_.Id] = $_ }

# services grouped by hosting PID
$svcByPid = @{}
foreach ($s in (Get-CimInstance Win32_Service | Where-Object { $_.ProcessId -gt 0 })) {
    if (-not $svcByPid.ContainsKey([int]$s.ProcessId)) { $svcByPid[[int]$s.ProcessId] = New-Object System.Collections.Generic.List[string] }
    $label = if ($s.DisplayName -and $s.DisplayName -ne $s.Name) { "$($s.Name) ($($s.DisplayName))" } else { $s.Name }
    $svcByPid[[int]$s.ProcessId].Add($label)
}

$nameByPid = @{}
foreach ($c in $cim) { $nameByPid[[int]$c.ProcessId] = $c.Name }

# --- Build rows ------------------------------------------------------------
$rows = foreach ($c in $cim) {
    $pid_ = [int]$c.ProcessId
    $p    = $procs[$pid_]

    $owner = [WhosLocking.ProcUser]::Get($pid_)

    $parentPid  = [int]$c.ParentProcessId
    $parentName = $nameByPid[$parentPid]
    $parent = if ($parentName) { "$parentName ($parentPid)" }
              elseif ($parentPid -gt 0) { "(exited) ($parentPid)" }
              else { '' }

    $services = if ($svcByPid.ContainsKey($pid_)) { $svcByPid[$pid_] -join ', ' } else { '' }

    $desc = $null; $company = $null; $path = $c.ExecutablePath
    if ($p) {
        try { $desc    = $p.MainModule.FileVersionInfo.FileDescription } catch {}
        try { $company = $p.MainModule.FileVersionInfo.CompanyName } catch {}
        if (-not $path) { try { $path = $p.Path } catch {} }
    }
    if (-not $desc) { $desc = $c.Description }

    # What is this process "used by"?  Services it hosts, else its parent.
    $usedBy = if ($services) { "Hosts: $services" }
              elseif ($parent) { "Started by: $parent" }
              else { '' }

    [pscustomobject]@{
        PID         = $pid_
        Name        = $c.Name
        Description = $desc
        Company     = $company
        User        = $owner
        Parent      = $parent
        ParentPID   = $parentPid
        Services    = $services
        UsedBy      = $usedBy
        MemoryMB    = [math]::Round($c.WorkingSetSize / 1MB, 1)
        Started     = if ($c.CreationDate) { $c.CreationDate } else { $null }
        Path        = $path
        CommandLine = $c.CommandLine
    }
}

# --- Filter ------------------------------------------------------------------
if ($Name) {
    $rows = $rows | Where-Object {
        $_.Name -like "*$Name*" -or $_.Description -like "*$Name*" -or
        $_.Services -like "*$Name*" -or $_.Path -like "*$Name*"
    }
}

$rows = @($rows | Sort-Object Name, PID)
Write-Host "$($rows.Count) process(es)" -ForegroundColor Cyan

# --- Output ------------------------------------------------------------------
if ($Csv) {
    $rows | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
    Write-Host "Saved to $Csv" -ForegroundColor Green
}

if ($Grid) {
    $rows | Select-Object PID, Name, Description, User, UsedBy, Parent, Services, MemoryMB, Started, Path, CommandLine |
        Out-GridView -Title "Running processes - what they are used by (type in the filter box to search)"
    return
}

if ($Tree) {
    $byParent = @{}
    $ids = @{}
    foreach ($r in $rows) { $ids[$r.PID] = $true }
    foreach ($r in $rows) {
        $k = if ($ids.ContainsKey($r.ParentPID) -and $r.ParentPID -ne $r.PID) { $r.ParentPID } else { -1 }
        if (-not $byParent.ContainsKey($k)) { $byParent[$k] = New-Object System.Collections.Generic.List[object] }
        $byParent[$k].Add($r)
    }
    function Show-Node($r, $depth) {
        $indent = '  ' * $depth
        $extra = if ($r.Services) { "  [hosts: $($r.Services)]" } elseif ($r.Description -and $r.Description -ne $r.Name) { "  - $($r.Description)" } else { '' }
        $user = if ($r.User) { "  <$($r.User)>" } else { '' }
        Write-Host ("{0}{1} ({2}){3}{4}" -f $indent, $r.Name, $r.PID, $user, $extra)
        if ($byParent.ContainsKey($r.PID)) {
            foreach ($child in ($byParent[$r.PID] | Sort-Object Name)) { Show-Node $child ($depth + 1) }
        }
    }
    foreach ($root in ($byParent[-1] | Sort-Object Name)) { Show-Node $root 0 }
    return
}

$rows | Format-Table PID, Name, Description, User, UsedBy, MemoryMB, Path -AutoSize -Wrap |
    Out-String -Width 250 | Write-Host
