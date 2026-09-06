<#
.SYNOPSIS
  Process Inspector - a window with three tabs:
    1. Processes        : every running process, who it runs as, what started it,
                          which services it hosts, which files it has open.
    2. Open files       : every file every process has open, searchable.
    3. Who's locking?   : pick / drop a file or folder and see which processes hold
                          it open. End the process or stop the service from there.
  Only one copy runs at a time; starting it again brings the running window to the front.

.EXAMPLE
  .\ProcessInspector.ps1
  .\ProcessInspector.ps1 -Path "C:\some\locked\file.mdf"     # opens on the lock tab
  .\ProcessInspector.ps1 -Tray                                # start hidden in the tray
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$Tray,        # start hidden in the system tray (used by "start automatically")
    [switch]$Show,        # with -Tray: show the window immediately but keep tray behaviour
    [switch]$SelfTest,    # build everything, run the data functions, exit (no window shown)
    [string]$Screenshot,  # with -SelfTest: render the window to this PNG file
    [int]$ShowTab = -1,   # with -Screenshot: which tab to show
    [switch]$Dark         # with -Screenshot: render in the dark theme
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:AppRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ExePath = $env:PROCESS_INSPECTOR_EXE          # set by ProcessInspector.exe when hosting this script
$script:AppVersion = '1.2.1'
$script:RepoOwner  = 'furiouskopan'          # used by "Check for updates"
$script:RepoName   = 'process-inspector'
$script:CpuPrev       = @{}    # pid -> @{Cpu; Io; Time}  for the CPU % / Disk columns
$script:PrevRows      = @{}    # pid -> ProcRow           for New / Exited highlighting
$script:SignerCache   = @{}    # exe path -> signer text
$script:PathInfoCache = @{}    # exe path -> @{Desc; Company}   (never changes while the file exists)
$script:UserCache     = @{}    # "pid|created" -> user account
$script:IconCache     = @{}    # exe path -> 16px ImageSource
$script:SvcCache      = $null; $script:SvcCacheTime = [datetime]::MinValue

# ---- Single instance: if a copy is already running, hand it our request and quit ----
$script:IpcSuffix = if ($IsAdmin) { '.admin' } else { '' }
$script:IpcDir    = Join-Path $env:LOCALAPPDATA 'ProcessInspector'
$script:IpcFile   = Join-Path $IpcDir 'activate.txt'
$script:Mutex     = $null
if (-not $SelfTest) {
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, "Local\ProcessInspector.Instance$IpcSuffix", [ref]$created)
    if (-not $created) {
        try {
            New-Item -ItemType Directory -Force -Path $IpcDir | Out-Null
            $mode = if ($Tray -and -not $Show -and -not $Path) { 'silent' } else { 'show' }
            [IO.File]::WriteAllLines($IpcFile, [string[]]@($mode, [string]$Path))
            $evt = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', "Local\ProcessInspector.Activate$IpcSuffix")
            $evt.Set() | Out-Null
            $evt.Dispose()
        } catch {}
        $global:ProcessInspectorExited = $true
        return
    }
}

# =============================================================================
# Native helpers + row types
# =============================================================================
# Prebuilt DLL when available (fast start); otherwise compile the sources on the fly.
$script:NativeDll = Join-Path $AppRoot 'ProcessInspector.Native.dll'
if (-not ('WhosLocking.RestartManager' -as [type])) {
    if (Test-Path $NativeDll) {
        Add-Type -Path $NativeDll
    } else {
        $wpfRefs = @([System.Windows.Media.ImageSource].Assembly.Location, [System.Windows.DependencyObject].Assembly.Location, [System.Uri].Assembly.Location)
        Add-Type -Path (Join-Path $AppRoot 'Native.cs'), (Join-Path $AppRoot 'HandleEnum.cs'), (Join-Path $AppRoot 'SysMetrics.cs') -ReferencedAssemblies $wpfRefs
    }
}


# 16 px icon of an exe, cached per path (null when it cannot be read).
function Get-ExeIcon([string]$path) {
    if (-not $path) { return $null }
    if ($IconCache.ContainsKey($path)) { return $IconCache[$path] }
    $bmp = $null
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($path)
        if ($ico) {
            $bmp = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty,
                     [System.Windows.Media.Imaging.BitmapSizeOptions]::FromWidthAndHeight(16, 16))
            $bmp.Freeze()
            $ico.Dispose()
        }
    } catch { $bmp = $null }
    $IconCache[$path] = $bmp
    return $bmp
}

# =============================================================================
# Data functions
# =============================================================================
function Get-ProcessRows([switch]$KeepExited) {
    # only the properties we use: measurably faster than the full instance
    $cim   = Get-CimInstance -ClassName Win32_Process -Property ProcessId, Name, ParentProcessId, ExecutablePath, CommandLine,
                 CreationDate, WorkingSetSize, ThreadCount, HandleCount, ReadTransferCount, WriteTransferCount
    $now   = Get-Date
    $cores = [Environment]::ProcessorCount
    $cpuNow = @{}; $liveRows = @{}
    $procs = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procs[$_.Id] = $_ }

    # which service lives in which process changes rarely: re-read every 15 s only
    if (-not $script:SvcCache -or ($now - $script:SvcCacheTime).TotalSeconds -gt 15) {
        $m = @{}
        foreach ($s in (Get-CimInstance Win32_Service | Where-Object { $_.ProcessId -gt 0 })) {
            $k = [int]$s.ProcessId
            if (-not $m.ContainsKey($k)) { $m[$k] = @() }
            $m[$k] += ,$s
        }
        $script:SvcCache = $m; $script:SvcCacheTime = $now
    }
    $svcByPid = $script:SvcCache
    $nameByPid = @{}
    foreach ($c in $cim) { $nameByPid[[int]$c.ProcessId] = $c.Name }

    $list = New-Object 'System.Collections.Generic.List[WhosLocking.ProcRow]'
    foreach ($c in $cim) {
        $pid_ = [int]$c.ProcessId
        $p    = $procs[$pid_]
        $r    = New-Object WhosLocking.ProcRow
        $r.PID  = $pid_
        $r.Name = $c.Name
        $userKey = "$pid_|$($c.CreationDate)"
        if ($UserCache.ContainsKey($userKey)) { $r.User = $UserCache[$userKey] }
        else { $r.User = [WhosLocking.ProcUser]::Get($pid_); if ($r.User) { $UserCache[$userKey] = $r.User } }
        if (-not $r.User) { $r.User = '(unknown)' }
        $r.ParentPID = [int]$c.ParentProcessId
        $pn = $nameByPid[$r.ParentPID]
        $r.Parent = if ($pn) { "$pn ($($r.ParentPID))" } elseif ($r.ParentPID -gt 0) { "(exited) ($($r.ParentPID))" } else { '' }
        if ($svcByPid.ContainsKey($pid_)) {
            $svcs = $svcByPid[$pid_]
            $r.ServiceNames = ($svcs | ForEach-Object { $_.Name }) -join ','
            $r.Services = ($svcs | ForEach-Object {
                if ($_.DisplayName -and $_.DisplayName -ne $_.Name) { "$($_.Name) ($($_.DisplayName))" } else { $_.Name } }) -join ', '
        }
        $r.Path = $c.ExecutablePath
        if (-not $r.Path -and $p) { try { $r.Path = $p.Path } catch {} }
        if ($r.Path) {
            if (-not $PathInfoCache.ContainsKey($r.Path)) {
                $info = @{ Desc = ''; Company = '' }
                try { $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($r.Path); $info.Desc = $fvi.FileDescription; $info.Company = $fvi.CompanyName } catch {}
                $PathInfoCache[$r.Path] = $info
            }
            $r.Description = $PathInfoCache[$r.Path].Desc
            $r.Company     = $PathInfoCache[$r.Path].Company
            $r.Icon        = Get-ExeIcon $r.Path
        } else {
            $r.Signer = '(unknown)'          # no path = no signature check possible (usually needs Administrator)
        }
        if (-not $r.Description) { $r.Description = '' }
        $r.UsedBy = if ($r.Services) { "Hosts service: $($r.Services)" } elseif ($r.Parent) { "Started by: $($r.Parent)" } else { '' }
        $r.MemoryMB = [math]::Round($c.WorkingSetSize / 1MB, 1)
        $r.Threads  = [int]$c.ThreadCount
        $r.Handles  = [int]$c.HandleCount
        if ($c.CreationDate) { $r.Started = $c.CreationDate }
        $r.CommandLine = $c.CommandLine
        # CPU % and disk KB/s since the previous refresh
        $cpuMs = $null
        if ($p) { try { $cpuMs = $p.TotalProcessorTime.TotalMilliseconds } catch {} }
        $io = [double]($c.ReadTransferCount + $c.WriteTransferCount)
        if ($script:CpuPrev.ContainsKey($pid_)) {
            $prev = $script:CpuPrev[$pid_]
            $wall = ($now - $prev.Time).TotalMilliseconds
            if ($wall -gt 0) {
                if ($null -ne $cpuMs -and $null -ne $prev.Cpu) {
                    $r.CpuPercent = [math]::Round([math]::Max(0, ($cpuMs - $prev.Cpu) / $wall / $cores * 100), 1)
                }
                $r.DiskKBs = [math]::Round([math]::Max(0, ($io - $prev.Io) / $wall / 1.024), 1)   # bytes/ms -> KB/s
            }
        }
        $cpuNow[$pid_] = @{ Cpu = $cpuMs; Io = $io; Time = $now }
        if ($script:PrevRows.Count -gt 0 -and -not $script:PrevRows.ContainsKey($pid_)) { $r.Status = 'New' }
        if ($r.Path -and $script:SignerCache.ContainsKey($r.Path)) { $r.Signer = $script:SignerCache[$r.Path] }
        $list.Add($r)
        $liveRows[$pid_] = $r
    }
    # processes that disappeared since the previous refresh: shown once more, greyed out, but only in
    # the live (auto-refresh) view - after a manual refresh or an End process they must be gone
    if ($KeepExited) {
        foreach ($k in $script:PrevRows.Keys) {
            if (-not $liveRows.ContainsKey($k)) {
                $old = $script:PrevRows[$k]
                $old.Status = 'Exited'; $old.CpuPercent = 0; $old.DiskKBs = 0
                $list.Add($old)
            }
        }
    }
    $script:PrevRows = $liveRows
    $script:CpuPrev  = $cpuNow
    # Process objects hold a kernel handle each once touched: release them now instead of at GC time
    foreach ($x in $procs.Values) { try { $x.Dispose() } catch {} }
    return ,$list
}

