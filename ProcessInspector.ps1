<#
.SYNOPSIS
  Process Inspector - a window with two tabs:
    1. Processes        : every running process, who it runs as, what started it,
                          which services it hosts. Live search, sort, end process.
    2. Who's locking?   : pick / drop a file or folder and see which processes hold
                          it open. End the process or stop the service from there.

.EXAMPLE
  .\ProcessInspector.ps1
  .\ProcessInspector.ps1 -Path "C:\some\locked\file.mdf"     # opens on the lock tab
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$Tray,        # start hidden in the system tray (used by "start automatically")
    [switch]$Show,        # with -Tray: show the window immediately but keep tray behaviour
    [switch]$SelfTest,    # build everything, run the data functions, exit (no window shown)
    [string]$Screenshot,  # with -SelfTest: render the window to this PNG file
    [int]$ShowTab = -1    # with -Screenshot: which tab to show
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:AppRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ExePath = $env:PROCESS_INSPECTOR_EXE          # set by ProcessInspector.exe when hosting this script
$script:AppVersion = '1.0.0'

# =============================================================================
# Native helpers + row types
# =============================================================================
if (-not ('WhosLocking.RestartManager' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WhosLocking {

public class ProcRow {
    public int      PID          { get; set; }
    public string   Name         { get; set; }
    public string   Description  { get; set; }
    public string   Company      { get; set; }
    public string   User         { get; set; }
    public string   Parent       { get; set; }
    public int      ParentPID    { get; set; }
    public string   Services     { get; set; }   // display labels
    public string   ServiceNames { get; set; }   // short names, comma separated
    public string   UsedBy       { get; set; }
    public double   MemoryMB     { get; set; }
    public DateTime? Started     { get; set; }
    public string   Path         { get; set; }
    public string   CommandLine  { get; set; }
}

public class LockRow {
    public int      PID          { get; set; }
    public string   Name         { get; set; }
    public string   Description  { get; set; }
    public string   Type         { get; set; }
    public string   ServiceNames { get; set; }
    public string   User         { get; set; }
    public DateTime? Started     { get; set; }
    public string   Path         { get; set; }
}

public static class ProcUser {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr tok);
    public static string Get(int pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return null;
        try {
            IntPtr tok;
            if (!OpenProcessToken(h, 0x0008, out tok)) return null;
            try { using (var id = new System.Security.Principal.WindowsIdentity(tok)) return id.Name; }
            finally { CloseHandle(tok); }
        } finally { CloseHandle(h); }
    }
}

public static class RestartManager {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string strServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId;
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

    public class Locker { public int Pid; public string AppName; public string ServiceName; public int AppType; }

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
            while (rc == 234) {
                var buf = new RM_PROCESS_INFO[needed];
                count = needed;
                rc = RmGetList(session, out needed, ref count, buf, ref reasons);
                if (rc == 0)
                    for (int i = 0; i < count; i++)
                        result.Add(new Locker { Pid = buf[i].Process.dwProcessId, AppName = buf[i].strAppName,
                                                ServiceName = buf[i].strServiceShortName, AppType = buf[i].ApplicationType });
            }
            if (rc != 0) throw new Exception("RmGetList failed (" + rc + ")");
        } finally { RmEndSession(session); }
        return result;
    }
}
}
'@
}

if (-not ('WhosLocking.HandleEnum' -as [type])) { Add-Type -Path (Join-Path $AppRoot 'HandleEnum.cs') }

# =============================================================================
# Data functions
# =============================================================================
function Get-ProcessRows {
    $cim   = Get-CimInstance Win32_Process
    $procs = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procs[$_.Id] = $_ }

    $svcByPid = @{}
    foreach ($s in (Get-CimInstance Win32_Service | Where-Object { $_.ProcessId -gt 0 })) {
        $k = [int]$s.ProcessId
        if (-not $svcByPid.ContainsKey($k)) { $svcByPid[$k] = @() }
        $svcByPid[$k] += ,$s
    }
    $nameByPid = @{}
    foreach ($c in $cim) { $nameByPid[[int]$c.ProcessId] = $c.Name }

    $list = New-Object 'System.Collections.Generic.List[WhosLocking.ProcRow]'
    foreach ($c in $cim) {
        $pid_ = [int]$c.ProcessId
        $p    = $procs[$pid_]
        $r    = New-Object WhosLocking.ProcRow
        $r.PID  = $pid_
        $r.Name = $c.Name
        $r.User = [WhosLocking.ProcUser]::Get($pid_)
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
        if ($p) {
            try { $r.Description = $p.MainModule.FileVersionInfo.FileDescription } catch {}
            try { $r.Company     = $p.MainModule.FileVersionInfo.CompanyName } catch {}
            if (-not $r.Path) { try { $r.Path = $p.Path } catch {} }
        }
        if (-not $r.Description) { $r.Description = '' }
        $r.UsedBy = if ($r.Services) { "Hosts service: $($r.Services)" } elseif ($r.Parent) { "Started by: $($r.Parent)" } else { '' }
        $r.MemoryMB = [math]::Round($c.WorkingSetSize / 1MB, 1)
        if ($c.CreationDate) { $r.Started = $c.CreationDate }
        $r.CommandLine = $c.CommandLine
        $list.Add($r)
    }
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

