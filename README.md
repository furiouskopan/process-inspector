<p align="center"><img src="docs/icon-256.png" width="96" alt="Process Inspector icon"></p>

# Process Inspector

**"The action can't be completed because the file is open in another program."**
Process Inspector tells you *which* program, lets you end it or stop the service from the same window,
and shows what every process on the machine is used by and which files it has open.

No downloads, no drivers, no admin needed for your own processes. It is a single PowerShell/WPF app
that talks to the Windows Restart Manager and the kernel handle table, wrapped in a small .exe.

| Processes | Open files | Who's locking a file? |
|---|---|---|
| ![Processes tab](docs/processes.png) | ![Open files tab](docs/open-files.png) | ![Who's locking tab](docs/whos-locking.png) |

## Features

- **Processes tab** – every process with description, user account, memory, start time and a
  *Used by / started by* column: the services a process hosts (what is inside each `svchost.exe`)
  or the parent that started it. Live search, sortable columns, a details pane, and a panel listing
  the files the selected process has open (optionally its loaded DLLs too).
- **Open files tab** – every file every process has open, system-wide, in about a second. Search by
  file, folder or process name. Double-click to jump to the process.
- **Who's locking a file?** – drop a file or folder on the box (or use *File… / Folder…*).
  Uses the Restart Manager API, so it catches open handles *and* loaded EXE/DLL images.
  End the process or stop the service right there.
- **Right-click menus** on every list: end process, end process tree, stop hosted service, show files
  used, go to parent, open file location, search online, copy PID/name/path/command line, properties.
  `Del` ends, `F5` refreshes, `Ctrl+F` focuses search, `Ctrl+C` copies rows.
- **Administrator aware** – files held by services (SQL Server, antivirus, Windows services) are
  invisible to a normal user. The app detects the access-denied case and offers to restart elevated.
- **System tray** – optional autostart at logon, minimised to the tray. Left-click opens the window,
  right-click gives quick actions.
- **Safe by default** – every end/stop action asks first, services are stopped properly instead of
  killed, and critical system processes are refused.

## Install

Download `ProcessInspector-Setup.exe` from the [Releases](../../releases) page and run it.
It installs for the current user only (no admin prompt) into
`%LOCALAPPDATA%\Programs\ProcessInspector` and lets you choose:

- Desktop shortcut and Start Menu entry
- Start automatically at sign-in (in the system tray)
- "Who's locking this?" in the right-click menu of files and folders

Uninstall from **Settings › Apps › Installed apps**, or run `Uninstall.ps1`.

Unattended: `ProcessInspector-Setup.exe -Silent [-NoAutostart] [-ContextMenu] [-NoDesktop] [-NoLaunch]`

### Portable

Unzip `ProcessInspector-portable.zip` anywhere and run `ProcessInspector.exe`.
Drag a file onto `ProcessInspector.exe` (or run `ProcessInspector.exe -Path "C:\some\file"`) to open
straight on the *Who's locking* tab. `-Tray` starts hidden in the tray.

### Command line

The same engine is available as plain scripts:

```powershell
.\WhosLocking.ps1 "C:\Program Files\App\app.exe"      # who holds this file / folder / exe
.\OpenFiles.ps1 -Name sqlservr                          # files a process has open
.\OpenFiles.ps1 -File "KNI_EKO"                         # which process has a file matching this open
.\ListProcesses.ps1 -Tree                               # parent -> child process tree
.\ListProcesses.ps1 -Grid                               # searchable grid of all processes
```

## Build from source

Nothing to install: the build uses `csc.exe` from the .NET Framework that is part of Windows.

```powershell
.\Build.ps1
```

produces `app.ico`, `ProcessInspector.exe`, `dist\ProcessInspector-portable.zip` and
`dist\ProcessInspector-Setup.exe`.

## How it works

| Piece | Mechanism |
|---|---|
| Who's locking | `rstrtmgr.dll` (Restart Manager): `RmRegisterResources` + `RmGetList` |
| Open files | `NtQuerySystemInformation(SystemExtendedHandleInformation)` → `DuplicateHandle` → `GetFileType` (skips pipes, so no hangs) → `GetFinalPathNameByHandle` |
| Process owner | `OpenProcessToken` + `WindowsIdentity` (fast, unlike WMI `GetOwner`) |
| Services per process | `Win32_Service.ProcessId` |
| .exe | `Launcher.cs` hosts the PowerShell engine in-process, so the app runs as `ProcessInspector.exe` with its own icon |
| Setup.exe | `Setup.cs` self-extracts the embedded files and runs `Install.ps1` |

Requirements: Windows 10/11 with Windows PowerShell 5.1 (built in).

## Ideas for future versions

- Search handles for a **partial name** ("who has anything under D:\Projects open?")
- **Unlock without killing**: close the single handle in the other process (`DuplicateHandle` with
  `DUPLICATE_CLOSE_SOURCE`), the way Unlocker / Process Explorer do
- **Delete / rename / move on reboot** for files that cannot be released now (`MoveFileEx` with
  `MOVEFILE_DELAY_UNTIL_REBOOT`)
- **Network connections** per process (TCP/UDP endpoints, like TCPView)
- **Live CPU / memory** columns with auto-refresh and process highlighting (new = green, exiting = red)
- **Loaded DLL search**: which processes have a given DLL loaded
- **Signature / publisher check** and VirusTotal hash lookup for unknown processes
- **Restart process** and **run as another user**
- **Export** the current view to CSV / clipboard as a table
- **Dark theme** and per-monitor DPI polish
- **Auto-update** check against GitHub Releases
- **Winget / Scoop / Chocolatey** packages
- Rewrite the UI in C#/WPF (or WinUI 3) once the feature set settles, keeping the scripts as the engine

## License

MIT – see [LICENSE](LICENSE).
