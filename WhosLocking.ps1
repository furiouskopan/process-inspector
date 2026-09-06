<#
.SYNOPSIS
  Shows which processes are holding a file, folder, or program open.

.DESCRIPTION
  Uses the Windows Restart Manager API (built into Windows, no downloads).
  It catches both "file is open" and "exe/dll is loaded by a process" cases,
  which is what causes "cannot close/delete, in use by another process".

.EXAMPLE
  .\WhosLocking.ps1 "C:\Program Files\SomeApp\app.exe"
  .\WhosLocking.ps1 "C:\Some\Folder"
  .\WhosLocking.ps1 "C:\file.pdf" -Kill      # asks before killing each process

.NOTES
  Run from an elevated (Administrator) window to see system / other-user processes.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path,
    [switch]$Kill,
    [switch]$Force        # with -Kill: no per-process confirmation
)

$ErrorActionPreference = 'Stop'

if (-not $Path -or $Path.Count -eq 0) {
    $in = Read-Host 'Enter the path of the file, folder or program that is "in use"'
    if ([string]::IsNullOrWhiteSpace($in)) { exit 1 }
    $Path = @($in.Trim('"'))
}

# ---- Restart Manager P/Invoke -------------------------------------------------
if (-not ('WhosLocking.RestartManager' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WhosLocking {
public static class RestartManager {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string strServiceShortName;
        public int  ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    public class Locker {
        public int    Pid;
        public string AppName;
        public string ServiceName;
        public int    AppType;
    }

    public static List<Locker> Find(string[] files) {
        var result = new List<Locker>();
        uint session;
        int rc = RmStartSession(out session, 0, Guid.NewGuid().ToString("N"));
        if (rc != 0) throw new Exception("RmStartSession failed (" + rc + ")");
        try {
            rc = RmRegisterResources(session, (uint)files.Length, files, 0, null, 0, null);
            if (rc != 0) throw new Exception("RmRegisterResources failed (" + rc + ")");

            uint needed = 0, count = 0, reasons = 0;
            rc = RmGetList(session, out needed, ref count, null, ref reasons);
            while (rc == 234 /* ERROR_MORE_DATA */) {
                var buf = new RM_PROCESS_INFO[needed];
                count = needed;
                rc = RmGetList(session, out needed, ref count, buf, ref reasons);
                if (rc == 0) {
                    for (int i = 0; i < count; i++)
                        result.Add(new Locker {
                            Pid = buf[i].Process.dwProcessId,
                            AppName = buf[i].strAppName,
                            ServiceName = buf[i].strServiceShortName,
                            AppType = buf[i].ApplicationType });
                }
            }
            if (rc != 0) throw new Exception("RmGetList failed (" + rc + ")");
        } finally { RmEndSession(session); }
        return result;
    }
}
}
'@
}

# ---- Collect the files to check ----------------------------------------------
$files = New-Object System.Collections.Generic.List[string]
foreach ($p in $Path) {
    $p = $p.Trim('"')
    if (-not (Test-Path -LiteralPath $p)) { Write-Warning "Not found: $p"; continue }
    $item = Get-Item -LiteralPath $p -Force
    if ($item.PSIsContainer) {
        Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $files.Add($_.FullName) }
    } else {
        $files.Add($item.FullName)
    }
}
if ($files.Count -eq 0) { Write-Error 'Nothing to check.'; exit 1 }

Write-Host ""
Write-Host "Checking $($files.Count) file(s) under: $($Path -join ', ')" -ForegroundColor Cyan

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Restart Manager copes with large lists but batch to keep it responsive.
$lockers = @{}
$batchSize = 500
try {
    for ($i = 0; $i -lt $files.Count; $i += $batchSize) {
        $end = [Math]::Min($i + $batchSize, $files.Count) - 1
        $batch = [string[]]$files[$i..$end]
        foreach ($l in [WhosLocking.RestartManager]::Find($batch)) {
            if (-not $lockers.ContainsKey($l.Pid)) { $lockers[$l.Pid] = $l }
        }
    }
} catch {
    $msg = $_.Exception.Message
    if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
    if ($msg -match '\(5\)' -and -not $isAdmin) {
        # ERROR_ACCESS_DENIED: the holder is a service / another user's process.
        # Relaunch ourselves elevated with the same arguments.
        Write-Host ""
        Write-Host "Access denied - the file is held by a service or another user's process." -ForegroundColor Yellow
        Write-Host "Relaunching as Administrator (accept the UAC prompt)..." -ForegroundColor Yellow
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath))
        foreach ($p in $Path) { $argList += ('"{0}"' -f $p) }
        if ($Kill)  { $argList += '-Kill' }
        if ($Force) { $argList += '-Force' }
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
        } catch {
            Write-Host "Elevation was cancelled. Re-run this tool from an Administrator window." -ForegroundColor Red
            exit 5
        }
        exit 0
    }
    throw
}

if ($lockers.Count -eq 0) {
    Write-Host "No process is currently holding it open." -ForegroundColor Green
    if (-not $isAdmin) {
        Write-Host "(If you still get 'in use', re-run as Administrator - system processes are hidden otherwise.)" -ForegroundColor DarkGray
    }
    exit 0
}

$typeNames = @{ 0='Unknown'; 1='App'; 2='App (no window)'; 3='Service'; 4='Explorer'; 5='Console'; 1000='Critical' }

$rows = foreach ($l in $lockers.Values) {
    $proc = Get-Process -Id $l.Pid -ErrorAction SilentlyContinue
    $exe  = $null; $started = $null
    if ($proc) {
        try { $exe = $proc.Path } catch {}
        try { $started = $proc.StartTime } catch {}
    }
    [pscustomobject]@{
        PID         = $l.Pid
        Process     = if ($proc) { $proc.ProcessName } else { '(exited)' }
        Description = $l.AppName
        Type        = if ($l.ServiceName) { "Service ($($l.ServiceName))" } else { $typeNames[$l.AppType] }
        Started     = $started
        Path        = $exe
    }
}

Write-Host ""
Write-Host "Held open by $(@($rows).Count) process(es):" -ForegroundColor Yellow
$rows | Sort-Object PID | Format-Table PID, Process, Description, Type, Started, Path -AutoSize -Wrap | Out-String -Width 220 | Write-Host

if (-not $isAdmin) {
    Write-Host "Tip: run as Administrator to also see system / other-user processes." -ForegroundColor DarkGray
}

# ---- Optional kill ------------------------------------------------------------
if ($Kill) {
    Write-Host ""
    foreach ($r in ($rows | Sort-Object PID)) {
        if ($r.Process -eq '(exited)') { continue }
        if ($r.Type -like 'Critical*' -or $r.Process -in @('csrss','wininit','winlogon','smss','services','lsass','System')) {
            Write-Host "Skipping critical system process $($r.Process) [$($r.PID)]" -ForegroundColor Red
            continue
        }
        $do = [bool]$Force
        if (-not $do) {
            $ans = Read-Host "Kill $($r.Process) [$($r.PID)] ($($r.Description))? [y/N]"
            $do = $ans -match '^(y|yes)$'
        }
        if ($do) {
            try {
                if ($r.Type -like 'Service*') {
                    $svc = ($r.Type -replace '^Service \((.*)\)$', '$1')
                    Stop-Service -Name $svc -Force -ErrorAction Stop
                    Write-Host "Stopped service $svc" -ForegroundColor Green
                } else {
                    Stop-Process -Id $r.PID -Force -ErrorAction Stop
                    Write-Host "Killed $($r.Process) [$($r.PID)]" -ForegroundColor Green
                }
            } catch {
                Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}