function Get-FilesUnder([string]$p) {
    $p = $p.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $p)) { throw "Not found: $p" }
    $item = Get-Item -LiteralPath $p -Force
    if ($item.PSIsContainer) {
        return @(Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    return @($item.FullName)
}

$typeNames = @{ 0='Unknown'; 1='App'; 2='App (no window)'; 3='Service'; 4='Explorer'; 5='Console'; 1000='Critical' }

# A lock-tab row for a PID, filled from the process list when we have it.
function New-LockRow([int]$pid_) {
    $proc = Get-Process -Id $pid_ -ErrorAction SilentlyContinue
    $r = New-Object WhosLocking.LockRow
    $r.PID  = $pid_
    $r.Name = if ($proc) { $proc.ProcessName } else { '(exited)' }
    $known = $null
    if ($script:AllProcs) { $known = $AllProcs | Where-Object { $_.PID -eq $pid_ } | Select-Object -First 1 }
    if ($known) {
        $r.Description = $known.Description
        $r.ServiceNames = $known.ServiceNames
        if ($known.ServiceNames) { $r.Type = "Service ($($known.ServiceNames))" }
        $r.Path = $known.Path
        if ($known.Started) { $r.Started = $known.Started }
    }
    if ($proc) {
        if (-not $r.Path)    { try { $r.Path = $proc.Path } catch {} }
        if (-not $r.Started) { try { $r.Started = $proc.StartTime } catch {} }
    }
    if ($r.Path -and -not $r.Description) {
        try { $r.Description = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($r.Path).FileDescription } catch {}
    }
    $r.Icon = Get-ExeIcon $r.Path
    $r.User = [WhosLocking.ProcUser]::Get($pid_)
    if (-not $r.User) { $r.User = '(unknown)' }
    return $r
}

# Restart Manager: processes that have these files open or loaded as EXE/DLL.
function Find-LockRows([string[]]$files) {
    $list = New-Object 'System.Collections.Generic.List[WhosLocking.LockRow]'
    $files = @($files)
    if ($files.Count -eq 0) { return ,$list }
    $lockers = @{}
    $batch = 500
    for ($i = 0; $i -lt $files.Count; $i += $batch) {
        $end = [Math]::Min($i + $batch, $files.Count) - 1
        if ($files.Count -gt $batch) { Show-Status "Checking files $($i + 1)-$($end + 1) of $($files.Count)..." }
        foreach ($l in [WhosLocking.RestartManager]::Find([string[]]$files[$i..$end])) {
            if (-not $lockers.ContainsKey($l.Pid)) { $lockers[$l.Pid] = $l }
        }
    }
    foreach ($l in $lockers.Values) {
        $r = New-LockRow $l.Pid
        if ($l.AppName)     { $r.Description = $l.AppName }
        if ($l.ServiceName) { $r.ServiceNames = $l.ServiceName }
        $r.Type = if ($r.ServiceNames) { "Service ($($r.ServiceNames))" } else { $typeNames[$l.AppType] }
        if ($files.Count -eq 1) { $r.HeldItem = $files[0] }
        $list.Add($r)
    }
    return ,$list
}

# Handle scan: processes holding any open file whose path satisfies $match. Merges into $rows and
# records the handle values so they can be force-closed later. $dirBase (optional) marks a handle
# on the folder itself, which is what a console window's "current directory" looks like.
function Merge-HandleLocks($rows, [scriptblock]$match, [string]$dirBase) {
    $held = @{}; $handles = @{}
    foreach ($f in [WhosLocking.HandleEnum]::GetFiles(-1)) {
        if (-not (& $match $f.Path)) { continue }
        if (-not $held.ContainsKey($f.Pid)) {
            $held[$f.Pid]    = New-Object System.Collections.Generic.List[string]
            $handles[$f.Pid] = New-Object System.Collections.Generic.List[long]
        }
        if (-not $held[$f.Pid].Contains($f.Path)) { $held[$f.Pid].Add($f.Path) }
        $handles[$f.Pid].Add($f.Handle.ToInt64())
    }
    $byPid = @{}
    foreach ($r in $rows) { $byPid[$r.PID] = $r }
    foreach ($k in $held.Keys) {
        $items = $held[$k]
        $label = if ($items.Count -eq 1) { $items[0] } else { "$($items[0])  (+$($items.Count - 1) more)" }
        if ($byPid.ContainsKey($k)) {
            $r = $byPid[$k]
            if (-not $r.HeldItem) { $r.HeldItem = $label }
        } else {
            $r = New-LockRow $k
            if (-not $r.Type) {
                $r.Type = if ($dirBase -and ($items -contains $dirBase)) { 'Folder handle / working directory' } else { 'Open file handle' }
            }
            $r.HeldItem = $label
            $rows.Add($r)
        }
        $r.Handles.AddRange($handles[$k])
    }
    return ,$rows
}

# Files a process (or every process when $pid_ = -1) currently has open.
function Get-OpenFileRows([int]$pid_, [bool]$includeModules, [hashtable]$names) {
    $list = New-Object 'System.Collections.Generic.List[WhosLocking.FileRow]'
    foreach ($f in [WhosLocking.HandleEnum]::GetFiles($pid_)) {
        $name = $names[[int]$f.Pid]
        if (-not $name) {
            # started after the process list was loaded
            $gp = Get-Process -Id $f.Pid -ErrorAction SilentlyContinue
            $name = if ($gp) { $gp.ProcessName + '.exe' } else { "(pid $($f.Pid))" }
            $names[[int]$f.Pid] = $name
        }
        $r = New-Object WhosLocking.FileRow
        $r.PID = $f.Pid; $r.Process = $name; $r.Kind = 'Open file'; $r.File = $f.Path; $r.Handle = $f.Handle.ToInt64()
        $list.Add($r)
    }
    if ($includeModules) {
        $targets = if ($pid_ -ge 0) { @($pid_) } else { @($names.Keys) }
        foreach ($tp in $targets) {
            $p = Get-Process -Id $tp -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            try {
                foreach ($m in $p.Modules) {
                    $r = New-Object WhosLocking.FileRow
                    $r.PID = $tp; $r.Process = $p.ProcessName; $r.Kind = 'Loaded DLL/EXE'; $r.File = $m.FileName
                    $list.Add($r)
                }
            } catch {}
        }
    }
    return ,$list
}

$criticalNames = 'csrss','wininit','winlogon','smss','services','lsass','System','Idle','Registry','Memory Compression','svchost'

function Stop-Targets($items) {
    # $items: objects with PID, Name, ServiceNames (and Status for process rows)
    $items = @($items | Where-Object { $_ -and $_.Status -ne 'Exited' })
    if ($items.Count -eq 0) { Show-Status 'Nothing selected, or it has already exited.'; return $false }
    $desc = ($items | ForEach-Object {
        $s = "$($_.Name)  (PID $($_.PID))"
        if ($_.ServiceNames) { $s += "   -> will STOP service(s): $($_.ServiceNames)" }
        $s }) -join "`n"

    $wasAuto = $AutoTimer.IsEnabled; $AutoTimer.Stop()     # no list churn underneath the dialogs
    try {
        $ans = [System.Windows.MessageBox]::Show("End the following?`n`n$desc", 'Confirm', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return $false }

        $problems = @(); $denied = $false; $killed = @()
        foreach ($it in $items) {
            $base = [IO.Path]::GetFileNameWithoutExtension($it.Name)
            if ($criticalNames -contains $base -and -not $it.ServiceNames) {
                $problems += "Skipped critical system process $($it.Name) ($($it.PID)) - ending it would crash or lock Windows."; continue
            }
            try {
                if ($it.ServiceNames) {
                    $failed = @()
                    foreach ($svc in ($it.ServiceNames -split ',')) {
                        try { Stop-Service -Name $svc.Trim() -Force -ErrorAction Stop } catch { $failed += "$($svc.Trim()): $($_.Exception.Message)" }
                    }
                    if ($failed) {
                        $ans2 = [System.Windows.MessageBox]::Show(
                            "The service did not stop:`n$($failed -join "`n")`n`nForce-end the hosting process $($it.Name) (PID $($it.PID)) instead?`n(Any other service living in the same process ends too.)",
                            'Service refused to stop', 'YesNo', 'Warning')
                        if ($ans2 -ne 'Yes') { $problems += $failed; continue }
                        Stop-Process -Id $it.PID -Force -ErrorAction Stop
                    }
                } else {
                    Stop-Process -Id $it.PID -Force -ErrorAction Stop
                }
                $killed += [int]$it.PID
            } catch {
                $m = $_.Exception.Message
                if ($m -match 'denied|not permitted|privilege|Access') { $denied = $true }
                $problems += "$($it.Name) ($($it.PID)): $m"
            }
        }

        # wait until they are really gone (up to 3 s), so the list does not show them as still running
        if ($killed.Count) {
            Show-Status 'Waiting for the process to exit...'
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 3 -and @($killed | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count) { Start-Sleep -Milliseconds 150 }
            foreach ($k in $killed) {
                if (Get-Process -Id $k -ErrorAction SilentlyContinue) { $problems += "PID $k is still running 3 s after being told to end. It is protected, or a parent process restarted it." }
                $script:PrevRows.Remove($k)          # never show it as a lingering red row
            }
        }

        if ($problems) {
            $text = $problems -join "`n"
            if ($denied -and -not $IsAdmin) {
                $ans3 = [System.Windows.MessageBox]::Show("$text`n`nWindows refused: the process belongs to another user or runs elevated. Restart Process Inspector as Administrator and try again?",
                    'Access denied', 'YesNo', 'Warning')
                if ($ans3 -eq 'Yes') { Restart-Elevated $ui.txtPath.Text; return $true }
            } else {
                [System.Windows.MessageBox]::Show($text, 'Some items could not be ended', 'OK', 'Warning') | Out-Null
            }
        } elseif ($killed.Count) {
            Show-Status "Ended: $(($items | ForEach-Object { $_.Name }) -join ', ')"
        }
        return $true
    } finally {
        if ($wasAuto -and $ui.chkAutoRefresh.IsChecked -and -not $Exiting) { $AutoTimer.Start() }
    }
}

function Restart-Elevated([string]$prefill) {
    if ($ExePath) {
        $file = $ExePath
        $argList = @()
    } else {
        $file = 'powershell.exe'
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', ('"{0}"' -f $PSCommandPath))
    }
    if ($prefill) { $argList += '-Path'; $argList += ('"{0}"' -f $prefill) }
    try {
        if ($argList.Count) { Start-Process -FilePath $file -Verb RunAs -ArgumentList $argList | Out-Null }
        else                { Start-Process -FilePath $file -Verb RunAs | Out-Null }
        $script:Exiting = $true
        $script:window.Close()
    } catch {
        Show-Status 'Elevation cancelled.'
    }
}

# =============================================================================
# UI
# =============================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Process Inspector" Width="1250" Height="760" MinWidth="800" MinHeight="500"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12" Background="{DynamicResource BgBrush}">
  <Window.Resources>
    <!-- theme brushes; Set-Theme swaps them at run time -->
    <SolidColorBrush x:Key="BgBrush"        Color="#F3F3F3"/>
    <SolidColorBrush x:Key="PanelBrush"     Color="#FFFFFF"/>
    <SolidColorBrush x:Key="AltRowBrush"    Color="#F7F9FC"/>
    <SolidColorBrush x:Key="HeaderBrush"    Color="#EDEDED"/>
    <SolidColorBrush x:Key="LineBrush"      Color="#CCCCCC"/>
    <SolidColorBrush x:Key="GridLineBrush"  Color="#E3E3E3"/>
    <SolidColorBrush x:Key="TextBrush"      Color="#1B1B1B"/>
    <SolidColorBrush x:Key="MutedBrush"     Color="#666666"/>
    <SolidColorBrush x:Key="StatusBrush"    Color="#E8E8E8"/>
    <SolidColorBrush x:Key="NewRowBrush"    Color="#DDF5DD"/>
    <SolidColorBrush x:Key="ExitedRowBrush" Color="#F9DADA"/>
    <SolidColorBrush x:Key="ButtonBrush"    Color="#E6E6E6"/>
    <SolidColorBrush x:Key="AccentBrush"    Color="#2F7BD9"/>
    <SolidColorBrush x:Key="Accent2Brush"   Color="#E08A2E"/>
    <SolidColorBrush x:Key="ChartFillBrush" Color="#332F7BD9"/>

    <!-- one live-metric tile: title, value and a sparkline -->
    <Style x:Key="Tile" TargetType="Border">
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Padding" Value="8,4,8,5"/>
      <Setter Property="Background" Value="{DynamicResource BgBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="3"/>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="MinWidth" Value="90"/>
      <Setter Property="Background" Value="{DynamicResource ButtonBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Background" Value="{DynamicResource PanelBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="{DynamicResource BgBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" Background="{DynamicResource HeaderBrush}" BorderBrush="{DynamicResource LineBrush}"
                    BorderThickness="1,1,1,0" Margin="0,2,-1,0" Padding="14,5">
              <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource BgBrush}"/>
                <Setter TargetName="bd" Property="Margin" Value="0,0,-1,-1"/>
                <Setter TargetName="bd" Property="Padding" Value="14,6,14,7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource GridLineBrush}"/>
      <Setter Property="RowBackground" Value="{DynamicResource PanelBrush}"/>
      <Setter Property="AlternatingRowBackground" Value="{DynamicResource AltRowBrush}"/>
      <Setter Property="Background" Value="{DynamicResource PanelBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="RowHeaderWidth" Value="0"/>
      <Setter Property="SelectionMode" Value="Extended"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="RowHeight" Value="24"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Background" Value="{DynamicResource HeaderBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>
    <Style TargetType="DataGridCell" BasedOn="{StaticResource {x:Type DataGridCell}}">
      <Setter Property="Padding" Value="4,0"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
  </Window.Resources>

  <DockPanel TextElement.Foreground="{DynamicResource TextBrush}">
    <Border DockPanel.Dock="Bottom" Background="{DynamicResource StatusBrush}" Padding="8,3">
      <DockPanel>
        <Button x:Name="btnUpdates" DockPanel.Dock="Right" Content="Check for updates" MinWidth="0" Padding="8,2" FontSize="11"/>
        <CheckBox x:Name="chkDark" DockPanel.Dock="Right" Content="Dark theme" Margin="0,0,10,0"/>
        <CheckBox x:Name="chkMetrics" DockPanel.Dock="Right" Content="Live metrics" Margin="0,0,14,0" IsChecked="True"/>
        <TextBlock x:Name="txtStatus" Text="Ready" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>

    <!-- ================= live metrics strip ================= -->
    <Border x:Name="metricsBar" DockPanel.Dock="Top" Background="{DynamicResource PanelBrush}"
            BorderBrush="{DynamicResource LineBrush}" BorderThickness="0,0,0,1" Padding="10,6,2,5">
      <UniformGrid Rows="1" Columns="4">
        <Border Style="{StaticResource Tile}">
          <DockPanel>
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,3">
              <TextBlock Text="CPU" FontWeight="SemiBold"/>
              <TextBlock x:Name="mCpu" Text="--" HorizontalAlignment="Right" Foreground="{DynamicResource MutedBrush}"/>
            </DockPanel>
            <Canvas x:Name="cCpu" Height="30" ClipToBounds="True">
              <Polygon x:Name="fCpu" Fill="{DynamicResource ChartFillBrush}"/>
              <Polyline x:Name="lCpu" Stroke="{DynamicResource AccentBrush}" StrokeThickness="1.5"/>
            </Canvas>
          </DockPanel>
        </Border>
        <Border Style="{StaticResource Tile}">
          <DockPanel>
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,3">
              <TextBlock Text="Memory" FontWeight="SemiBold"/>
              <TextBlock x:Name="mMem" Text="--" HorizontalAlignment="Right" Foreground="{DynamicResource MutedBrush}"/>
            </DockPanel>
            <Canvas x:Name="cMem" Height="30" ClipToBounds="True">
              <Polygon x:Name="fMem" Fill="{DynamicResource ChartFillBrush}"/>
              <Polyline x:Name="lMem" Stroke="{DynamicResource AccentBrush}" StrokeThickness="1.5"/>
            </Canvas>
          </DockPanel>
        </Border>
        <Border Style="{StaticResource Tile}">
          <DockPanel>
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,3">
              <TextBlock Text="Disk" FontWeight="SemiBold"/>
              <TextBlock x:Name="mDisk" Text="--" HorizontalAlignment="Right" Foreground="{DynamicResource MutedBrush}"/>
            </DockPanel>
            <Canvas x:Name="cDisk" Height="30" ClipToBounds="True">
              <Polygon x:Name="fDisk" Fill="{DynamicResource ChartFillBrush}"/>
              <Polyline x:Name="lDisk" Stroke="{DynamicResource AccentBrush}" StrokeThickness="1.5"/>
            </Canvas>
          </DockPanel>
        </Border>
        <Border Style="{StaticResource Tile}">
          <DockPanel>
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,3">
              <TextBlock Text="Network" FontWeight="SemiBold"/>
              <TextBlock x:Name="mNet" Text="--" HorizontalAlignment="Right" Foreground="{DynamicResource MutedBrush}"/>
            </DockPanel>
            <Canvas x:Name="cNet" Height="30" ClipToBounds="True">
              <Polygon x:Name="fNet" Fill="{DynamicResource ChartFillBrush}"/>
              <Polyline x:Name="lNet" Stroke="{DynamicResource AccentBrush}" StrokeThickness="1.5"/>
              <Polyline x:Name="lNet2" Stroke="{DynamicResource Accent2Brush}" StrokeThickness="1.5"/>
            </Canvas>
          </DockPanel>
        </Border>
      </UniformGrid>
    </Border>

    <TabControl x:Name="tabs" Margin="8">

      <!-- ================= Processes ================= -->
      <TabItem Header="   Processes   ">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*" MinHeight="120"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="230" MinHeight="90"/>
          </Grid.RowDefinitions>

          <DockPanel Grid.Row="0" Margin="0,0,0,8">
            <Button x:Name="btnAdmin"    DockPanel.Dock="Right" Content="Restart as Administrator"/>
            <Button x:Name="btnOpenLoc"  DockPanel.Dock="Right" Content="Open file location"/>
            <Button x:Name="btnKillProc" DockPanel.Dock="Right" Content="End process"/>
            <Button x:Name="btnRefresh"  DockPanel.Dock="Right" Content="Refresh"/>
            <Button x:Name="btnColumns"  DockPanel.Dock="Right" Content="Columns" MinWidth="0"/>
            <ComboBox x:Name="cmbInterval" DockPanel.Dock="Right" Width="58" Margin="4,0,0,0" SelectedIndex="1"
                      ToolTip="Auto-refresh interval">
              <ComboBoxItem Content="2 s"/><ComboBoxItem Content="3 s"/><ComboBoxItem Content="5 s"/><ComboBoxItem Content="10 s"/>
            </ComboBox>
            <CheckBox x:Name="chkAutoRefresh" DockPanel.Dock="Right" Content="Auto-refresh" Margin="12,0,0,0"
                      ToolTip="New processes are shown green, exited ones red for one cycle."/>
            <CheckBox x:Name="chkUnknown" DockPanel.Dock="Right" Content="Only unsigned / unknown" Margin="12,0,0,0"
                      ToolTip="Show only processes that are unsigned or have an invalid signature (and, when running as Administrator, processes whose file cannot be read)."/>
            <Grid>
              <TextBox x:Name="txtSearch"/>
              <TextBlock x:Name="phSearch" Text="Filter by name, PID, user, service, path or command line"
                         Foreground="{DynamicResource MutedBrush}" Margin="8,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
          </DockPanel>

          <DataGrid x:Name="gridProcs" Grid.Row="1" AlternationCount="2" AlternatingRowBackground="{x:Null}">
            <!-- RowStyle (alternation + New/Exited colours + tooltip) is built in code by Set-Theme -->
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="" Width="26" CanUserResize="False" CanUserReorder="False" SortMemberPath="Name">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate><Image Source="{Binding Icon}" Width="16" Height="16" Margin="3,0,0,0"/></DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="PID"         Binding="{Binding PID}"         Width="60"/>
              <DataGridTextColumn Header="Name"        Binding="{Binding Name}"        Width="150"/>
              <DataGridTextColumn Header="Description" Binding="{Binding Description}" Width="180"/>
              <DataGridTextColumn Header="CPU %"       Binding="{Binding CpuPercent, StringFormat={}{0:N1}}" Width="60"/>
              <DataGridTextColumn Header="Memory (MB)" Binding="{Binding MemoryMB}"    Width="95"/>
              <DataGridTextColumn Header="Disk KB/s"   Binding="{Binding DiskKBs, StringFormat={}{0:N1}}" Width="80"/>
              <DataGridTextColumn Header="Threads"     Binding="{Binding Threads}"     Width="65" Visibility="Collapsed"/>
              <DataGridTextColumn Header="Handles"     Binding="{Binding Handles}"     Width="65" Visibility="Collapsed"/>
              <DataGridTextColumn Header="User"        Binding="{Binding User}"        Width="140"/>
              <DataGridTextColumn Header="Used by / started by" Binding="{Binding UsedBy}" Width="270"/>
              <DataGridTextColumn Header="Signer"      Binding="{Binding Signer}"      Width="150"/>
              <DataGridTextColumn Header="Company"     Binding="{Binding Company}"     Width="150" Visibility="Collapsed"/>
              <DataGridTextColumn Header="Started"     Binding="{Binding Started, StringFormat=g}" Width="125"/>
              <DataGridTextColumn Header="Path"        Binding="{Binding Path}"        Width="*"/>
            </DataGrid.Columns>
          </DataGrid>

          <GridSplitter Grid.Row="2" Height="8" HorizontalAlignment="Stretch" Background="Transparent"
                        ResizeDirection="Rows" ResizeBehavior="PreviousAndNext" Cursor="SizeNS"/>
          <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="2*"/>
              <ColumnDefinition Width="3*"/>
            </Grid.ColumnDefinitions>
            <GroupBox Grid.Column="0" Header="Details of selected process" Margin="0,0,4,0">
              <DockPanel>
                <Border DockPanel.Dock="Bottom" Margin="4,4,4,2" Padding="6,3,6,4" Background="{DynamicResource BgBrush}"
                        BorderBrush="{DynamicResource LineBrush}" BorderThickness="1" CornerRadius="3">
                  <DockPanel>
                    <TextBlock DockPanel.Dock="Top" x:Name="mProc" Text="Select a process to see its live CPU (blue) and memory (orange)."
                               Foreground="{DynamicResource MutedBrush}" Margin="0,0,0,3"/>
                    <Canvas x:Name="cProc" Height="34" ClipToBounds="True">
                      <Polygon x:Name="fProc" Fill="{DynamicResource ChartFillBrush}"/>
                      <Polyline x:Name="lProc" Stroke="{DynamicResource AccentBrush}" StrokeThickness="1.5"/>
                      <Polyline x:Name="lProc2" Stroke="{DynamicResource Accent2Brush}" StrokeThickness="1.5"/>
                    </Canvas>
                  </DockPanel>
                </Border>
                <TextBox x:Name="txtDetails" IsReadOnly="True" TextWrapping="Wrap"
                         VerticalScrollBarVisibility="Auto" BorderThickness="0" Background="Transparent"/>
              </DockPanel>
            </GroupBox>
            <GroupBox Grid.Column="1" Margin="4,0,0,0">
              <GroupBox.Header>
                <StackPanel Orientation="Horizontal">
                  <TextBlock x:Name="txtFilesHeader" Text="Files used by selected process"/>
                  <CheckBox x:Name="chkModules" Content="include loaded DLLs / EXE" Margin="16,0,0,0"/>
                </StackPanel>
              </GroupBox.Header>
              <DataGrid x:Name="gridFiles" SelectionMode="Single" RowHeight="22">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Kind" Binding="{Binding Kind}" Width="110"/>
                  <DataGridTextColumn Header="File" Binding="{Binding File}" Width="*"/>
                </DataGrid.Columns>
              </DataGrid>
            </GroupBox>
          </Grid>
        </Grid>
      </TabItem>

      <!-- ================= Open files (all processes) ================= -->
      <TabItem Header="   Open files   ">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,6">
            <Button x:Name="btnLoadAllFiles" DockPanel.Dock="Right" Content="Load / refresh" FontWeight="SemiBold"/>
            <CheckBox x:Name="chkAllModules" DockPanel.Dock="Right" Content="include loaded DLLs / EXE"
                      VerticalAlignment="Center" Margin="12,0,0,0"/>
            <Grid>
              <TextBox x:Name="txtFileSearch"/>
              <TextBlock x:Name="phFileSearch" Text="Filter by file, folder, process name or PID"
                         Foreground="{DynamicResource MutedBrush}" Margin="8,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
          </DockPanel>
          <TextBlock Grid.Row="1" x:Name="txtAllFilesInfo" Foreground="{DynamicResource MutedBrush}" Margin="0,0,0,8"
                     Text="Click 'Load / refresh' to list every file every process has open right now. Type part of a file name, folder or process name to filter. Double-click a row to jump to that process."/>
          <DataGrid x:Name="gridAllFiles" Grid.Row="2">
            <DataGrid.Columns>
              <DataGridTextColumn Header="PID"     Binding="{Binding PID}"     Width="60"/>
              <DataGridTextColumn Header="Process" Binding="{Binding Process}" Width="180"/>
              <DataGridTextColumn Header="Kind"    Binding="{Binding Kind}"    Width="110"/>
              <DataGridTextColumn Header="File"    Binding="{Binding File}"    Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

      <!-- ================= Who's locking ================= -->
      <TabItem Header="   Who's locking a file?   ">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <DockPanel Grid.Row="0" Margin="0,0,0,6">
            <Button x:Name="btnCheck"        DockPanel.Dock="Right" Content="Check" FontWeight="SemiBold"/>
            <Button x:Name="btnBrowseFolder" DockPanel.Dock="Right" Content="Folder..."/>
            <Button x:Name="btnBrowseFile"   DockPanel.Dock="Right" Content="File..."/>
            <Grid>
              <TextBox x:Name="txtPath" AllowDrop="True"/>
              <TextBlock x:Name="phPath" Text="Drop a file or folder here, paste a path, or type part of a file name to search every open handle"
                         Foreground="{DynamicResource MutedBrush}" Margin="8,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
          </DockPanel>
          <TextBlock Grid.Row="1" Text="Finds programs that hold the item open or have it loaded. Right-click a result to end it, or to release just the file and keep the program running."
                     Foreground="{DynamicResource MutedBrush}" Margin="0,0,0,8" TextWrapping="Wrap"/>

          <DataGrid x:Name="gridLock" Grid.Row="2">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="" Width="26" CanUserResize="False" CanUserReorder="False" SortMemberPath="Name">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate><Image Source="{Binding Icon}" Width="16" Height="16" Margin="3,0,0,0"/></DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="PID"         Binding="{Binding PID}"         Width="60"/>
              <DataGridTextColumn Header="Process"     Binding="{Binding Name}"        Width="160"/>
              <DataGridTextColumn Header="Description" Binding="{Binding Description}" Width="220"/>
              <DataGridTextColumn Header="Type"        Binding="{Binding Type}"        Width="180"/>
              <DataGridTextColumn Header="User"        Binding="{Binding User}"        Width="150"/>
              <DataGridTextColumn Header="Started"     Binding="{Binding Started, StringFormat=g}" Width="130"/>
              <DataGridTextColumn Header="Held item"   Binding="{Binding HeldItem}"    Width="260"/>
              <DataGridTextColumn Header="Path"        Binding="{Binding Path}"        Width="*"/>
            </DataGrid.Columns>
          </DataGrid>

          <DockPanel Grid.Row="3" Margin="0,8,0,0">
            <Button x:Name="btnAdmin2"     DockPanel.Dock="Right" Content="Restart as Administrator"/>
            <Button x:Name="btnShowInList" DockPanel.Dock="Right" Content="Show in Processes tab"/>
            <Button x:Name="btnKillLock"   DockPanel.Dock="Right" Content="End process / stop service"/>
            <TextBlock x:Name="txtLockInfo" VerticalAlignment="Center" TextWrapping="Wrap"/>
          </DockPanel>
        </Grid>
      </TabItem>

      <!-- ================= Network ================= -->
      <TabItem Header="   Network   ">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,6">
            <Button x:Name="btnNetRefresh" DockPanel.Dock="Right" Content="Load / refresh" FontWeight="SemiBold"/>
            <Grid>
              <TextBox x:Name="txtNetSearch"/>
              <TextBlock x:Name="phNetSearch" Text="Filter by process, PID, address, port or state"
                         Foreground="{DynamicResource MutedBrush}" Margin="8,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
          </DockPanel>
          <TextBlock Grid.Row="1" x:Name="txtNetInfo" Foreground="{DynamicResource MutedBrush}" Margin="0,0,0,8"
                     Text="TCP connections and UDP listeners of every process. Search by process, address, port or state. Double-click a row to jump to the process."/>
          <DataGrid x:Name="gridNet" Grid.Row="2">
            <DataGrid.Columns>
              <DataGridTextColumn Header="PID"            Binding="{Binding PID}"        Width="60"/>
              <DataGridTextColumn Header="Process"        Binding="{Binding Process}"    Width="160"/>
              <DataGridTextColumn Header="Protocol"       Binding="{Binding Protocol}"   Width="70"/>
              <DataGridTextColumn Header="Local address"  Binding="{Binding LocalAddr}"  Width="160"/>
              <DataGridTextColumn Header="Local port"     Binding="{Binding LocalPort}"  Width="80"/>
              <DataGridTextColumn Header="Remote address" Binding="{Binding RemoteAddr}" Width="160"/>
              <DataGridTextColumn Header="Remote port"    Binding="{Binding RemotePort}" Width="90"/>
              <DataGridTextColumn Header="State"          Binding="{Binding State}"      Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

    </TabControl>
  </DockPanel>
</Window>
'@

$script:window = [Windows.Markup.XamlReader]::Parse($xaml)
$ui = @{}
foreach ($n in 'txtStatus','tabs','btnAdmin','btnOpenLoc','btnKillProc','btnRefresh','txtSearch','gridProcs','txtDetails',
               'btnCheck','btnBrowseFolder','btnBrowseFile','txtPath','gridLock','btnAdmin2','btnShowInList','btnKillLock','txtLockInfo',
               'txtFilesHeader','chkModules','gridFiles','btnLoadAllFiles','chkAllModules','txtFileSearch','txtAllFilesInfo','gridAllFiles',
               'chkAutoRefresh','chkDark','btnUpdates','btnNetRefresh','txtNetSearch','txtNetInfo','gridNet',
               'metricsBar','mCpu','cCpu','fCpu','lCpu','mMem','cMem','fMem','lMem','mDisk','cDisk','fDisk','lDisk',
               'mNet','cNet','fNet','lNet','lNet2','mProc','cProc','fProc','lProc','lProc2',
               'btnColumns','cmbInterval','chkUnknown','chkMetrics','phSearch','phFileSearch','phNetSearch','phPath') {
    $ui[$n] = $window.FindName($n)
}
if ($IsAdmin) {
    $window.Title = 'Process Inspector  (Administrator)'
    $ui.btnAdmin.Visibility = 'Collapsed'; $ui.btnAdmin2.Visibility = 'Collapsed'
}
$script:IconPath = Join-Path $AppRoot 'app.ico'
if (Test-Path $IconPath) {
    try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([uri]$IconPath) } catch {}
}
# never open larger than the screen
$wa = [System.Windows.SystemParameters]::WorkArea
if ($window.Width  -gt $wa.Width  - 40) { $window.Width  = [Math]::Max($window.MinWidth,  $wa.Width  - 40) }
if ($window.Height -gt $wa.Height - 40) { $window.Height = [Math]::Max($window.MinHeight, $wa.Height - 40) }

function Test-Match([string]$text, [string]$q) {
    # plain substring match, case-insensitive, no wildcard surprises with [ ] * ?
    return ($null -ne $text -and $text.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# ---- Theme + settings ---------------------------------------------------------------
$script:Palette = @{
    light = @{ BgBrush='#F3F3F3'; PanelBrush='#FFFFFF'; AltRowBrush='#F7F9FC'; HeaderBrush='#EDEDED'; LineBrush='#CCCCCC'
               GridLineBrush='#E3E3E3'; TextBrush='#1B1B1B'; MutedBrush='#666666'; StatusBrush='#E8E8E8'
               NewRowBrush='#DDF5DD'; ExitedRowBrush='#F9DADA'; ButtonBrush='#E6E6E6'
               AccentBrush='#2F7BD9'; Accent2Brush='#E08A2E'; ChartFillBrush='#332F7BD9' }
    dark  = @{ BgBrush='#1E1E1E'; PanelBrush='#262626'; AltRowBrush='#2C2C2C'; HeaderBrush='#333333'; LineBrush='#464646'
               GridLineBrush='#353535'; TextBrush='#E4E4E4'; MutedBrush='#9C9C9C'; StatusBrush='#2A2A2A'
               NewRowBrush='#22402A'; ExitedRowBrush='#4B2323'; ButtonBrush='#3A3A3A'
               AccentBrush='#4EA1FF'; Accent2Brush='#F0A050'; ChartFillBrush='#334EA1FF' }
}
function Set-Theme([bool]$dark) {
    $pal = if ($dark) { $Palette.dark } else { $Palette.light }
    foreach ($k in $pal.Keys) {
        $b = New-Object System.Windows.Media.SolidColorBrush
        $b.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($pal[$k])
        $b.Freeze()
        # .BaseObject: the untyped indexer would otherwise receive PowerShell's PSObject wrapper,
        # which WPF rejects as "not a valid value for property Foreground"
        $window.Resources[$k] = $b.psobject.BaseObject
    }
    $script:IsDark = $dark
    # Trigger setters resolve a DynamicResource only once, so the row style is rebuilt with
    # concrete colours: alternating rows, plus green "New" / red "Exited" rows.
    $rowStyle = @"
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="DataGridRow">
  <Setter Property="ToolTip" Value="{Binding CommandLine}"/>
  <Style.Triggers>
    <Trigger Property="AlternationIndex" Value="1"><Setter Property="Background" Value="$($pal.AltRowBrush)"/></Trigger>
    <DataTrigger Binding="{Binding Status}" Value="New"><Setter Property="Background" Value="$($pal.NewRowBrush)"/></DataTrigger>
    <DataTrigger Binding="{Binding Status}" Value="Exited">
      <Setter Property="Background" Value="$($pal.ExitedRowBrush)"/>
      <Setter Property="Foreground" Value="$($pal.MutedBrush)"/>
    </DataTrigger>
  </Style.Triggers>
</Style>
"@
    $ui.gridProcs.RowStyle = [Windows.Markup.XamlReader]::Parse($rowStyle)
}
Set-Theme $false

$script:SettingsFile = Join-Path $IpcDir 'settings.json'
$script:Settings = @{ dark = $false; autoRefresh = $false; interval = 1; metrics = $true; hiddenCols = @('Threads','Handles','Company')
                      width = 0; height = 0; left = -99999; top = -99999 }
function Load-Settings {
    try {
        if (Test-Path $SettingsFile) {
            $j = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $Settings[$p.Name] = $p.Value }
        }
    } catch {}
}
function Save-Settings {
    try {
        $Settings.dark        = [bool]$ui.chkDark.IsChecked
        $Settings.autoRefresh = [bool]$ui.chkAutoRefresh.IsChecked
        $Settings.interval    = [int]$ui.cmbInterval.SelectedIndex
        $Settings.metrics     = [bool]$ui.chkMetrics.IsChecked
        $Settings.hiddenCols  = @($ui.gridProcs.Columns | Where-Object { $_.Header -and $_.Visibility -ne 'Visible' } | ForEach-Object { [string]$_.Header })
        if ($window.WindowState -eq 'Normal' -and $window.ActualWidth -gt 0) {
            $Settings.width = [int]$window.ActualWidth; $Settings.height = [int]$window.ActualHeight
            $Settings.left  = [int]$window.Left;        $Settings.top    = [int]$window.Top
        }
        New-Item -ItemType Directory -Force -Path $IpcDir | Out-Null
        $Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
    } catch {}
}
function Apply-Settings {
    Load-Settings
    $ui.chkDark.IsChecked = [bool]$Settings.dark
    Set-Theme ([bool]$Settings.dark)
    $ui.chkAutoRefresh.IsChecked = [bool]$Settings.autoRefresh
    $ui.cmbInterval.SelectedIndex = [Math]::Max(0, [Math]::Min(3, [int]$Settings.interval))
    $ui.chkMetrics.IsChecked = [bool]$Settings.metrics
    $ui.metricsBar.Visibility = if ($Settings.metrics) { 'Visible' } else { 'Collapsed' }
    $hidden = @($Settings.hiddenCols)
    foreach ($c in $ui.gridProcs.Columns) {
        if (-not $c.Header) { continue }
        $c.Visibility = if ($hidden -contains [string]$c.Header) { 'Collapsed' } else { 'Visible' }
    }
    foreach ($mi in $ColMenu.Items) { $mi.IsChecked = ($mi.Tag.Visibility -eq 'Visible') }
    if ($Settings.width -ge 800 -and $Settings.height -ge 500) {
        $wa = [System.Windows.SystemParameters]::VirtualScreenWidth
        if ($Settings.left -gt -10000 -and $Settings.left -lt $wa -and $Settings.top -gt -10000) {
            $window.WindowStartupLocation = 'Manual'
            $window.Left = $Settings.left; $window.Top = $Settings.top
        }
        $window.Width = [Math]::Min($Settings.width, [System.Windows.SystemParameters]::WorkArea.Width)
        $window.Height = [Math]::Min($Settings.height, [System.Windows.SystemParameters]::WorkArea.Height)
    }
}

# ---- Update check (GitHub Releases) -----------------------------------------------------
function Check-Updates {
    Show-Status 'Checking GitHub for a newer version...'
    $window.Cursor = 'Wait'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest" `
                                 -Headers @{ 'User-Agent' = "ProcessInspector/$AppVersion" } -TimeoutSec 10
        $latest = [version](($rel.tag_name -replace '^v', '') -replace '[^\d.].*$', '')
        if ($latest -gt [version]$AppVersion) {
            $ans = [System.Windows.MessageBox]::Show("Version $latest is available (you have $AppVersion).`n`nOpen the download page?", 'Update available', 'YesNo', 'Information')
            if ($ans -eq 'Yes') { Start-Process $rel.html_url }
        } else {
            [System.Windows.MessageBox]::Show("You have the latest version ($AppVersion).", 'Up to date', 'OK', 'Information') | Out-Null
        }
    } catch {
        [System.Windows.MessageBox]::Show("Could not check for updates.`n`n$($_.Exception.Message)`n`n(No internet connection, or the project has not published a release yet.)", 'Check for updates', 'OK', 'Warning') | Out-Null
    } finally { $window.Cursor = $null; Show-Status 'Ready' }
}

function Show-Status([string]$t) { $ui.txtStatus.Text = $t; $ui.txtStatus.Dispatcher.Invoke([action]{}, 'Render') }

# Errors are appended to %LOCALAPPDATA%\ProcessInspector\error.log so a problem can be diagnosed after the fact.
$script:ErrorLog = Join-Path $IpcDir 'error.log'
function Write-ErrorLog([string]$where, $err) {
    try {
        $ex = $err; $stack = ''
        if ($err -is [System.Management.Automation.ErrorRecord]) { $ex = $err.Exception; $stack = $err.ScriptStackTrace }
        $msg = if ($ex) { $ex.ToString() } else { [string]$err }
        New-Item -ItemType Directory -Force -Path $IpcDir | Out-Null
        Add-Content -Path $ErrorLog -Value "[$(Get-Date -Format s)] v$AppVersion $where`n$msg`n$stack`n" -Encoding UTF8
        # keep the log small
        if ((Get-Item $ErrorLog).Length -gt 512KB) { Get-Content $ErrorLog -Tail 400 | Set-Content $ErrorLog -Encoding UTF8 }
    } catch {}
}

# ---- Processes tab ------------------------------------------------------------
function Test-Unknown($o) {
    # "unknown" = nobody vouches for the program: unsigned or a bad signature. A process whose file we
    # cannot even read counts too, but only when elevated - for a normal user that is every system
    # process, which would drown the list.
    if ($o.Signer -eq 'Unsigned' -or $o.Signer -like 'Invalid*') { return $true }
    return ($IsAdmin -and -not $o.Path)
}
$script:ProcFilter = [Predicate[object]]{
    param($o)
    if ($ui.chkUnknown.IsChecked -and -not (Test-Unknown $o)) { return $false }
    $q = $ui.txtSearch.Text
    if ([string]::IsNullOrWhiteSpace($q)) { return $true }
    $q = $q.Trim()
    return ((Test-Match $o.Name $q) -or (Test-Match $o.Description $q) -or (Test-Match $o.Services $q) -or
            (Test-Match $o.Path $q) -or (Test-Match $o.User $q) -or (Test-Match $o.Parent $q) -or
            [string]$o.PID -eq $q -or (Test-Match $o.CommandLine $q))
}

function Find-Child($parent, [type]$type) {
    if (-not $parent) { return $null }
    $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($parent)
    for ($i = 0; $i -lt $n; $i++) {
        $c = [System.Windows.Media.VisualTreeHelper]::GetChild($parent, $i)
        if ($c -is $type) { return $c }
        $r = Find-Child $c $type
        if ($r) { return $r }
    }
    return $null
}

# Authenticode signer of an exe, cached per path ("Unsigned" / "Invalid (...)" / signer name).
function Get-SignerText([string]$p) {
    if (-not $p) { return '' }
    if ($SignerCache.ContainsKey($p)) { return $SignerCache[$p] }
    $t = ''
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $p -ErrorAction Stop
        switch ([string]$sig.Status) {
            'Valid'     { $t = $sig.SignerCertificate.Subject; if ($t -match 'CN=("[^"]+"|[^,]+)') { $t = $matches[1].Trim('"') } }
            'NotSigned' { $t = 'Unsigned' }
            default     { $t = "Invalid ($($sig.Status))" }
        }
    } catch { $t = '' }
    $SignerCache[$p] = $t
    return $t
}
# Signature checks take seconds for a few hundred files, so they run in a background runspace;
# a timer applies the results to the list when they are ready.
$script:SigJob = $null
$script:SigScript = {
    param([string[]]$paths)
    foreach ($p in $paths) {
        $t = ''
        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $p -ErrorAction Stop
            switch ([string]$sig.Status) {
                'Valid'     { $t = $sig.SignerCertificate.Subject; if ($t -match 'CN=("[^"]+"|[^,]+)') { $t = $matches[1].Trim('"') } }
                'NotSigned' { $t = 'Unsigned' }
                default     { $t = "Invalid ($($sig.Status))" }
            }
        } catch { $t = '' }
        [pscustomobject]@{ Path = $p; Signer = $t }
    }
}
function Update-Signers {
    if (-not $script:AllProcs -or $SigJob) { return }
    $todo = @{}
    foreach ($r in $AllProcs) { if ($r.Path -and -not $r.Signer -and -not $SignerCache.ContainsKey($r.Path)) { $todo[$r.Path] = $true } }
    if ($todo.Count -eq 0) { return }
    Show-Status "Checking signatures of $($todo.Count) program(s) in the background..."
    $ps = [powershell]::Create()
    $ps.Runspace = [runspacefactory]::CreateRunspace(); $ps.Runspace.Open()
    $null = $ps.AddScript($SigScript).AddArgument([string[]]@($todo.Keys))
    $script:SigJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
    $SigTimer.Start()
}
$script:SigTimer = New-Object System.Windows.Threading.DispatcherTimer
$SigTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$SigTimer.Add_Tick({
    try {
        if (-not $SigJob) { $SigTimer.Stop(); return }
        if (-not $SigJob.Handle.IsCompleted) { return }
        $SigTimer.Stop()
        try {
            $results = $SigJob.PS.EndInvoke($SigJob.Handle)
            foreach ($x in $results) { if ($x.Path) { $SignerCache[$x.Path] = $x.Signer } }
        } catch {} finally {
            try { $SigJob.PS.Runspace.Dispose(); $SigJob.PS.Dispose() } catch {}
            $script:SigJob = $null
        }
        if ($script:AllProcs -and -not $LoadingProcs) {
            foreach ($r in $AllProcs) { if ($r.Path -and -not $r.Signer -and $SignerCache.ContainsKey($r.Path)) { $r.Signer = $SignerCache[$r.Path] } }
            $ui.gridProcs.Items.Refresh()
            Update-ProcCount
            if ($ui.gridProcs.SelectedItem) { Show-Details $ui.gridProcs.SelectedItem }
        }
    } catch { Write-ErrorLog 'signatures' $_ }
})

