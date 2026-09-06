// System metrics for the live charts. Native calls only (no performance counters), so it works
// regardless of the Windows display language and costs a few milliseconds per sample.
using System;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;

namespace WhosLocking {

public static class SysMetrics {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetSystemTimes(out long idle, out long kernel, out long user);

    [StructLayout(LayoutKind.Sequential)]
    struct MEMORYSTATUSEX {
        public uint  dwLength, dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile,
                     ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX buf);

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount,
                     ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessIoCounters(IntPtr h, out IO_COUNTERS c);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("psapi.dll", SetLastError = true)]
    static extern bool EnumProcesses([Out] int[] pids, int size, out int needed);

    static long lastIdle, lastKernel, lastUser;

    /// Whole-machine CPU % since the previous call (first call returns 0).
    public static double CpuPercent() {
        long i, k, u;
        if (!GetSystemTimes(out i, out k, out u)) return 0;
        double r = 0;
        long di = i - lastIdle, total = (k - lastKernel) + (u - lastUser);
        if (lastKernel != 0 && total > 0) r = 100.0 * (total - di) / total;
        lastIdle = i; lastKernel = k; lastUser = u;
        return Math.Max(0, Math.Min(100, r));
    }

    public static void Memory(out ulong total, out ulong avail) {
        var m = new MEMORYSTATUSEX();
        m.dwLength = (uint)Marshal.SizeOf(m);
        GlobalMemoryStatusEx(ref m);
        total = m.ullTotalPhys; avail = m.ullAvailPhys;
    }

    /// Bytes read + written so far by one process (false if we may not open it).
    public static bool ProcessIo(int pid, out ulong read, out ulong write) {
        read = write = 0;
        IntPtr h = OpenProcess(0x1000, false, pid);   // PROCESS_QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) return false;
        try {
            IO_COUNTERS c;
            if (!GetProcessIoCounters(h, out c)) return false;
            read = c.ReadTransferCount; write = c.WriteTransferCount;
            return true;
        } finally { CloseHandle(h); }
    }

    /// Sum of read + written bytes over every process we may query.
    public static ulong TotalIo() {
        int[] pids = new int[8192]; int needed;
        if (!EnumProcesses(pids, pids.Length * 4, out needed)) return 0;
        int n = needed / 4; ulong sum = 0;
        for (int i = 0; i < n; i++) { ulong r, w; if (ProcessIo(pids[i], out r, out w)) sum += r + w; }
        return sum;
    }

    /// Bytes received / sent so far over all non-loopback interfaces that are up.
    public static void NetBytes(out ulong recv, out ulong sent) {
        recv = sent = 0;
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()) {
            if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback || ni.OperationalStatus != OperationalStatus.Up) continue;
            try { var s = ni.GetIPv4Statistics(); recv += (ulong)s.BytesReceived; sent += (ulong)s.BytesSent; } catch { }
        }
    }
}
}
