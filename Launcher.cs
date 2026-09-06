// ProcessInspector.exe - hosts ProcessInspector.ps1 inside the .exe itself, so the app shows
// up as "ProcessInspector.exe" with its own icon instead of a powershell.exe window.
// Built by Build.ps1 with the C# compiler that ships with the .NET Framework (csc.exe).
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Process Inspector")]
[assembly: AssemblyDescription("See what every process is used by, which files it has open, and who is locking a file.")]
[assembly: AssemblyProduct("Process Inspector")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.0.0")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string exe    = Assembly.GetExecutingAssembly().Location;
            string home   = Path.GetDirectoryName(exe);
            string script = Path.Combine(home, "ProcessInspector.ps1");
            if (!File.Exists(script))
            {
                MessageBox.Show("ProcessInspector.ps1 was not found next to the program:\n" + script,
                                "Process Inspector", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            Environment.SetEnvironmentVariable("PROCESS_INSPECTOR_EXE", exe);
            Environment.SetEnvironmentVariable("PROCESS_INSPECTOR_HOME", home);

            var cmd = new StringBuilder();
            cmd.Append("Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue; & '")
               .Append(script.Replace("'", "''")).Append("'");
            foreach (string a in args)
            {
                bool isSwitch = a.StartsWith("-") && a.IndexOfAny(new[] { ' ', '\\', '/', ':' }) < 0;
                if (isSwitch) cmd.Append(' ').Append(a);
                else          cmd.Append(" '").Append(a.Replace("'", "''")).Append("'");
            }

            using (var rs = RunspaceFactory.CreateRunspace(InitialSessionState.CreateDefault()))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions  = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddScript(cmd.ToString());
                    ps.Invoke();

                    object exited = rs.SessionStateProxy.GetVariable("ProcessInspectorExited");
                    bool clean = exited is bool && (bool)exited;
                    if (ps.HadErrors && !clean)
                    {
                        var msg = new StringBuilder();
                        foreach (var e in ps.Streams.Error)
                        {
                            msg.AppendLine(e.ToString());
                            if (e.InvocationInfo != null) msg.AppendLine(e.InvocationInfo.PositionMessage);
                            msg.AppendLine();
                        }
                        MessageBox.Show(msg.ToString(), "Process Inspector - error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 2;
                    }
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.ToString(), "Process Inspector - error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 3;
        }
    }
}