$script:LoadingProcs = $false
function Load-Processes([switch]$Auto) {
    if ($LoadingProcs) { return }          # a click during the wait cursor must not re-enter
    $script:LoadingProcs = $true
    if (-not $Auto) { Show-Status 'Collecting processes...'; $window.Cursor = 'Wait' }
    try {
        # remember selection, sort and scroll position so a refresh does not throw them away
        $selPids = @{}; foreach ($s in $ui.gridProcs.SelectedItems) { $selPids[[int]$s.PID] = $true }
        $current = $ui.gridProcs.SelectedItem
        $sortCols = @($ui.gridProcs.Columns | Where-Object { $_.SortDirection -ne $null })
        $sv = Find-Child $ui.gridProcs ([System.Windows.Controls.ScrollViewer])
        $offset = if ($sv) { $sv.VerticalOffset } else { 0 }

        $script:AllProcs = Get-ProcessRows -KeepExited:($Auto -and $ui.chkAutoRefresh.IsChecked)
        $ui.gridProcs.ItemsSource = $AllProcs
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridProcs.ItemsSource)
        $view.Filter = $ProcFilter
        foreach ($c in $sortCols) {
            $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription($c.SortMemberPath, $c.SortDirection)))
            $c.SortDirection = $c.SortDirection
        }
        if ($selPids.Count -gt 0) {
            $first = $null
            foreach ($r in $AllProcs) {
                if ($selPids.ContainsKey($r.PID)) {
                    if ($selPids.Count -eq 1) { $ui.gridProcs.SelectedItem = $r } else { $ui.gridProcs.SelectedItems.Add($r) }
                    if (-not $first -or ($current -and $r.PID -eq $current.PID)) { $first = $r }
                }
            }
            if ($first -and -not $Auto) { $ui.gridProcs.ScrollIntoView($first) }
        }
        if ($sv -and $offset -gt 0) {
            $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded,
                [action]{ $sv.ScrollToVerticalOffset($offset) }.GetNewClosure()) | Out-Null
        }
        Update-ProcCount
        # signatures are checked after the list is on screen (one-time cost per new program)
        $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Update-Signers }) | Out-Null
    } catch {
        Write-ErrorLog 'refresh' $_
        Show-Status "Could not refresh the list: $($_.Exception.Message)  (details in error.log)"
    } finally { $window.Cursor = $null; $script:LoadingProcs = $false }
}
function Update-ProcCount {
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridProcs.ItemsSource)
    $shown = 0; foreach ($x in $view) { $shown++ }
    $msg = "$shown of $($AllProcs.Count) processes"
    if (-not $IsAdmin) { $msg += '   (not elevated: path/user of system processes hidden)' }
    Show-Status $msg
}