function Find-LockRows([string[]]$files) {
    $lockers = @{}
    $batch = 500
    for ($i = 0; $i -lt $files.Count; $i += $batch) {
        $end = [Math]::Min($i + $batch, $files.Count) - 1
        foreach ($l in [WhosLocking.RestartManager]::Find([string[]]$files[$i..$end])) {
            if (-not $lockers.ContainsKey($l.Pid)) { $lockers[$l.Pid] = $l }
        }
    }
    $list = New-Object 'System.Collections.Generic.List[WhosLocking.LockRow]'
    foreach ($l in $lockers.Values) {
        $proc = Get-Process -Id $l.Pid -ErrorAction SilentlyContinue
        $r = New-Object WhosLocking.LockRow
        $r.PID = $l.Pid
        $r.Name = if ($proc) { $proc.ProcessName } else { '(exited)' }
        $r.Description = $l.AppName
        $r.ServiceNames = $l.ServiceName
        $r.Type = if ($l.ServiceName) { "Service ($($l.ServiceName))" } else { $typeNames[$l.AppType] }
        $r.User = [WhosLocking.ProcUser]::Get($l.Pid)
        if ($proc) {
            try { $r.Path = $proc.Path } catch {}
            try { $r.Started = $proc.StartTime } catch {}
        }
        $list.Add($r)
    }
    return ,$list
}

