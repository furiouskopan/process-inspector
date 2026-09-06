<#
.SYNOPSIS
  Installs Process Inspector for the current user (no admin rights needed).

.DESCRIPTION
  Copies the app to %LOCALAPPDATA%\Programs\ProcessInspector and, depending on the options:
    - creates Desktop and Start Menu shortcuts
    - starts it automatically at logon, minimised to the system tray
    - adds "Who's locking this?" to the right-click menu of files and folders
    - registers it in Settings > Apps (Add/Remove Programs) with an uninstaller

.EXAMPLE
  .\Install.ps1                       # shows the options dialog
  .\Install.ps1 -Silent               # defaults: desktop + start menu + autostart, launches when done
  .\Install.ps1 -Silent -NoAutostart -ContextMenu -NoLaunch
#>
[CmdletBinding()]
param(
    [string]$Source = $PSScriptRoot,
    [switch]$Silent,
    [switch]$NoDesktop,
    [switch]$NoStartMenu,
    [switch]$NoAutostart,
    [switch]$ContextMenu,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$AppName = 'Process Inspector'
$Version = '1.2.0'
$Dest    = Join-Path $env:LOCALAPPDATA 'Programs\ProcessInspector'
$Files   = 'ProcessInspector.exe','ProcessInspector.ps1','HandleEnum.cs','SysMetrics.cs','app.ico',
           'WhosLocking.ps1','ListProcesses.ps1','OpenFiles.ps1',
           'Install.ps1','Uninstall.ps1','README.md','LICENSE'
$Stale   = 'ProcessInspector.cmd','WhosLocking.cmd','ListProcesses.cmd','Install-ContextMenu.ps1'   # from older versions

function Install-App([hashtable]$o) {
    # stop a running copy so the exe can be replaced
    Get-Process -Name ProcessInspector -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    foreach ($f in $Files) {
        $src = Join-Path $Source $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $Dest $f) -Force }
    }
    foreach ($f in $Stale) { Remove-Item -LiteralPath (Join-Path $Dest $f) -Force -ErrorAction SilentlyContinue }
    $exe  = Join-Path $Dest 'ProcessInspector.exe'
    $icon = Join-Path $Dest 'app.ico'
    if (-not (Test-Path $exe)) { throw "ProcessInspector.exe is missing from $Source. Run Build.ps1 first." }

    $ws = New-Object -ComObject WScript.Shell
    function New-Shortcut([string]$lnkPath, [string]$arguments) {
        $lnk = $ws.CreateShortcut($lnkPath)
        $lnk.TargetPath = $exe
        $lnk.Arguments = $arguments
        $lnk.WorkingDirectory = $Dest
        $lnk.IconLocation = "$icon,0"
        $lnk.Description = "$AppName - what is each process used by, and who is locking a file"
        $lnk.Save()
    }
    $desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
    $startLnk   = Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"
    if ($o.Desktop)   { New-Shortcut $desktopLnk '' } elseif (Test-Path $desktopLnk) { Remove-Item $desktopLnk -Force }
    if ($o.StartMenu) { New-Shortcut $startLnk   '' } elseif (Test-Path $startLnk)   { Remove-Item $startLnk -Force }

    # start automatically at logon (tray)
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($o.Autostart) { New-Item -Path $run -Force | Out-Null; Set-ItemProperty -Path $run -Name 'ProcessInspector' -Value "`"$exe`" -Tray" }
    else { Remove-ItemProperty -Path $run -Name 'ProcessInspector' -ErrorAction SilentlyContinue }

    # right-click menu. The "*" in the first key is a literal key name; PowerShell's registry
    # provider would treat it as a wildcard (and scan every file type), so use .NET directly.
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser
    foreach ($k in 'Software\Classes\*\shell\WhosLocking','Software\Classes\Directory\shell\WhosLocking','Software\Classes\Drive\shell\WhosLocking') {
        if ($o.ContextMenu) {
            $key = $hkcu.CreateSubKey($k)
            $key.SetValue('', "Who's locking this?")
            $key.SetValue('Icon', "`"$icon`"")
            $cmd = $key.CreateSubKey('command')
            $cmd.SetValue('', "`"$exe`" -Path `"%1`"")
            $cmd.Close(); $key.Close()
        } else {
            $hkcu.DeleteSubKeyTree($k, $false)
        }
    }

    # Settings > Apps entry
    $unKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ProcessInspector'
    New-Item -Path $unKey -Force | Out-Null
    $size = [int]((Get-ChildItem $Dest -File | Measure-Object Length -Sum).Sum / 1KB)
    $props = @{
        DisplayName     = $AppName
        DisplayVersion  = $Version
        Publisher       = 'Process Inspector (open source)'
        InstallLocation = $Dest
        DisplayIcon     = $exe
        UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dest\Uninstall.ps1`""
        QuietUninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dest\Uninstall.ps1`" -Silent"
        InstallDate     = (Get-Date -Format 'yyyyMMdd')
    }
    foreach ($p in $props.GetEnumerator()) { Set-ItemProperty -Path $unKey -Name $p.Key -Value $p.Value }
    foreach ($n in 'NoModify','NoRepair') { Set-ItemProperty -Path $unKey -Name $n -Value 1 -Type DWord }
    Set-ItemProperty -Path $unKey -Name 'EstimatedSize' -Value $size -Type DWord

    if ($o.Launch) {
        if ($o.Autostart) { Start-Process -FilePath $exe -ArgumentList '-Tray','-Show' -WorkingDirectory $Dest }
        else              { Start-Process -FilePath $exe -WorkingDirectory $Dest }
    }
    return $exe
}