$ui.txtSearch.Add_TextChanged({
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridProcs.ItemsSource)
    if ($view) { $view.Refresh(); Update-ProcCount }
})
$ui.chkUnknown.Add_Click({
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridProcs.ItemsSource)
    if ($view) { $view.Refresh(); Update-ProcCount }
})

# placeholder text in the search boxes
$script:Placeholders = @{ txtSearch = 'phSearch'; txtFileSearch = 'phFileSearch'; txtNetSearch = 'phNetSearch'; txtPath = 'phPath' }
foreach ($n in $Placeholders.Keys) {
    $ui[$n].Add_TextChanged({ param($s, $e) $ui[$Placeholders[$s.Name]].Visibility = if ($s.Text) { 'Collapsed' } else { 'Visible' } })
}

# column chooser for the process list
$script:ColMenu = New-Object System.Windows.Controls.ContextMenu
foreach ($c in $ui.gridProcs.Columns) {
    if (-not $c.Header) { continue }
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = [string]$c.Header; $mi.IsCheckable = $true; $mi.StaysOpenOnClick = $true
    $mi.IsChecked = ($c.Visibility -eq 'Visible')
    $mi.Tag = $c.psobject.BaseObject
    $mi.Add_Click({ param($s, $e)
        $s.Tag.Visibility = if ($s.IsChecked) { 'Visible' } else { 'Collapsed' }
        Save-Settings })
    $null = $ColMenu.Items.Add($mi)
}
$ui.btnColumns.Add_Click({ $ColMenu.PlacementTarget = $ui.btnColumns; $ColMenu.IsOpen = $true })
$ui.chkMetrics.Add_Click({
    $ui.metricsBar.Visibility = if ($ui.chkMetrics.IsChecked) { 'Visible' } else { 'Collapsed' }
    Save-Settings
})
$ui.btnRefresh.Add_Click({ Load-Processes })
$ui.btnAdmin.Add_Click({ Restart-Elevated $ui.txtPath.Text })
$ui.btnAdmin2.Add_Click({ Restart-Elevated $ui.txtPath.Text })
$ui.btnUpdates.Add_Click({ Check-Updates })
$ui.chkDark.Add_Click({ Set-Theme ([bool]$ui.chkDark.IsChecked); Save-Settings })