# Files a process (or every process when $pid_ = -1) currently has open.
function Get-OpenFileRows([int]$pid_, [bool]$includeModules, [hashtable]$names) {
    $list = New-Object 'System.Collections.Generic.List[WhosLocking.FileRow]'
    foreach ($f in [WhosLocking.HandleEnum]::GetFiles($pid_)) {
        $r = New-Object WhosLocking.FileRow
        $r.PID = $f.Pid; $r.Process = $names[[int]$f.Pid]; $r.Kind = 'Open file'; $r.File = $f.Path
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
    # $items: objects with PID, Name, ServiceNames
    $items = @($items)
    if ($items.Count -eq 0) { Show-Status 'Nothing selected.'; return $false }
    $desc = ($items | ForEach-Object {
        $s = "$($_.Name)  (PID $($_.PID))"
        if ($_.ServiceNames) { $s += "   -> will STOP service(s): $($_.ServiceNames)" }
        $s }) -join "`n"
    $ans = [System.Windows.MessageBox]::Show("End the following?`n`n$desc", 'Confirm', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return $false }

    $problems = @()
    foreach ($it in $items) {
        $base = [IO.Path]::GetFileNameWithoutExtension($it.Name)
        if ($criticalNames -contains $base -and -not $it.ServiceNames) {
            $problems += "Skipped critical system process $($it.Name) ($($it.PID))."; continue
        }
        try {
            if ($it.ServiceNames) {
                foreach ($svc in ($it.ServiceNames -split ',')) { Stop-Service -Name $svc.Trim() -Force -ErrorAction Stop }
            } else {
                Stop-Process -Id $it.PID -Force -ErrorAction Stop
            }
        } catch {
            $m = $_.Exception.Message
            if (-not $script:IsAdmin) { $m += "  (try Restart as Administrator)" }
            $problems += "$($it.Name) ($($it.PID)): $m"
        }
    }
    if ($problems) { [System.Windows.MessageBox]::Show(($problems -join "`n"), 'Some items could not be ended', 'OK', 'Warning') | Out-Null }
    Start-Sleep -Milliseconds 400
    return $true
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
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12" Background="#F3F3F3">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="MinWidth" Value="90"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#E3E3E3"/>
      <Setter Property="AlternatingRowBackground" Value="#F7F9FC"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="RowHeaderWidth" Value="0"/>
      <Setter Property="SelectionMode" Value="Extended"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="BorderBrush" Value="#CCCCCC"/>
      <Setter Property="RowHeight" Value="24"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Background" Value="#EDEDED"/>
      <Setter Property="BorderBrush" Value="#CCCCCC"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="Padding" Value="4,0"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
  </Window.Resources>

  <DockPanel>
    <Border DockPanel.Dock="Bottom" Background="#E8E8E8" Padding="8,4">
      <TextBlock x:Name="txtStatus" Text="Ready"/>
    </Border>

    <TabControl x:Name="tabs" Margin="8">

      <!-- ================= Processes ================= -->
      <TabItem Header="   Processes   ">
        <Grid Margin="8">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <DockPanel Grid.Row="0" Margin="0,0,0,8">
            <Button x:Name="btnAdmin"    DockPanel.Dock="Right" Content="Restart as Administrator"/>
            <Button x:Name="btnOpenLoc"  DockPanel.Dock="Right" Content="Open file location"/>
            <Button x:Name="btnKillProc" DockPanel.Dock="Right" Content="End process"/>
            <Button x:Name="btnRefresh"  DockPanel.Dock="Right" Content="Refresh"/>
            <TextBlock Text="Search:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="txtSearch"/>
          </DockPanel>

          <DataGrid x:Name="gridProcs" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTextColumn Header="PID"         Binding="{Binding PID}"         Width="60"/>
              <DataGridTextColumn Header="Name"        Binding="{Binding Name}"        Width="160"/>
              <DataGridTextColumn Header="Description" Binding="{Binding Description}" Width="200"/>
              <DataGridTextColumn Header="User"        Binding="{Binding User}"        Width="150"/>
              <DataGridTextColumn Header="Used by / started by" Binding="{Binding UsedBy}" Width="320"/>
              <DataGridTextColumn Header="Memory (MB)" Binding="{Binding MemoryMB}"    Width="90"/>
              <DataGridTextColumn Header="Started"     Binding="{Binding Started, StringFormat=g}" Width="130"/>
              <DataGridTextColumn Header="Path"        Binding="{Binding Path}"        Width="*"/>
            </DataGrid.Columns>
          </DataGrid>

          <Grid Grid.Row="2" Margin="0,8,0,0" Height="230">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="2*"/>
              <ColumnDefinition Width="3*"/>
            </Grid.ColumnDefinitions>
            <GroupBox Grid.Column="0" Header="Details of selected process" Margin="0,0,4,0">
              <TextBox x:Name="txtDetails" IsReadOnly="True" TextWrapping="Wrap"
                       VerticalScrollBarVisibility="Auto" BorderThickness="0" Background="Transparent"/>
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
            <TextBlock Text="Search:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="txtFileSearch"/>
          </DockPanel>
          <TextBlock Grid.Row="1" x:Name="txtAllFilesInfo" Foreground="#666" Margin="0,0,0,8"
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
            <TextBlock Text="File or folder:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="txtPath" AllowDrop="True"/>
          </DockPanel>
          <TextBlock Grid.Row="1" Text="Tip: you can also drag a file or folder from Explorer onto the box above."
                     Foreground="#666" Margin="0,0,0,8"/>

          <DataGrid x:Name="gridLock" Grid.Row="2">
            <DataGrid.Columns>
              <DataGridTextColumn Header="PID"         Binding="{Binding PID}"         Width="60"/>
              <DataGridTextColumn Header="Process"     Binding="{Binding Name}"        Width="160"/>
              <DataGridTextColumn Header="Description" Binding="{Binding Description}" Width="220"/>
              <DataGridTextColumn Header="Type"        Binding="{Binding Type}"        Width="180"/>
              <DataGridTextColumn Header="User"        Binding="{Binding User}"        Width="150"/>
              <DataGridTextColumn Header="Started"     Binding="{Binding Started, StringFormat=g}" Width="130"/>
              <DataGridTextColumn Header="Path"        Binding="{Binding Path}"        Width="*"/>
            </DataGrid.Columns>
          </DataGrid>

          <DockPanel Grid.Row="3" Margin="0,8,0,0">
            <Button x:Name="btnAdmin2"     DockPanel.Dock="Right" Content="Restart as Administrator"/>
            <Button x:Name="btnShowInList" DockPanel.Dock="Right" Content="Show in Processes tab"/>
            <Button x:Name="btnKillLock"   DockPanel.Dock="Right" Content="End process / stop service"/>
            <TextBlock x:Name="txtLockInfo" VerticalAlignment="Center" Foreground="#444"/>
          </DockPanel>
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
               'txtFilesHeader','chkModules','gridFiles','btnLoadAllFiles','chkAllModules','txtFileSearch','txtAllFilesInfo','gridAllFiles') {
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

function Show-Status([string]$t) { $ui.txtStatus.Text = $t; $ui.txtStatus.Dispatcher.Invoke([action]{}, 'Render') }

# ---- Processes tab ------------------------------------------------------------
$script:ProcFilter = [Predicate[object]]{
    param($o)
    $q = $ui.txtSearch.Text
    if ([string]::IsNullOrWhiteSpace($q)) { return $true }
    $q = $q.Trim()
    return ($o.Name -like "*$q*" -or $o.Description -like "*$q*" -or $o.Services -like "*$q*" -or
            $o.Path -like "*$q*" -or $o.User -like "*$q*" -or $o.Parent -like "*$q*" -or
            [string]$o.PID -eq $q -or $o.CommandLine -like "*$q*")
}

function Load-Processes {
    Show-Status 'Collecting processes...'
    $window.Cursor = 'Wait'
    try {
        $script:AllProcs = Get-ProcessRows
        $ui.gridProcs.ItemsSource = $AllProcs
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridProcs.ItemsSource)
        $view.Filter = $ProcFilter
        Update-ProcCount
    } finally { $window.Cursor = $null }
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
$ui.btnRefresh.Add_Click({ Load-Processes })
$ui.btnAdmin.Add_Click({ Restart-Elevated $ui.txtPath.Text })
$ui.btnAdmin2.Add_Click({ Restart-Elevated $ui.txtPath.Text })

$ui.gridProcs.Add_SelectionChanged({
    $r = $ui.gridProcs.SelectedItem
    if (-not $r) { $ui.txtDetails.Text = ''; return }
    $lines = @(
        "$($r.Name)  (PID $($r.PID))   $($r.Description)   $($r.Company)"
        "User:        $($r.User)"
        "Started by:  $($r.Parent)"
        "Services:    $($r.Services)"
        "Started:     $($r.Started)"
        "Path:        $($r.Path)"
        "Command:     $($r.CommandLine)"
    )
    $ui.txtDetails.Text = $lines -join "`n"
    Load-SelectedFiles
})

function Get-NameMap {
    $m = @{}
    if ($script:AllProcs) { foreach ($r in $AllProcs) { $m[[int]$r.PID] = $r.Name } }
    return $m
}

function Load-SelectedFiles {
    $r = $ui.gridProcs.SelectedItem
    $ui.gridFiles.ItemsSource = $null
    if (-not $r) { $ui.txtFilesHeader.Text = 'Files used by selected process'; return }
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
function Run-LockCheck {
    $p = $ui.txtPath.Text.Trim().Trim('"')
    if (-not $p) { Show-Status 'Enter or drop a path first.'; return }
    $window.Cursor = 'Wait'
    try {
        Show-Status 'Collecting files...'
        $files = Get-FilesUnder $p
        if ($files.Count -eq 0) { $ui.gridLock.ItemsSource = $null; $ui.txtLockInfo.Text = 'Folder is empty.'; Show-Status 'Ready'; return }
        Show-Status "Checking $($files.Count) file(s)..."
        try {
            $rows = Find-LockRows $files
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
        if ($rows.Count -eq 0) {
            $ui.txtLockInfo.Text = 'No process is holding it open' + $(if (-not $IsAdmin) { ' (as far as a non-admin can see).' } else { '.' })
        } else {
            $ui.txtLockInfo.Text = "Held open by $($rows.Count) process(es). Select one and click 'End process / stop service' to release it."
        }
        Show-Status "Checked $($files.Count) file(s)."
    } catch {
        $ui.txtLockInfo.Text = "Error: $($_.Exception.Message)"
        Show-Status 'Error'
    } finally { $window.Cursor = $null }
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
    return ($o.File -like "*$q*" -or $o.Process -like "*$q*" -or [string]$o.PID -eq $q)
}
function Update-FileCount {
    if (-not $ui.gridAllFiles.ItemsSource) { return }
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridAllFiles.ItemsSource)
    $shown = 0; foreach ($x in $view) { $shown++ }
    $total = $ui.gridAllFiles.ItemsSource.Count
    $procs = @($ui.gridAllFiles.ItemsSource | Select-Object -ExpandProperty PID -Unique).Count
    $msg = "$shown of $total file(s) across $procs process(es)."
    if (-not $IsAdmin) { $msg += '  Not elevated: files held by services / other users are not visible.' }
    $ui.txtAllFilesInfo.Text = $msg
}
function Load-AllFiles {
    if (-not $script:AllProcs) { Load-Processes }
    Show-Status 'Scanning open handles of every process...'
    $window.Cursor = 'Wait'
    try {
        $rows = Get-OpenFileRows -1 ([bool]$ui.chkAllModules.IsChecked) (Get-NameMap)
        $ui.gridAllFiles.ItemsSource = $rows
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ui.gridAllFiles.ItemsSource)
        $view.Filter = $FileFilter
        Update-FileCount
        Show-Status "Open files loaded."
    } catch {
        $ui.txtAllFilesInfo.Text = "Error: $($_.Exception.Message)"
        Show-Status 'Error'
    } finally { $window.Cursor = $null }
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
    @{ Header = 'Show files this process is using'; Key = 'p.files'
       Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Goto-Files $r.PID } } }
    @{ Header = 'Go to parent process';        Key = 'p.parent'
       Action = { $r = $ui.gridProcs.SelectedItem; if ($r -and $r.ParentPID -gt 0) { Goto-Process $r.ParentPID } } }
    @{ Header = 'Open file location';          Key = 'p.loc'
       Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Open-Location $r.Path } } }
    @{ Header = 'Search online for this process'
       Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Search-Online $r.Name } } }
    '-'
    @{ Header = 'Copy PID';          Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Copy-Text ([string]$r.PID) } } }
    @{ Header = 'Copy name';         Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Copy-Text $r.Name } } }
    @{ Header = 'Copy path';         Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Copy-Text $r.Path } } }
    @{ Header = 'Copy command line'; Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { Copy-Text $r.CommandLine } } }
    @{ Header = 'Copy selected row(s)'; Gesture = 'Ctrl+C'
       Action = { $t = (@($ui.gridProcs.SelectedItems) | ForEach-Object { "$($_.PID)`t$($_.Name)`t$($_.Description)`t$($_.User)`t$($_.UsedBy)`t$($_.Path)" }) -join "`n"; Copy-Text $t } }
    '-'
    @{ Header = 'Properties';        Action = { $r = $ui.gridProcs.SelectedItem; if ($r) { [System.Windows.MessageBox]::Show($ui.txtDetails.Text, "$($r.Name) ($($r.PID))", 'OK', 'Information') | Out-Null } } }
    @{ Header = 'Refresh list'; Gesture = 'F5'; Action = { Load-Processes } }
)
$ui.gridProcs.Add_PreviewMouseRightButtonDown({ param($s, $e) Select-RowUnderMouse $ui.gridProcs $e })
$ui.gridProcs.Add_ContextMenuOpening({
    $r = $ui.gridProcs.SelectedItem
    $has = $null -ne $r
    foreach ($k in 'p.end','p.tree','p.files','p.loc','p.parent') { $MenuItems[$k].IsEnabled = $has }
    $MenuItems['p.svc'].Visibility    = if ($has -and $r.ServiceNames) { 'Visible' } else { 'Collapsed' }
    $MenuItems['p.tree'].IsEnabled    = $has -and ((Get-Descendants $r.PID).Count -gt 0)
    $MenuItems['p.parent'].IsEnabled  = $has -and $r.ParentPID -gt 0
    $MenuItems['p.loc'].IsEnabled     = $has -and [bool]$r.Path
})
$ui.gridProcs.Add_PreviewKeyDown({ param($s, $e)
    if ($e.Key -eq 'Delete') { $e.Handled = $true; if (Stop-Targets @($ui.gridProcs.SelectedItems)) { Load-Processes } }
})