# ---------------------------------------------------------------------------------
if ($Silent) {
    $exe = Install-App @{ Desktop = -not $NoDesktop; StartMenu = -not $NoStartMenu; Autostart = -not $NoAutostart; ContextMenu = [bool]$ContextMenu; Launch = -not $NoLaunch }
    Write-Host "Installed to $exe"
    exit 0
}

Add-Type -AssemblyName PresentationFramework
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Install Process Inspector" Width="480" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12" Background="#F3F3F3">
  <StackPanel Margin="20">
    <TextBlock Text="Process Inspector" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock x:Name="txtDest" Foreground="#666" Margin="0,2,0,14" TextWrapping="Wrap"/>
    <CheckBox x:Name="chkDesktop"   Content="Create a Desktop shortcut" IsChecked="True" Margin="0,4"/>
    <CheckBox x:Name="chkStart"     Content="Add to the Start Menu" IsChecked="True" Margin="0,4"/>
    <CheckBox x:Name="chkAutostart" Content="Start automatically when I sign in (runs in the system tray)" IsChecked="True" Margin="0,4"/>
    <CheckBox x:Name="chkContext"   Content="Add &quot;Who's locking this?&quot; to the right-click menu of files and folders" Margin="0,4"/>
    <CheckBox x:Name="chkLaunch"    Content="Open Process Inspector when the installation finishes" IsChecked="True" Margin="0,4"/>
    <TextBlock Text="Installs for the current user only. No administrator rights are needed. Uninstall from Settings &gt; Apps." Foreground="#666" Margin="0,12,0,14" TextWrapping="Wrap"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="btnCancel"  Content="Cancel"  MinWidth="90" Padding="12,5" Margin="0,0,8,0"/>
      <Button x:Name="btnInstall" Content="Install" MinWidth="90" Padding="12,5" FontWeight="SemiBold"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
$w = [Windows.Markup.XamlReader]::Parse($xaml)
$icoSrc = Join-Path $Source 'app.ico'
if (Test-Path $icoSrc) { try { $w.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([uri]$icoSrc) } catch {} }
$w.FindName('txtDest').Text = "Version $Version  -  will be installed to $Dest"
$w.FindName('btnCancel').Add_Click({ $w.Close() })
$w.FindName('btnInstall').Add_Click({
    $opts = @{
        Desktop = [bool]$w.FindName('chkDesktop').IsChecked
        StartMenu = [bool]$w.FindName('chkStart').IsChecked
        Autostart = [bool]$w.FindName('chkAutostart').IsChecked
        ContextMenu = [bool]$w.FindName('chkContext').IsChecked
        Launch = [bool]$w.FindName('chkLaunch').IsChecked
    }
    try {
        $w.Cursor = 'Wait'
        $exe = Install-App $opts
        $w.Cursor = $null
        [System.Windows.MessageBox]::Show("Process Inspector is installed.`n`n$exe", 'Installed', 'OK', 'Information') | Out-Null
        $w.Close()
    } catch {
        $w.Cursor = $null
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Installation failed', 'OK', 'Error') | Out-Null
    }
})
$null = $w.ShowDialog()