$script:Intervals = 2, 3, 5, 10
$script:AutoTimer = New-Object System.Windows.Threading.DispatcherTimer
$AutoTimer.Interval = [TimeSpan]::FromSeconds(3)
$AutoTimer.Add_Tick({
    try {
        if ($window.IsVisible -and $ui.tabs.SelectedIndex -eq 0 -and -not $LoadingProcs -and -not $CheckingLock) { Load-Processes -Auto }
    } catch { Write-ErrorLog 'auto-refresh' $_ }
})
$ui.chkAutoRefresh.Add_Click({
    if ($ui.chkAutoRefresh.IsChecked) { $AutoTimer.Start() } else { $AutoTimer.Stop() }
    Save-Settings
})
$ui.cmbInterval.Add_SelectionChanged({
    $i = [Math]::Max(0, $ui.cmbInterval.SelectedIndex)
    $AutoTimer.Interval = [TimeSpan]::FromSeconds($Intervals[$i])
    if ($script:Settings) { Save-Settings }
})

# ---- Live metrics (1 s) ----------------------------------------------------------------------
$script:MetricSamples = 60
$script:Hist = @{}
foreach ($k in 'cpu','mem','disk','netIn','netOut','pcpu','pmem') { $Hist[$k] = New-Object System.Collections.Generic.List[double] }
$script:MetricPrev = @{ Time = $null; Io = [uint64]0; In = [uint64]0; Out = [uint64]0 }
$script:DiskCounter = $null; $script:DiskCounterTried = $false
$script:SelProc = $null; $script:SelProcPid = -1; $script:SelProcCpu = $null; $script:SelProcTime = $null

function Push-Sample([string]$k, [double]$v) {
    $l = $Hist[$k]; $l.Add($v)
    while ($l.Count -gt $MetricSamples) { $l.RemoveAt(0) }
}
function Format-Rate([double]$bps) {
    if ($bps -ge 1GB) { return ('{0:N1} GB/s' -f ($bps / 1GB)) }
    if ($bps -ge 1MB) { return ('{0:N1} MB/s' -f ($bps / 1MB)) }
    if ($bps -ge 1KB) { return ('{0:N0} KB/s' -f ($bps / 1KB)) }
    return ('{0:N0} B/s' -f $bps)
}
# Draws one series into a Polyline (and optional area Polygon) on a Canvas.
function Draw-Chart($canvas, $line, $fill, $values, [double]$max) {
    $w = $canvas.ActualWidth; $h = $canvas.ActualHeight
    $n = $values.Count
    if ($w -le 0 -or $h -le 0 -or $n -lt 2) { return }
    if ($max -le 0) { $max = 1 }
    $pts = New-Object System.Windows.Media.PointCollection
    $start = $MetricSamples - $n
    for ($i = 0; $i -lt $n; $i++) {
        $x = ($start + $i) * $w / ($MetricSamples - 1)
        $y = ($h - 1) - [Math]::Min(1.0, $values[$i] / $max) * ($h - 2)
        $pts.Add((New-Object System.Windows.Point($x, $y)))
    }
    $line.Points = $pts
    if ($fill) {
        $fp = New-Object System.Windows.Media.PointCollection
        $fp.Add((New-Object System.Windows.Point($pts[0].X, $h)))
        foreach ($pt in $pts) { $fp.Add($pt) }
        $fp.Add((New-Object System.Windows.Point($pts[$pts.Count - 1].X, $h)))
        $fill.Points = $fp
    }
}
function Get-DiskBytesPerSec([double]$dt) {
    # English perf-counter names are not available on every Windows language: try once, then fall back
    # to summing the I/O counters of every process we may query.
    if (-not $DiskCounterTried) {
        $script:DiskCounterTried = $true
        try {
            $c = New-Object System.Diagnostics.PerformanceCounter('PhysicalDisk', 'Disk Bytes/sec', '_Total')
            $null = $c.NextValue(); $script:DiskCounter = $c
        } catch { $script:DiskCounter = $null }
    }
    if ($DiskCounter) { try { return [double]$DiskCounter.NextValue() } catch {} }
    $io = [WhosLocking.SysMetrics]::TotalIo()
    $rate = if ($MetricPrev.Io -gt 0 -and $dt -gt 0) { ($io - $MetricPrev.Io) / $dt } else { 0 }
    $MetricPrev.Io = $io
    return [Math]::Max(0, $rate)
}
function Update-Metrics {
    $now = Get-Date
    $dt = if ($MetricPrev.Time) { ($now - $MetricPrev.Time).TotalSeconds } else { 0 }
    $MetricPrev.Time = $now

    $cpu = [WhosLocking.SysMetrics]::CpuPercent()
    [uint64]$tot = 0; [uint64]$av = 0
    [WhosLocking.SysMetrics]::Memory([ref]$tot, [ref]$av)
    $usedGB = ($tot - $av) / 1GB; $totGB = $tot / 1GB
    $disk = Get-DiskBytesPerSec $dt
    [uint64]$in = 0; [uint64]$out = 0
    [WhosLocking.SysMetrics]::NetBytes([ref]$in, [ref]$out)
    $inRate = 0; $outRate = 0
    if ($MetricPrev.In -gt 0 -and $dt -gt 0) { $inRate = [Math]::Max(0, ($in - $MetricPrev.In) / $dt); $outRate = [Math]::Max(0, ($out - $MetricPrev.Out) / $dt) }
    $MetricPrev.In = $in; $MetricPrev.Out = $out

    Push-Sample 'cpu' $cpu; Push-Sample 'mem' $usedGB; Push-Sample 'disk' $disk; Push-Sample 'netIn' $inRate; Push-Sample 'netOut' $outRate
    $ui.mCpu.Text  = ('{0:N0} %' -f $cpu)
    $ui.mMem.Text  = ('{0:N1} / {1:N1} GB  ({2:N0} %)' -f $usedGB, $totGB, ($usedGB / $totGB * 100))
    $ui.mDisk.Text = Format-Rate $disk
    $ui.mNet.Text  = ('down {0}   up {1}' -f (Format-Rate $inRate), (Format-Rate $outRate))
    Draw-Chart $ui.cCpu  $ui.lCpu  $ui.fCpu  $Hist.cpu  100
    Draw-Chart $ui.cMem  $ui.lMem  $ui.fMem  $Hist.mem  $totGB
    $dmax = 0; foreach ($v in $Hist.disk) { if ($v -gt $dmax) { $dmax = $v } }
    Draw-Chart $ui.cDisk $ui.lDisk $ui.fDisk $Hist.disk ([Math]::Max($dmax, 1MB))
    $nmax = 0; foreach ($v in $Hist.netIn) { if ($v -gt $nmax) { $nmax = $v } }; foreach ($v in $Hist.netOut) { if ($v -gt $nmax) { $nmax = $v } }
    Draw-Chart $ui.cNet  $ui.lNet  $ui.fNet  $Hist.netIn  ([Math]::Max($nmax, 100KB))
    Draw-Chart $ui.cNet  $ui.lNet2 $null     $Hist.netOut ([Math]::Max($nmax, 100KB))

    # selected process
    $r = $ui.gridProcs.SelectedItem
    if (-not $r -or $r.Status -eq 'Exited') { return }
    if ($r.PID -ne $SelProcPid) {
        $script:SelProcPid = $r.PID; $script:SelProcCpu = $null; $script:SelProcTime = $null
        $Hist.pcpu.Clear(); $Hist.pmem.Clear()
        if ($SelProc) { try { $SelProc.Dispose() } catch {} }
        $script:SelProc = Get-Process -Id $r.PID -ErrorAction SilentlyContinue
    }
    if (-not $SelProc) { $ui.mProc.Text = "$($r.Name): no live data (access denied)"; return }
    try {
        $SelProc.Refresh()
        if ($SelProc.HasExited) { $ui.mProc.Text = "$($r.Name) has exited."; return }
        $cpuMs = $SelProc.TotalProcessorTime.TotalMilliseconds
        $pc = 0
        if ($null -ne $SelProcCpu -and $SelProcTime) {
            $wall = ($now - $SelProcTime).TotalMilliseconds
            if ($wall -gt 0) { $pc = [Math]::Max(0, ($cpuMs - $SelProcCpu) / $wall / [Environment]::ProcessorCount * 100) }
        }
        $script:SelProcCpu = $cpuMs; $script:SelProcTime = $now
        $memMB = $SelProc.WorkingSet64 / 1MB
        Push-Sample 'pcpu' $pc; Push-Sample 'pmem' $memMB
        $ui.mProc.Text = ('{0}  -  CPU {1:N1} %   Memory {2:N0} MB   Threads {3}   Handles {4}' -f $r.Name, $pc, $memMB, $SelProc.Threads.Count, $SelProc.HandleCount)
        $pmax = 0; foreach ($v in $Hist.pmem) { if ($v -gt $pmax) { $pmax = $v } }
        Draw-Chart $ui.cProc $ui.lProc  $ui.fProc $Hist.pcpu 100
        Draw-Chart $ui.cProc $ui.lProc2 $null     $Hist.pmem ([Math]::Max($pmax * 1.2, 1))
    } catch { $ui.mProc.Text = "$($r.Name): no live data" }
}
$script:MetricsTimer = New-Object System.Windows.Threading.DispatcherTimer
$MetricsTimer.Interval = [TimeSpan]::FromSeconds(1)
$MetricsTimer.Add_Tick({
    if ($window.IsVisible -and ($ui.metricsBar.Visibility -eq 'Visible' -or $ui.tabs.SelectedIndex -eq 0)) {
        try { Update-Metrics } catch { $ui.mProc.Text = "metrics: $($_.Exception.Message)"; Write-ErrorLog 'metrics' $_ }
    }
})

function Show-Details($r) {
    if (-not $r) { $ui.txtDetails.Text = ''; return }
    $lines = @(
        "$($r.Name)  (PID $($r.PID))   $($r.Description)   $($r.Company)"
        "User:        $($r.User)"
        "Started by:  $($r.Parent)"
        "Services:    $($r.Services)"
        "Started:     $($r.Started)"
        "Signer:      $(if ($r.Signer) { $r.Signer } elseif ($r.Path) { Get-SignerText $r.Path } else { '(unknown)' })"
        "Path:        $(if ($r.Path) { $r.Path } else { '(not readable - protected process or needs Administrator)' })"
        "Command:     $($r.CommandLine)"
    )
    $ui.txtDetails.Text = $lines -join "`n"
}

$script:LastFilesPid = -1
$ui.gridProcs.Add_SelectionChanged({
    $r = $ui.gridProcs.SelectedItem
    Show-Details $r
    # debounce: arrow-keying through the list must not scan handles on every step,
    # and an auto-refresh that re-selects the same process must not rescan at all
    if (-not $r) {
        if ($LoadingProcs) { return }          # a refresh clears and then restores the selection
        $FilesTimer.Stop(); Load-SelectedFiles; return
    }
    if ($r.PID -ne $LastFilesPid) { $FilesTimer.Stop(); $FilesTimer.Start() }
})
$script:FilesTimer = New-Object System.Windows.Threading.DispatcherTimer
$FilesTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$FilesTimer.Add_Tick({ $FilesTimer.Stop(); Load-SelectedFiles })

function Get-NameMap {
    $m = @{}
    if ($script:AllProcs) { foreach ($r in $AllProcs) { $m[[int]$r.PID] = $r.Name } }
    return $m
}