# ---- Files used by selected process (Processes tab) -------------------------------
$ui.gridFiles.ContextMenu = New-ContextMenu @(
    @{ Header = "Who's locking this file?"; Bold = $true; Action = { $r = $ui.gridFiles.SelectedItem; if ($r) { Goto-Lock $r.File } } }
    @{ Header = 'Open file location';       Action = { $r = $ui.gridFiles.SelectedItem; if ($r) { Open-Location $r.File } } }
    '-'
    @{ Header = 'Copy path';                Action = { $r = $ui.gridFiles.SelectedItem; if ($r) { Copy-Text $r.File } } }
    @{ Header = 'Copy all listed paths';    Action = { if ($ui.gridFiles.ItemsSource) { Copy-Text ((@($ui.gridFiles.ItemsSource) | ForEach-Object { $_.File }) -join "`n") } } }
)
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
    @{ Header = 'Copy selected row(s)'; Gesture = 'Ctrl+C'
       Action = { Copy-Text ((@($ui.gridAllFiles.SelectedItems) | ForEach-Object { "$($_.PID)`t$($_.Process)`t$($_.Kind)`t$($_.File)" }) -join "`n") } }
    '-'
    @{ Header = 'Refresh'; Gesture = 'F5';  Action = { Load-AllFiles } }
)
$ui.gridAllFiles.Add_PreviewMouseRightButtonDown({ param($s, $e) Select-RowUnderMouse $ui.gridAllFiles $e })

