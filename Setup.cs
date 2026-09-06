// ProcessInspector-Setup.exe - self-extracting installer. All app files are embedded as
// resources by Build.ps1; at run time they are extracted to a temp folder and Install.ps1
// is started (it shows the install options dialog). Pass -Silent for an unattended install.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Process Inspector Setup")]
[assembly: AssemblyProduct("Process Inspector")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.0.0")]

static class Setup
{
    [STAThread]
    static int Main(string[] args)
    {
        string tmp = Path.Combine(Path.GetTempPath(), "ProcessInspectorSetup_" + Process.GetCurrentProcess().Id);
        try
        {
            var asm = Assembly.GetExecutingAssembly();
            Directory.CreateDirectory(tmp);
            foreach (string name in asm.GetManifestResourceNames())
            {
                using (Stream s = asm.GetManifestResourceStream(name))
                using (FileStream f = File.Create(Path.Combine(tmp, name)))
                    s.CopyTo(f);
            }

            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            string extra = args.Length > 0 ? " " + string.Join(" ", args) : "";
            var psi = new ProcessStartInfo(ps,
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(tmp, "Install.ps1") +
                "\" -Source \"" + tmp + "\"" + extra)
            { UseShellExecute = false, CreateNoWindow = true };

            using (var p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.ToString(), "Process Inspector Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            try { if (Directory.Exists(tmp)) Directory.Delete(tmp, true); } catch { }
        }
    }
}