function Load-SelectedFiles {
    $r = $ui.gridProcs.SelectedItem
    $ui.gridFiles.ItemsSource = $null
    if (-not $r) { $ui.txtFilesHeader.Text = 'Files used by selected process'; $script:LastFilesPid = -1; return }
    $script:LastFilesPid = $r.PID
    try {
        $rows = Get-OpenFileRows $r.PID ([bool]$ui.chkModules.IsChecked) (Get-NameMap)
        $ui.gridFiles.ItemsSource = $rows
        $hdr = "Files used by $($r.Name) ($($r.PID)): $($rows.Count)"
        if ($rows.Count -eq 0 -and -not [WhosLocking.HandleEnum]::CanInspect($r.PID)) {
            $hdr += $(if ($IsAdmin) { '  - protected process' } else { '  - not visible, use Restart as Administrator' })
        }
        $ui.txtFilesHeader.Text = $hdr
    } catch {
        $ui.txtFilesHeader.Text = "Files: error - $($_.Exception.Message)"
    }
}
$ui.chkModules.Add_Click({ Load-SelectedFiles })
$ui.btnKillProc.Add_Click({
    if (Stop-Targets @($ui.gridProcs.SelectedItems)) { Load-Processes }
})
$ui.btnOpenLoc.Add_Click({
    $r = $ui.gridProcs.SelectedItem
    if ($r -and $r.Path -and (Test-Path -LiteralPath $r.Path)) { Start-Process explorer.exe -ArgumentList "/select,`"$($r.Path)`"" }
    else { Show-Status 'No path known for that process (try Restart as Administrator).' }
})

# ---- Lock tab -------------------------------------------------------------------
# Extensions Restart Manager is worth asking about inside a folder (loaded images). Everything
# else in a folder is covered faster and better by the handle scan.
$script:ImageExt = '.exe','.dll','.sys','.ocx','.drv','.cpl','.scr','.mui','.node','.pyd','.ax'

$script:CheckingLock = $false
function Run-LockCheck {
    if ($CheckingLock) { return }
    $p = $ui.txtPath.Text.Trim().Trim('"')
    if (-not $p) { Show-Status 'Enter or drop a path first.'; return }
    $script:CheckingLock = $true
    $window.Cursor = 'Wait'
    try {
        $partial = -not (Test-Path -LiteralPath $p)
        try {
            if ($partial) {
                # not an existing path: treat the text as a partial name and search every open handle
                Show-Status "Searching open handles for '$p'..."
                $script:LockQ = $p
                $rows = Merge-HandleLocks (New-Object 'System.Collections.Generic.List[WhosLocking.LockRow]') { param($path) Test-Match $path $script:LockQ } $null
                $what = "open handles matching '$p'"
            } else {
                $item  = Get-Item -LiteralPath $p -Force
                $isDir = $item.PSIsContainer
                $full  = $item.FullName.TrimEnd('\')
                if ($isDir) {
                    Show-Status 'Collecting files...'
                    $files   = Get-FilesUnder $full
                    $rmFiles = @($files | Where-Object { $ImageExt -contains [IO.Path]::GetExtension($_).ToLowerInvariant() })
                    Show-Status "Checking $($rmFiles.Count) program file(s)..."
                    $rows = Find-LockRows $rmFiles
                    Show-Status 'Scanning open handles under the folder...'
                    $script:LockFull = $full; $script:LockPrefix = $full + '\'
                    $rows = Merge-HandleLocks $rows { param($path)
                        $path.StartsWith($script:LockPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                        [string]::Equals($path, $script:LockFull, [StringComparison]::OrdinalIgnoreCase) } $full
                    $what = "folder ($($files.Count) files)"
                } else {
                    Show-Status 'Checking...'
                    $rows = Find-LockRows @($full)
                    Show-Status 'Scanning open handles...'
                    $script:LockFull = $full
                    $rows = Merge-HandleLocks $rows { param($path) [string]::Equals($path, $script:LockFull, [StringComparison]::OrdinalIgnoreCase) } $null
                    $what = 'file'
                }
            }
        } catch {
            $m = $_.Exception.Message
            if ($_.Exception.InnerException) { $m = $_.Exception.InnerException.Message }
            if ($m -match '\(5\)' -and -not $IsAdmin) {
                $ans = [System.Windows.MessageBox]::Show(
                    "Access denied: the file is held by a service or another user's process.`n`nRestart Process Inspector as Administrator to see it?",
                    'Administrator needed', 'YesNo', 'Question')
                if ($ans -eq 'Yes') { Restart-Elevated $p }
                else { Show-Status 'Access denied - run as Administrator to see this one.' }
                return
            }
            throw
        }
        $ui.gridLock.ItemsSource = $rows
        $note = if ($partial) { "Not an existing path, so every open handle was searched for '$p'. " } else { '' }
        if ($rows.Count -eq 0) {
            $ui.txtLockInfo.Text = $note + 'No process is holding it open' + $(if (-not $IsAdmin) { ' (as far as a non-admin can see - services and other users are hidden).' } else { '.' })
        } else {
            $ui.txtLockInfo.Text = $note + "Held open by $($rows.Count) process(es). Right-click a row for options: end it, or release just the file."
        }
        Show-Status "Checked $what."
    } catch {
        $ui.gridLock.ItemsSource = $null
        $ui.txtLockInfo.Text = "Error: $($_.Exception.Message)"
        Show-Status 'Error'
    } finally { $window.Cursor = $null; $script:CheckingLock = $false }
}

$ui.btnCheck.Add_Click({ Run-LockCheck })
$ui.txtPath.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Run-LockCheck } })
$ui.txtPath.Add_PreviewDragOver({ param($s, $e)
    $e.Effects = if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { 'Copy' } else { 'None' }
    $e.Handled = $true })
$ui.txtPath.Add_PreviewDrop({ param($s, $e)
    if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        $ui.txtPath.Text = @($e.Data.GetData([Windows.DataFormats]::FileDrop))[0]
        $e.Handled = $true
        Run-LockCheck
    } })
$ui.btnBrowseFile.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Title = 'Pick the file that is "in use"'; $d.CheckFileExists = $true
    if ($d.ShowDialog($window)) { $ui.txtPath.Text = $d.FileName; Run-LockCheck }
})
$ui.btnBrowseFolder.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Pick the folder that is "in use"'
    if ($d.ShowDialog() -eq 'OK') { $ui.txtPath.Text = $d.SelectedPath; Run-LockCheck }
})
$ui.btnKillLock.Add_Click({
    if (Stop-Targets @($ui.gridLock.SelectedItems)) { Run-LockCheck }
})
$ui.btnShowInList.Add_Click({
    $r = $ui.gridLock.SelectedItem
    if ($r) { $ui.txtSearch.Text = [string]$r.PID; $ui.tabs.SelectedIndex = 0 }
})

# ---- Open files tab ---------------------------------------------------------------
$script:FileFilter = [Predicate[object]]{
    param($o)
    $q = $ui.txtFileSearch.Text
    if ([string]::IsNullOrWhiteSpace($q)) { return $true }
    $q = $q.Trim()
    return ((Test-Match $o.File $q) -or (Test-Match $o.Process $q) -or [string]$o.PID -eq $q)
}
$script:AllFilesTotal = 0; $script:AllFilesProcs = 0
function Update-FileCount {
    if (-not $ui.gridAllFiles.ItemsSource) { return }
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridAllFiles.ItemsSource)
    $shown = 0; foreach ($x in $view) { $shown++ }
    $msg = "$shown of $AllFilesTotal file(s) across $AllFilesProcs process(es)."
    if (-not $IsAdmin) { $msg += '  Not elevated: files held by services / other users are not visible.' }
    $ui.txtAllFilesInfo.Text = $msg
}
$script:LoadingFiles = $false
function Load-AllFiles {
    if ($LoadingFiles) { return }
    $script:LoadingFiles = $true
    if (-not $script:AllProcs) { Load-Processes }
    Show-Status 'Scanning open handles of every process...'
    $window.Cursor = 'Wait'
    try {
        $rows = Get-OpenFileRows -1 ([bool]$ui.chkAllModules.IsChecked) (Get-NameMap)
        $script:AllFilesTotal = $rows.Count
        $pids = @{}; foreach ($r in $rows) { $pids[$r.PID] = $true }
        $script:AllFilesProcs = $pids.Count
        $ui.gridAllFiles.ItemsSource = $rows
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridAllFiles.ItemsSource)
        $view.Filter = $FileFilter
        Update-FileCount
        Show-Status "Open files loaded."
    } catch {
        $ui.txtAllFilesInfo.Text = "Error: $($_.Exception.Message)"
        Show-Status 'Error'
    } finally { $window.Cursor = $null; $script:LoadingFiles = $false }
}
$ui.btnLoadAllFiles.Add_Click({ Load-AllFiles })
$ui.txtFileSearch.Add_TextChanged({
    if ($ui.gridAllFiles.ItemsSource) {
        [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridAllFiles.ItemsSource).Refresh()
        Update-FileCount
    }
})
$ui.gridAllFiles.Add_MouseDoubleClick({
    $r = $ui.gridAllFiles.SelectedItem
    if ($r) { $ui.txtSearch.Text = [string]$r.PID; $ui.tabs.SelectedIndex = 0 }
})

# ---- Network tab ------------------------------------------------------------------------
function Resolve-ProcName([hashtable]$names, [int]$pid_) {
    $n = $names[$pid_]
    if (-not $n) {
        if ($pid_ -eq 0) { $n = 'System Idle / unowned' }
        elseif ($pid_ -eq 4) { $n = 'System' }
        else {
            $gp = Get-Process -Id $pid_ -ErrorAction SilentlyContinue
            $n = if ($gp) { $gp.ProcessName + '.exe' } else { "(pid $pid_)" }
        }
        $names[$pid_] = $n
    }
    return $n
}
function Get-NetRows([hashtable]$names) {
    $list = New-Object 'System.Collections.Generic.List[WhosLocking.NetRow]'
    $tcp = @(); $udp = @()
    try { $tcp = @(Get-NetTCPConnection -ErrorAction Stop) } catch {}
    try { $udp = @(Get-NetUDPEndpoint -ErrorAction Stop) } catch {}
    foreach ($c in $tcp) {
        $r = New-Object WhosLocking.NetRow
        $r.PID = [int]$c.OwningProcess; $r.Process = Resolve-ProcName $names $r.PID
        $r.Protocol = 'TCP'; $r.LocalAddr = $c.LocalAddress; $r.LocalPort = [int]$c.LocalPort
        $r.RemoteAddr = $c.RemoteAddress; $r.RemotePort = [int]$c.RemotePort; $r.State = [string]$c.State
        $list.Add($r)
    }
    foreach ($u in $udp) {
        $r = New-Object WhosLocking.NetRow
        $r.PID = [int]$u.OwningProcess; $r.Process = Resolve-ProcName $names $r.PID
        $r.Protocol = 'UDP'; $r.LocalAddr = $u.LocalAddress; $r.LocalPort = [int]$u.LocalPort
        $r.RemoteAddr = '*'; $r.RemotePort = 0; $r.State = 'Listening'
        $list.Add($r)
    }
    return ,$list
}
$script:NetFilter = [Predicate[object]]{
    param($o)
    $q = $ui.txtNetSearch.Text
    if ([string]::IsNullOrWhiteSpace($q)) { return $true }
    $q = $q.Trim()
    return ((Test-Match $o.Process $q) -or (Test-Match $o.LocalAddr $q) -or (Test-Match $o.RemoteAddr $q) -or
            (Test-Match $o.State $q) -or [string]$o.PID -eq $q -or [string]$o.LocalPort -eq $q -or [string]$o.RemotePort -eq $q)
}
function Update-NetCount {
    if (-not $ui.gridNet.ItemsSource) { return }
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridNet.ItemsSource)
    $shown = 0; foreach ($x in $view) { $shown++ }
    $ui.txtNetInfo.Text = "$shown of $($ui.gridNet.ItemsSource.Count) connection(s) / listener(s)."
}
$script:LoadingNet = $false
function Load-Net {
    if ($LoadingNet) { return }
    $script:LoadingNet = $true
    if (-not $script:AllProcs) { Load-Processes }
    Show-Status 'Reading TCP/UDP tables...'
    $window.Cursor = 'Wait'
    try {
        $rows = Get-NetRows (Get-NameMap)
        $ui.gridNet.ItemsSource = $rows
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridNet.ItemsSource)
        $view.Filter = $NetFilter
        if ($view.SortDescriptions.Count -eq 0) {
            $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Process', 'Ascending')))
            $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Protocol', 'Ascending')))
        }
        Update-NetCount
        Show-Status 'Network connections loaded.'
    } catch {
        $ui.txtNetInfo.Text = "Error: $($_.Exception.Message)"
        Show-Status 'Error'
    } finally { $window.Cursor = $null; $script:LoadingNet = $false }
}
function Goto-Net([int]$pid_) {
    if (-not $ui.gridNet.ItemsSource) { Load-Net }
    $ui.txtNetSearch.Text = [string]$pid_; $ui.tabs.SelectedIndex = 3
}
$ui.btnNetRefresh.Add_Click({ Load-Net })
$ui.txtNetSearch.Add_TextChanged({
    if ($ui.gridNet.ItemsSource) { [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridNet.ItemsSource).Refresh(); Update-NetCount }
})
$ui.gridNet.Add_MouseDoubleClick({ $r = $ui.gridNet.SelectedItem; if ($r) { Goto-Process $r.PID } })

# ---- Actions shared by the menus --------------------------------------------------------
function Export-Grid($grid, [string]$name) {
    if (-not $grid.ItemsSource) { Show-Status 'Nothing to export - load the list first.'; return }
    $d = New-Object Microsoft.Win32.SaveFileDialog
    $d.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $d.FileName = "$name-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
    if (-not $d.ShowDialog($window)) { return }
    $view  = [System.Windows.Data.CollectionViewSource]::GetDefaultView($grid.ItemsSource)
    $items = @(foreach ($x in $view) { $x })        # what is on screen: filtered and sorted
    $props = @($grid.Columns | ForEach-Object { $_.SortMemberPath } | Where-Object { $_ })
    $items | Select-Object $props | Export-Csv -LiteralPath $d.FileName -NoTypeInformation -Encoding UTF8
    Show-Status "Exported $($items.Count) row(s) to $($d.FileName)"
}
function Copy-GridTable($grid, [switch]$SelectedOnly) {
    if (-not $grid.ItemsSource) { return }
    $props = @($grid.Columns | ForEach-Object { $_.SortMemberPath } | Where-Object { $_ })
    $items = if ($SelectedOnly -and $grid.SelectedItems.Count -gt 0) { @($grid.SelectedItems) }
             else { $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($grid.ItemsSource); @(foreach ($x in $view) { $x }) }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine(($grid.Columns | ForEach-Object { [string]$_.Header }) -join "`t")
    foreach ($it in $items) { $null = $sb.AppendLine(($props | ForEach-Object { [string]$it.$_ }) -join "`t") }
    Copy-Text $sb.ToString()
    Show-Status "Copied $($items.Count) row(s) as a table."
}

# Force-close handles inside another process (Unlocker style).
function Close-RemoteHandles([int]$pid_, [string]$procName, $handles, [string]$what) {
    $handles = @($handles)
    if ($handles.Count -eq 0) { Show-Status 'No closable handle known for that row.'; return $false }
    $msg = "Force-close $($handles.Count) handle(s) that $procName (PID $pid_) holds on:`n$what`n`n" +
           "The program keeps running but loses the file. If it was still writing to it, the file can end up corrupted " +
           "or the program can misbehave. Use this for stuck files, not for databases or documents being edited.`n`nContinue?"
    $ans = [System.Windows.MessageBox]::Show($msg, 'Release file', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return $false }
    $problems = @()
    foreach ($h in $handles) {
        try { [WhosLocking.HandleEnum]::CloseRemoteHandle($pid_, [long]$h) }
        catch { $problems += "Handle 0x$([Convert]::ToString([long]$h, 16)): $($_.Exception.Message)" }
    }
    if ($problems) {
        $extra = if (-not $IsAdmin) { "`n`nTry Restart as Administrator." } else { '' }
        [System.Windows.MessageBox]::Show(($problems -join "`n") + $extra, 'Some handles could not be closed', 'OK', 'Warning') | Out-Null
    } else { Show-Status "Released: $what" }
    return $true
}
function Schedule-DeleteOnReboot([string]$p) {
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { Show-Status 'Enter an existing file path first.'; return }
    $isDir = (Get-Item -LiteralPath $p -Force).PSIsContainer
    $ans = [System.Windows.MessageBox]::Show("Delete this on the next restart, before any program can lock it?`n`n$p" +
        $(if ($isDir) { "`n`n(Only empty folders can be scheduled. Files inside must be scheduled first.)" } else { '' }),
        'Delete on next reboot', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    try {
        [WhosLocking.FileOps]::DeleteOnReboot($p)
        [System.Windows.MessageBox]::Show("Scheduled. It will be removed during the next restart.", 'Delete on next reboot', 'OK', 'Information') | Out-Null
    } catch {
        $m = $_.Exception.Message; if ($_.Exception.InnerException) { $m = $_.Exception.InnerException.Message }
        $extra = if (-not $IsAdmin) { "`n`nThis needs Administrator rights - use Restart as Administrator." } else { '' }
        [System.Windows.MessageBox]::Show("Could not schedule: $m$extra", 'Delete on next reboot', 'OK', 'Error') | Out-Null
    }
}
function Get-ArgsFromCommandLine([string]$cl) {
    if (-not $cl) { return '' }
    $cl = $cl.Trim()
    if ($cl.StartsWith('"')) { $i = $cl.IndexOf('"', 1); if ($i -gt 0) { return $cl.Substring($i + 1).Trim() } }
    $i = $cl.IndexOf(' '); if ($i -gt 0) { return $cl.Substring($i + 1).Trim() }
    return ''
}
function Restart-ProcessRow($r) {
    if (-not $r) { return }
    if ($r.ServiceNames) {
        $ans = [System.Windows.MessageBox]::Show("Restart service(s) $($r.ServiceNames)?", 'Restart service', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
        foreach ($svc in ($r.ServiceNames -split ',')) { try { Restart-Service -Name $svc.Trim() -Force -ErrorAction Stop } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'Restart service', 'OK', 'Error') | Out-Null } }
        Load-Processes; return
    }
    if (-not $r.Path) { Show-Status 'Path unknown - cannot restart (try Restart as Administrator).'; return }
    $arguments = Get-ArgsFromCommandLine $r.CommandLine
    if (-not (Stop-Targets @($r))) { return }
    Start-Sleep -Milliseconds 300
    try {
        if ($arguments) { Start-Process -FilePath $r.Path -ArgumentList $arguments -ErrorAction Stop }
        else            { Start-Process -FilePath $r.Path -ErrorAction Stop }
    } catch { [System.Windows.MessageBox]::Show("Ended, but could not start it again:`n$($_.Exception.Message)", 'Restart process', 'OK', 'Error') | Out-Null }
    Load-Processes
}
function Start-AsOtherUser($r) {
    if (-not $r -or -not $r.Path) { Show-Status 'Path unknown.'; return }
    try { Start-Process -FilePath $r.Path -Verb RunAsUser -ErrorAction Stop }
    catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'Run as different user', 'OK', 'Error') | Out-Null }
}
function Open-VirusTotal([string]$p) {
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { Show-Status 'Path unknown.'; return }
    try {
        Show-Status 'Hashing file...'
        $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
        Copy-Text $h
        Start-Process "https://www.virustotal.com/gui/file/$h"
        Show-Status "SHA-256 copied to clipboard and opened on VirusTotal: $h"
    } catch { Show-Status "Could not hash: $($_.Exception.Message)" }
}