# ---- Lock tab grid ----------------------------------------------------------------
$ui.gridLock.ContextMenu = New-ContextMenu @(
    @{ Header = 'End process / stop service'; Bold = $true; Gesture = 'Del'
       Action = { if (Stop-Targets @($ui.gridLock.SelectedItems)) { Run-LockCheck } } }
    @{ Header = 'Show in Processes tab';    Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Goto-Process $r.PID } } }
    @{ Header = 'Show all files this process is using'; Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Goto-Files $r.PID } } }
    @{ Header = 'Open file location';       Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Open-Location $r.Path } } }
    @{ Header = 'Search online for this process'; Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Search-Online $r.Name } } }
    '-'
    @{ Header = 'Copy PID';                 Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Copy-Text ([string]$r.PID) } } }
    @{ Header = 'Copy path';                Action = { $r = $ui.gridLock.SelectedItem; if ($r) { Copy-Text $r.Path } } }
    '-'
    @{ Header = 'Check again'; Gesture = 'F5'; Action = { Run-LockCheck } }
)
$ui.gridLock.Add_PreviewMouseRightButtonDown({ param($s, $e) Select-RowUnderMouse $ui.gridLock $e })
$ui.gridLock.Add_PreviewKeyDown({ param($s, $e)
    if ($e.Key -eq 'Delete') { $e.Handled = $true; if (Stop-Targets @($ui.gridLock.SelectedItems)) { Run-LockCheck } }
})

