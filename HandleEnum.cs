// Enumerates open file handles system-wide (what handle.exe / Process Explorer do).
// Used by ProcessInspector.ps1 and OpenFiles.ps1 via Add-Type -Path.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace WhosLocking {

public class FileRow {
    public int    PID     { get; set; }
    public string Process { get; set; }
    public string Kind    { get; set; }
    public string File    { get; set; }
}

public static class HandleEnum {
    [StructLayout(LayoutKind.Sequential)]
    struct SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX {
        public IntPtr Object;
        public IntPtr UniqueProcessId;
        public IntPtr HandleValue;
        public uint   GrantedAccess;
        public ushort CreatorBackTraceIndex;
        public ushort ObjectTypeIndex;
        public uint   HandleAttributes;
        public uint   Reserved;
    }

    [DllImport("ntdll.dll")]
    static extern int NtQuerySystemInformation(int infoClass, IntPtr buffer, int length, out int returnLength);
    [DllImport("kernel32.dll")]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DuplicateHandle(IntPtr srcProcess, IntPtr srcHandle, IntPtr dstProcess, out IntPtr dstHandle,
                                       uint access, bool inherit, uint options);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")]
    static extern uint GetFileType(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandle(IntPtr h, StringBuilder path, uint len, uint flags);

    const int  SystemExtendedHandleInformation = 64;
    const int  STATUS_INFO_LENGTH_MISMATCH = unchecked((int)0xC0000004);
    const uint PROCESS_DUP_HANDLE = 0x0040;
    const uint DUPLICATE_SAME_ACCESS = 0x0002;
    const uint FILE_TYPE_DISK = 0x0001;

    public class OpenFile { public int Pid; public string Path; }

    static SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX[] Snapshot() {
        int len = 4 * 1024 * 1024;
        IntPtr buf = Marshal.AllocHGlobal(len);
        try {
            int ret, status;
            while ((status = NtQuerySystemInformation(SystemExtendedHandleInformation, buf, len, out ret)) == STATUS_INFO_LENGTH_MISMATCH) {
                Marshal.FreeHGlobal(buf);
                buf = IntPtr.Zero;
                len = Math.Max(ret + 65536, len * 2);
                buf = Marshal.AllocHGlobal(len);
            }
            if (status != 0) throw new Exception("NtQuerySystemInformation failed (0x" + status.ToString("X8") + ")");

            long count = Marshal.ReadIntPtr(buf).ToInt64();
            int entrySize = Marshal.SizeOf(typeof(SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX));
            IntPtr first = new IntPtr(buf.ToInt64() + IntPtr.Size * 2);   // NumberOfHandles + Reserved
            var arr = new SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX[count];
            for (long i = 0; i < count; i++)
                arr[i] = (SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX)Marshal.PtrToStructure(
                            new IntPtr(first.ToInt64() + i * entrySize), typeof(SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX));
            return arr;
        } finally { if (buf != IntPtr.Zero) Marshal.FreeHGlobal(buf); }
    }

    /// pid = -1 for every process. Returns disk files and directories only (pipes/devices skipped,
    /// which also avoids the classic NtQueryObject hang). Processes we cannot open are silently skipped.
    public static List<OpenFile> GetFiles(int pid) {
        var result = new List<OpenFile>();
        SYSTEM_HANDLE_TABLE_ENTRY_INFO_EX[] snap;
        int typeIdx = -1;
        long me = System.Diagnostics.Process.GetCurrentProcess().Id;

        // Learn the object-type index for "File" by looking up a handle we know is a file.
        using (var probe = new FileStream(Path.Combine(Environment.SystemDirectory, "kernel32.dll"),
                                          FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
            IntPtr ph = probe.SafeFileHandle.DangerousGetHandle();
            snap = Snapshot();
            foreach (var e in snap)
                if (e.UniqueProcessId.ToInt64() == me && e.HandleValue == ph) { typeIdx = e.ObjectTypeIndex; break; }
        }
        if (typeIdx < 0) throw new Exception("Could not determine the File object type index.");

        var procHandles = new Dictionary<long, IntPtr>();
        var seen = new HashSet<string>();
        var sb = new StringBuilder(2048);
        IntPtr self = GetCurrentProcess();
        try {
            foreach (var e in snap) {
                if (e.ObjectTypeIndex != typeIdx) continue;
                long p = e.UniqueProcessId.ToInt64();
                if (pid >= 0 && p != pid) continue;
                if (p == me) continue;

                IntPtr hProc;
                if (!procHandles.TryGetValue(p, out hProc)) {
                    hProc = OpenProcess(PROCESS_DUP_HANDLE, false, (int)p);
                    procHandles[p] = hProc;
                }
                if (hProc == IntPtr.Zero) continue;

                IntPtr dup;
                if (!DuplicateHandle(hProc, e.HandleValue, self, out dup, 0, false, DUPLICATE_SAME_ACCESS)) continue;
                try {
                    if (GetFileType(dup) != FILE_TYPE_DISK) continue;
                    sb.Length = 0;
                    uint n = GetFinalPathNameByHandle(dup, sb, (uint)sb.Capacity, 0);
                    if (n == 0 || n >= sb.Capacity) continue;
                    string path = sb.ToString();
                    if (path.StartsWith(@"\\?\UNC\")) path = @"\\" + path.Substring(8);
                    else if (path.StartsWith(@"\\?\")) path = path.Substring(4);
                    if (seen.Add(p + "|" + path)) result.Add(new OpenFile { Pid = (int)p, Path = path });
                } finally { CloseHandle(dup); }
            }
        } finally {
            foreach (var h in procHandles.Values) if (h != IntPtr.Zero) CloseHandle(h);
        }
        return result;
    }

    /// True if we could open the process for handle duplication (false usually means "needs Administrator").
    public static bool CanInspect(int pid) {
        IntPtr h = OpenProcess(PROCESS_DUP_HANDLE, false, pid);
        if (h == IntPtr.Zero) return false;
        CloseHandle(h);
        return true;
    }
}
}