# =============================================================================
# Right-click menus + keyboard shortcuts
# =============================================================================
function Copy-Text([string]$t) {
    if ($null -eq $t) { $t = '' }
    try { [System.Windows.Clipboard]::SetText($t); Show-Status "Copied: $t" } catch { Show-Status 'Clipboard busy, try again.' }
}
function Open-Location([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe -ArgumentList "/select,`"$p`"" }
    else { Show-Status "Path not available$(if (-not $IsAdmin) { ' (try Restart as Administrator)' })." }
}
function Search-Online([string]$q) {
    if ($q) { Start-Process ("https://www.google.com/search?q=" + [uri]::EscapeDataString("$q process what is it")) }
}
function Goto-Process([int]$pid_) { $ui.txtSearch.Text = [string]$pid_; $ui.tabs.SelectedIndex = 0 }
function Goto-Files([int]$pid_) {
    if (-not $ui.gridAllFiles.ItemsSource) { Load-AllFiles }
    $ui.txtFileSearch.Text = [string]$pid_; $ui.tabs.SelectedIndex = 1
}
function Goto-Lock([string]$file) { $ui.txtPath.Text = $file; $ui.tabs.SelectedIndex = 2; Run-LockCheck }

function Get-Descendants([int]$pid_) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $AllProcs) {
        if ($r.ParentPID -eq $pid_ -and $r.PID -ne $pid_) { $out.Add($r); foreach ($d in (Get-Descendants $r.PID)) { $out.Add($d) } }
    }
    return ,$out
}

# Right-click selects the row under the mouse (WPF does not do this by itself).
function Select-RowUnderMouse($grid, $e) {
    $dep = $e.OriginalSource
    while ($dep -and -not ($dep -is [System.Windows.Controls.DataGridRow])) {
        if ($dep -is [System.Windows.Media.Visual] -or $dep -is [System.Windows.Media.Media3D.Visual3D]) {
            $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
        } else { $dep = [System.Windows.LogicalTreeHelper]::GetParent($dep) }
    }
    if ($dep) {
        if (-not $dep.IsSelected) { $grid.SelectedItems.Clear(); $dep.IsSelected = $true }
        $grid.CurrentItem = $dep.Item
        $dep.Focus() | Out-Null
    }
}

# items: @{Header; Action; Bold; Key} or '-' for a separator. Returns the menu; $script:MenuItems[Key] = item.
$script:MenuItems = @{}
function New-ContextMenu([array]$items) {
    $cm = New-Object System.Windows.Controls.ContextMenu
    foreach ($it in $items) {
        if ($it -eq '-') { $cm.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null; continue }
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $it.Header
        if ($it.Bold) { $mi.FontWeight = 'SemiBold' }
        if ($it.Gesture) { $mi.InputGestureText = $it.Gesture }
        $mi.Add_Click($it.Action)
        if ($it.Key) { $script:MenuItems[$it.Key] = $mi }
        $cm.Items.Add($mi) | Out-Null
    }
    return $cm
}

# ---- Processes grid ---------------------------------------------------------------
$ui.gridProcs.ContextMenu = New-ContextMenu @(
    @{ Header = 'End process';                 Bold = $true; Gesture = 'Del'; Key = 'p.end'
       Action = { if (Stop-Targets @($ui.gridProcs.SelectedItems)) { Load-Processes } } }
    @{ Header = 'End process tree (with child processes)'; Key = 'p.tree'
       Action = {
           $sel = @($ui.gridProcs.SelectedItems); if ($sel.Count -eq 0) { return }
           $all = New-Object System.Collections.Generic.List[object]
           foreach ($s in $sel) { foreach ($d in (Get-Descendants $s.PID)) { $all.Add($d) } }
           foreach ($s in $sel) { $all.Add($s) }          # children first, parents last
           if (Stop-Targets $all) { Load-Processes } } }
    @{ Header = 'Stop hosted service(s)';      Key = 'p.svc'
       Action = { if (Stop-Targets @($ui.gridProcs.SelectedItems)) { Load-Processes } } }
    '-'
    @{ Header = 'Restart process';             Key = 'p.restart'
       Action = { Restart-ProcessRow $ui.gridProcs.SelectedItem } }
    '-'
    @{ Header = 'Show files this process is using'; Key = 'p.files'
       Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Goto-Files $r.PID } } }
    @{ Header = 'Show network connections';    Key = 'p.net'
       Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Goto-Net $r.PID } } }
    @{ Header = 'Go to parent process';        Key = 'p.parent'
       Action = { $r = $ui.gridProcs.SelectedItem; if ($r -and $r.ParentPID -gt 0) { Goto-Process $r.ParentPID } } }
    @{ Header = 'Open file location';          Key = 'p.loc'
       Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Open-Location $r.Path } } }
    '-'
    @{ Header = 'Check file on VirusTotal';    Key = 'p.vt'
       Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Open-VirusTotal $r.Path } } }
    @{ Header = 'Search online for this process'
       Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Search-Online $r.Name } } }
    @{ Header = 'Run as different user...';    Key = 'p.runas'
       Action = { Start-AsOtherUser $ui.gridProcs.SelectedItem } }
    '-'
    @{ Header = 'Copy PID';          Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Copy-Text ([string]$r.PID) } } }
    @{ Header = 'Copy name';         Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Copy-Text $r.Name } } }
    @{ Header = 'Copy path';         Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Copy-Text $r.Path } } }
    @{ Header = 'Copy command line'; Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Copy-Text $r.CommandLine } } }
    @{ Header = 'Copy selected rows as table'; Gesture = 'Ctrl+C'; Action = { Copy-GridTable $ui.gridProcs -SelectedOnly } }
    @{ Header = 'Copy whole list as table';    Action = { Copy-GridTable $ui.gridProcs } }
    @{ Header = 'Export list to CSV...';        Action = { Export-Grid $ui.gridProcs 'processes' } }
    '-'
    @{ Header = 'Properties';        Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { [System.Windows.MessageBox]::Show($ui.txtDetails.Text, "$($r.Name) ($($r.PID))", 'OK', 'Information') | Out-Null } } }
    @{ Header = 'Refresh list'; Gesture = 'F5'; Action = { Load-Processes } }
)
$ui.gridProcs.Add_PreviewMouseRightButtonDown({ param($s, $e) Select-RowUnderMouse $ui.gridProcs $e })
$ui.gridProcs.Add_ContextMenuOpening({
    $r = $ui.gridProcs.SelectedItem
    $has = ($null -ne $r) -and ($r.Status -ne 'Exited')
    foreach ($k in 'p.end','p.tree','p.files','p.net','p.loc','p.parent','p.restart','p.runas','p.vt') { $MenuItems[$k].IsEnabled = $has }
    $MenuItems['p.svc'].Visibility    = if ($has -and $r.ServiceNames) { 'Visible' } else { 'Collapsed' }
    $MenuItems['p.tree'].IsEnabled    = $has -and ((Get-Descendants $r.PID).Count -gt 0)
    $MenuItems['p.parent'].IsEnabled  = $has -and $r.ParentPID -gt 0
    $MenuItems['p.loc'].IsEnabled     = $has -and [bool]$r.Path
    $MenuItems['p.vt'].IsEnabled      = $has -and [bool]$r.Path
    $MenuItems['p.runas'].IsEnabled   = $has -and [bool]$r.Path
    $MenuItems['p.restart'].IsEnabled = $has -and ([bool]$r.Path -or [bool]$r.ServiceNames)
})
$ui.gridProcs.Add_PreviewKeyDown({ param($s, $e)
    if ($e.Key -eq 'Delete') { $e.Handled = $true; if (Stop-Targets @($ui.gridProcs.SelectedItems)) { Load-Processes } }
})

# ---- Files used by selected process (Processes tab) -------------------------------
$ui.gridFiles.ContextMenu = New-ContextMenu @(
    @{ Header = "Who's locking this file?"; Bold = $true; Action = { $r = $ui.gridFiles.SelectedItem; if ($r) { Goto-Lock $r.File } } }
    @{ Header = 'Release this file (close the handle, keep the program running)'; Key = 'f.close'
       Action = { $r = $ui.gridFiles.SelectedItem; if ($r -and $r.Handle) { if (Close-RemoteHandles $r.PID $r.Process @($r.Handle) $r.File) { Load-SelectedFiles } } } }
    @{ Header = 'Open file location';       Action = { $r = $ui.gridFiles.SelectedItem; if ($r) { Open-Location $r.File } } }
    '-'
    @{ Header = 'Copy path';                Action = { $r = $ui.gridFiles.SelectedItem; if ($r) { Copy-Text $r.File } } }
    @{ Header = 'Copy all listed paths';    Action = { if ($ui.gridFiles.ItemsSource) { Copy-Text ((@($ui.gridFiles.ItemsSource) | ForEach-Object { $_.File }) -join "`n") } } }
    @{ Header = 'Export list to CSV...';    Action = { Export-Grid $ui.gridFiles 'files' } }
)
$ui.gridFiles.Add_ContextMenuOpening({ $r = $ui.gridFiles.SelectedItem; $MenuItems['f.close'].IsEnabled = ($r -and $r.Handle -ne 0) })
$ui.gridFiles.Add_PreviewMouseRightButtonDown({ param($s, $e) Select-RowUnderMouse $ui.gridFiles $e })

# ---- Open files tab grid ----------------------------------------------------------
$ui.gridAllFiles.ContextMenu = New-ContextMenu @(
    @{ Header = 'Go to process';            Bold = $true; Action = { $r = $ui.gridAllFiles.SelectedItem; if ($r) { Goto-Process $r.PID } } }
    @{ Header = "Who's locking this file?"; Action = { $r = $ui.gridAllFiles.SelectedItem; if ($r) { Goto-Lock $r.File } } }
    @{ Header = 'End the process holding it'; Action = {
           $r = $ui.gridAllFiles.SelectedItem; if (-not $r) { return }
           $p = $AllProcs | Where-Object { $_.PID -eq $r.PID } | Select-Object -First 1
           if (-not $p) { $p = [pscustomobject]@{ PID = $r.PID; Name = $r.Process; ServiceNames = '' } }
           if (Stop-Targets @($p)) { Load-AllFiles } } }
    @{ Header = 'Open file location';       Action = { $r = $ui.gridAllFiles.SelectedItem; if ($r) { Open-Location $r.File } } }
    '-'
    @{ Header = 'Copy path';                Action = { $r = $ui.gridAllFiles.SelectedItem; if ($r) { Copy-Text $r.File } } }
    @{ Header = 'Copy PID';                 Action = { $r = $ui.gridAllFiles.SelectedItem; if ($r) { Copy-Text ([string]$r.PID) } } }
    @{ Header = 'Release this file (close the handle, keep the program running)'; Key = 'a.close'
       Action = { $r = $ui.gridAllFiles.SelectedItem; if ($r -and $r.Handle) { if (Close-RemoteHandles $r.PID $r.Process @($r.Handle) $r.File) { Load-AllFiles } } } }
    '-'
    @{ Header = 'Copy selected rows as table'; Gesture = 'Ctrl+C'; Action = { Copy-GridTable $ui.gridAllFiles -SelectedOnly } }
    @{ Header = 'Copy whole list as table';    Action = { Copy-GridTable $ui.gridAllFiles } }
    @{ Header = 'Export list to CSV...';    Action = { Export-Grid $ui.gridAllFiles 'open-files' } }
    '-'
    @{ Header = 'Refresh'; Gesture = 'F5';  Action = { Load-AllFiles } }
)
$ui.gridAllFiles.Add_PreviewMouseRightButtonDown({ param($s, $e) Select-RowUnderMouse $ui.gridAllFiles $e })
$ui.gridAllFiles.Add_ContextMenuOpening({ $r = $ui.gridAllFiles.SelectedItem; $MenuItems['a.close'].IsEnabled = ($r -and $r.Handle -ne 0) })

# ---- Lock tab grid ----------------------------------------------------------------
$ui.gridLock.ContextMenu = New-ContextMenu @(
    @{ Header = 'End process / stop service'; Bold = $true; Gesture = 'Del'
       Action = { if (Stop-Targets @($ui.gridLock.SelectedItems)) { Run-LockCheck } } }
    @{ Header = 'Release the file only (close its handle, keep the program running)'; Key = 'l.close'
       Action = { $r = $ui.gridLock.SelectedItem; if ($r) { if (Close-RemoteHandles $r.PID $r.Name $r.Handles $r.HeldItem) { Run-LockCheck } } } }
    @{ Header = 'Delete this path on next reboot...'; Key = 'l.reboot'
       Action = { Schedule-DeleteOnReboot ($ui.txtPath.Text.Trim().Trim('"')) } }
    '-'
    @{ Header = 'Show in Processes tab';    Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Goto-Process $r.PID } } }
    @{ Header = 'Show all files this process is using'; Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Goto-Files $r.PID } } }
    @{ Header = 'Open file location';       Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Open-Location $r.Path } } }
    @{ Header = 'Search online for this process'; Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Search-Online $r.Name } } }
    '-'
    @{ Header = 'Copy PID';                 Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Copy-Text ([string]$r.PID) } } }
    @{ Header = 'Copy path';                Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Copy-Text $r.Path } } }
    @{ Header = 'Export list to CSV...';    Action = { Export-Grid $ui.gridLock 'locks' } }
    '-'
    @{ Header = 'Check again'; Gesture = 'F5'; Action = { Run-LockCheck } }
)
$ui.gridLock.Add_PreviewMouseRightButtonDown({ param($s, $e) Select-RowUnderMouse $ui.gridLock $e })
$ui.gridLock.Add_ContextMenuOpening({
    $r = $ui.gridLock.SelectedItem
    $MenuItems['l.close'].IsEnabled = ($r -and $r.Handles.Count -gt 0)
    $MenuItems['l.reboot'].IsEnabled = [bool](Test-Path -LiteralPath ($ui.txtPath.Text.Trim().Trim('"')) -ErrorAction SilentlyContinue)
})