# ---- Window-level keys -------------------------------------------------------------
$window.Add_PreviewKeyDown({ param($s, $e)
    if ($e.Key -eq 'F5') {
        $e.Handled = $true
        switch ($ui.tabs.SelectedIndex) { 0 { Load-Processes } 1 { Load-AllFiles } 2 { Run-LockCheck } }
    }
    elseif ($e.Key -eq 'F' -and $e.KeyboardDevice.Modifiers -eq 'Control') {
        $e.Handled = $true
        switch ($ui.tabs.SelectedIndex) { 0 { $ui.txtSearch.Focus() } 1 { $ui.txtFileSearch.Focus() } 2 { $ui.txtPath.Focus() } }
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
    if ($Screenshot) {
        if ($ShowTab -ge 0) { $ui.tabs.SelectedIndex = $ShowTab }
        $window.WindowStartupLocation = 'Manual'; $window.Left = -5000; $window.Top = -5000   # off-screen
        $window.Show()
        $window.Dispatcher.Invoke([action]{}, 'Loaded')
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
        $window.Dispatcher.BeginInvoke([action]{ Load-Processes }, 'Background') | Out-Null
    }
}
function Exit-App {
    $script:Exiting = $true
    if ($window.IsVisible -or $window.IsLoaded) { $window.Close() } else { Stop-App }
}
function Stop-App {
    try { $notify.Visible = $false; $notify.Dispose() } catch {}
    $global:ProcessInspectorExited = $true       # tells ProcessInspector.exe this was a clean exit
    $app.Shutdown()
}

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

if ($TrayMode -and -not $Show) { <# stay hidden until the tray icon is clicked #> } else { $window.Show() }
$app.Run() | Out-Null
