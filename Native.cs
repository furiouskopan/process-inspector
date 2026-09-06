// Row types bound to the WPF grids, process-owner lookup and the Restart Manager wrapper.
// Compiled together with HandleEnum.cs and SysMetrics.cs into ProcessInspector.Native.dll by
// Build.ps1; ProcessInspector.ps1 compiles the sources itself when the DLL is missing.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WhosLocking {

public class ProcRow {
    public System.Windows.Media.ImageSource Icon { get; set; }
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
    public double   CpuPercent   { get; set; }
    public double   DiskKBs      { get; set; }
    public int      Threads      { get; set; }
    public int      Handles      { get; set; }
    public string   Status       { get; set; }   // "", "New", "Exited"
    public string   Signer       { get; set; }
    public DateTime? Started     { get; set; }
    public string   Path         { get; set; }
    public string   CommandLine  { get; set; }
}

public class LockRow {
    public System.Windows.Media.ImageSource Icon { get; set; }
    public int      PID          { get; set; }
    public string   Name         { get; set; }
    public string   Description  { get; set; }
    public string   Type         { get; set; }
    public string   ServiceNames { get; set; }
    public string   User         { get; set; }
    public DateTime? Started     { get; set; }
    public string   Path         { get; set; }
    public string   HeldItem     { get; set; }
    public List<long> Handles    { get; set; }   // handle values we could close remotely
    public LockRow() { Handles = new List<long>(); }
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