# ---- Network grid ----------------------------------------------------------------------
$ui.gridNet.ContextMenu = New-ContextMenu @(
    @{ Header = 'Go to process';            Bold = $true; Action = { $r = $ui.gridNet.SelectedItem; if ($r) { Goto-Process $r.PID } } }
    @{ Header = 'End the process';          Action = {
           $r = $ui.gridNet.SelectedItem; if (-not $r -or $r.PID -le 4) { return }
           $p = $AllProcs | Where-Object { $_.PID -eq $r.PID } | Select-Object -First 1
           if (-not $p) { $p = [pscustomobject]@{ PID = $r.PID; Name = $r.Process; ServiceNames = '' } }
           if (Stop-Targets @($p)) { Load-Net } } }
    '-'
    @{ Header = 'Copy remote address';      Action = { $r = $ui.gridNet.SelectedItem; if ($r) { Copy-Text "$($r.RemoteAddr):$($r.RemotePort)" } } }
    @{ Header = 'Look up remote address online'; Action = { $r = $ui.gridNet.SelectedItem; if ($r -and $r.RemoteAddr -and $r.RemoteAddr -ne '*') { Start-Process "https://www.google.com/search?q=$([uri]::EscapeDataString($r.RemoteAddr + ' ip address'))" } } }
    @{ Header = 'Copy as table (with headers)'; Action = { Copy-GridTable $ui.gridNet } }
    @{ Header = 'Export list to CSV...';    Action = { Export-Grid $ui.gridNet 'network' } }
    '-'
    @{ Header = 'Refresh'; Gesture = 'F5';  Action = { Load-Net } }
)
$ui.gridNet.Add_PreviewMouseRightButtonDown({ param($s, $e) Select-RowUnderMouse $ui.gridNet $e })
$ui.gridLock.Add_PreviewKeyDown({ param($s, $e)
    if ($e.Key -eq 'Delete') { $e.Handled = $true; if (Stop-Targets @($ui.gridLock.SelectedItems)) { Run-LockCheck } }
})

# ---- Window-level keys -------------------------------------------------------------
$window.Add_PreviewKeyDown({ param($s, $e)
    if ($e.Key -eq 'F5') {
        $e.Handled = $true
        switch ($ui.tabs.SelectedIndex) { 0 { Load-Processes } 1 { Load-AllFiles } 2 { Run-LockCheck } 3 { Load-Net } }
    }
    elseif ($e.Key -eq 'F' -and $e.KeyboardDevice.Modifiers -eq 'Control') {
        $e.Handled = $true
        switch ($ui.tabs.SelectedIndex) { 0 { $ui.txtSearch.Focus() } 1 { $ui.txtFileSearch.Focus() } 2 { $ui.txtPath.Focus() } 3 { $ui.txtNetSearch.Focus() } }
    }
    elseif ($e.Key -eq 'Escape') {
        $f = [System.Windows.Input.Keyboard]::FocusedElement
        if ($f -is [System.Windows.Controls.TextBox] -and $Placeholders.ContainsKey($f.Name) -and $f.Text) { $f.Text = ''; $e.Handled = $true }
    }
})

# =============================================================================
# Start
# =============================================================================
if ($Path) { $ui.txtPath.Text = $Path; $ui.tabs.SelectedIndex = 2 }

if ($SelfTest) {
    Load-Processes
    $ui.txtSearch.Text = 'explorer'
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridProcs.ItemsSource)
    $n = 0; foreach ($x in $view) { $n++ }
    Write-Host "SelfTest: $($AllProcs.Count) processes loaded, $n match 'explorer'"
    if ($Path) { Run-LockCheck; Write-Host "SelfTest lock: $($ui.txtLockInfo.Text)"; $ui.gridLock.ItemsSource | Format-Table PID, Name, Type, User, Path -AutoSize | Out-String | Write-Host }
    Write-Host "SelfTest status: $($ui.txtStatus.Text)"
    $ui.gridProcs.SelectedIndex = 0
    $FilesTimer.Stop(); Load-SelectedFiles
    Write-Host "SelfTest selected-files: $($ui.txtFilesHeader.Text)"
    Load-AllFiles
    Write-Host "SelfTest all-files: $($ui.txtAllFilesInfo.Text)"
    foreach ($g in 'gridProcs','gridFiles','gridAllFiles','gridLock') {
        $cm = $ui[$g].ContextMenu
        $hdrs = ($cm.Items | Where-Object { $_ -is [System.Windows.Controls.MenuItem] } | ForEach-Object { $_.Header }) -join ' | '
        Write-Host "SelfTest menu ${g}: $hdrs"
    }
    $sel = $ui.gridProcs.SelectedItem
    Write-Host "SelfTest descendants of $($sel.Name): $((Get-Descendants $sel.PID).Count)"
    $t = Measure-Command {
        Update-Signers
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($SigJob -and $sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 100; $window.Dispatcher.Invoke([action]{}, 'Background') }
    }
    $signed = @($AllProcs | Where-Object { $_.Path -and $_.Signer -and $_.Signer -ne 'Unsigned' -and $_.Signer -notlike 'Invalid*' }).Count
    Write-Host "SelfTest signers: $signed signed of $(@($AllProcs | Where-Object { $_.Path }).Count) with a path, in $([int]$t.TotalMilliseconds) ms (background); explorer -> '$($sel.Signer)'"
    Load-Net
    Write-Host "SelfTest network: $($ui.txtNetInfo.Text)"
    Start-Sleep -Milliseconds 600; Load-Processes
    $withCpu = @($AllProcs | Where-Object { $_.CpuPercent -gt 0 }).Count
    Write-Host "SelfTest cpu: $withCpu process(es) with CPU > 0 after second refresh; exited rows: $(@($AllProcs | Where-Object { $_.Status -eq 'Exited' }).Count)"
    Write-Host "SelfTest args: [$(Get-ArgsFromCommandLine '"C:\Program Files\x y\a.exe" --flag "v w"')] [$(Get-ArgsFromCommandLine 'notepad.exe c:\t.txt')] [$(Get-ArgsFromCommandLine '"C:\a.exe"')]"
    $icons = @($AllProcs | Where-Object { $_.Icon }).Count
    $unknown = @($AllProcs | Where-Object { Test-Unknown $_ }).Count
    Write-Host "SelfTest icons: $icons of $($AllProcs.Count) rows have an icon; unknown/unsigned: $unknown; cache sizes path=$($PathInfoCache.Count) user=$($UserCache.Count) icon=$($IconCache.Count)"
    $t2 = Measure-Command { Load-Processes -Auto }
    Write-Host "SelfTest cached refresh: $([int]$t2.TotalMilliseconds) ms"
    $window.WindowStartupLocation = 'Manual'; $window.Left = -5000; $window.Top = -5000   # off-screen
    $window.Show(); $window.Dispatcher.Invoke([action]{}, 'Loaded')     # canvases need a size for the charts
    Update-Metrics; Start-Sleep -Milliseconds 700; Update-Metrics
    Write-Host "SelfTest metrics: cpu='$($ui.mCpu.Text)' mem='$($ui.mMem.Text)' disk='$($ui.mDisk.Text)' net='$($ui.mNet.Text)' points=$($ui.lCpu.Points.Count) proc='$($ui.mProc.Text)' diskcounter=$($null -ne $DiskCounter)"
    if (-not $Screenshot) { $window.Close() }
    if ($Screenshot) {
        if ($Dark) {
            try { Set-Theme $true; $ui.chkDark.IsChecked = $true }
            catch { Write-Host "SelfTest theme error: $($_.Exception.ToString())`n$($_.ScriptStackTrace)"; throw }
        }
        if ($ShowTab -ge 0) { $ui.tabs.SelectedIndex = $ShowTab }
        $window.Left = -5000; $window.Top = -5000   # off-screen
        $window.Dispatcher.Invoke([action]{}, 'Loaded')
        Update-Metrics
        $root = $window.Content
        $w = [int]$root.ActualWidth; $h = [int]$root.ActualHeight
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($root)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($Screenshot); $enc.Save($fs); $fs.Close()
        $window.Close()
        Write-Host "SelfTest screenshot: $Screenshot (${w}x${h})"
    }
    return
}

# ---- Application loop + system tray --------------------------------------------------
$script:Exiting  = $false
$script:TrayMode = [bool]$Tray
$script:Loaded   = $false
$script:TrayTipShown = $false

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
# An exception that escapes an event handler would otherwise end the message loop and the app
# with it, silently when hosted in the exe. Log it, tell the user, keep running.
$app.Add_DispatcherUnhandledException({ param($s, $e)
    Write-ErrorLog 'unhandled' $e.Exception
    try { Show-Status "Error: $($e.Exception.Message)   (details in $ErrorLog)" } catch {}
    $e.Handled = $true
})

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text = 'Process Inspector'
$notify.Icon = if (Test-Path $IconPath) { New-Object System.Drawing.Icon($IconPath) } else { [System.Drawing.SystemIcons]::Application }

function Show-MainWindow {
    $wasHidden = -not $window.IsVisible
    $window.Show()
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    $window.Activate() | Out-Null
    if ($wasHidden -and $Loaded) {
        # re-opened from the tray: refresh in the background so the list is current
        $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Load-Processes }) | Out-Null
    }
}
function Exit-App {
    $script:Exiting = $true
    if ($window.IsVisible -or $window.IsLoaded) { $window.Close() } else { Stop-App }
}
function Stop-App {
    try { $ipcTimer.Stop(); $ActivateEvent.Dispose() } catch {}
    try { $notify.Visible = $false; $notify.Dispose() } catch {}
    try { $Mutex.ReleaseMutex(); $Mutex.Dispose() } catch {}
    $global:ProcessInspectorExited = $true       # tells ProcessInspector.exe this was a clean exit
    $app.Shutdown()
}

# Requests from a second copy of the app (see the single-instance block at the top).
$script:ActivateEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', "Local\ProcessInspector.Activate$IpcSuffix")
$script:ipcTimer = New-Object System.Windows.Threading.DispatcherTimer
$ipcTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$ipcTimer.Add_Tick({
    try {
        if (-not $ActivateEvent.WaitOne(0)) { return }
        $mode = 'show'; $p = ''
        try {
            $lines = [IO.File]::ReadAllLines($IpcFile)
            if ($lines.Count -ge 1) { $mode = $lines[0] }
            if ($lines.Count -ge 2) { $p = $lines[1] }
        } catch {}
        if ($mode -ne 'silent') { Show-MainWindow }
        if ($p) { $ui.txtPath.Text = $p; $ui.tabs.SelectedIndex = 2; Run-LockCheck }
    } catch { Write-ErrorLog 'activate' $_ }
})
$ipcTimer.Start()

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $trayMenu.Items.Add('Open Process Inspector', $null, { Show-MainWindow })
$null = $trayMenu.Items.Add("Who's locking a file...", $null, { Show-MainWindow; $ui.tabs.SelectedIndex = 2; $ui.txtPath.Focus() | Out-Null })
$null = $trayMenu.Items.Add('Open files of all processes', $null, { Show-MainWindow; $ui.tabs.SelectedIndex = 1; Load-AllFiles })
$null = $trayMenu.Items.Add('-')
$null = $trayMenu.Items.Add('Exit', $null, { Exit-App })
$notify.ContextMenuStrip = $trayMenu
$notify.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-MainWindow } })
$notify.Visible = $true

$window.Add_ContentRendered({
    $window.Activate() | Out-Null
    if (-not $Loaded) { $script:Loaded = $true; Load-Processes }
    if ($Path) { Run-LockCheck }
})
$window.Add_Closing({ param($s, $e)
    Save-Settings
    if ($TrayMode -and -not $Exiting) {
        $e.Cancel = $true
        $window.Hide()
        if (-not $TrayTipShown) {
            $script:TrayTipShown = $true
            $notify.ShowBalloonTip(3000, 'Process Inspector', 'Still running in the tray. Right-click the tray icon to exit.', 'Info')
        }
    }
})
$window.Add_Closed({ Stop-App })

Apply-Settings
if ($ui.chkAutoRefresh.IsChecked) { $AutoTimer.Start() }
$MetricsTimer.Start()
if ($TrayMode -and -not $Show) { <# stay hidden until the tray icon is clicked #> } else { $window.Show() }
$app.Run() | Out-Null
