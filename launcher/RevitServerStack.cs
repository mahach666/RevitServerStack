// Tray launcher of the Revit Server Stack control panel.
//
// Starts panel\server.ps1 in a hidden PowerShell, keeps an icon in the
// notification area and opens the panel in the browser. Closing the icon stops
// the panel; containers keep running. Plain C# 5 on the compiler that ships with
// Windows (see Build.ps1), no SDK and no packages.

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace RevitServerStack
{
    internal static class Program
    {
        private const string Title = "Revit Server Stack";

        [STAThread]
        private static int Main(string[] args)
        {
            bool noBrowser = Array.IndexOf(args, "--no-browser") >= 0;
            string root = Path.GetDirectoryName(Application.ExecutablePath);
            string script = Path.Combine(root, @"panel\server.ps1");

            if (!File.Exists(script))
            {
                MessageBox.Show(
                    "Не найден файл panel\\server.ps1 рядом с программой.\n\n" +
                    "Распакуйте архив целиком и запускайте RevitServerStack.exe из его папки.",
                    Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }

            bool first;
            Mutex mutex = new Mutex(true, @"Local\RevitServerStack", out first);
            try
            {
                if (!first)
                {
                    // A second start only brings the panel up in the browser.
                    string running = Tray.ReadUrl(Path.Combine(root, @"panel\runtime\panel.url"), DateTime.MinValue);
                    if (running != null)
                    {
                        if (!noBrowser) Tray.OpenUrl(running);
                    }
                    else
                    {
                        MessageBox.Show("Revit Server Stack уже запущен. Его значок находится в области уведомлений.",
                            Title, MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                    return 0;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new Tray(root, script, noBrowser));
                return 0;
            }
            finally
            {
                if (first) mutex.ReleaseMutex();
                mutex.Dispose();
            }
        }
    }

    internal sealed class Tray : ApplicationContext
    {
        private enum State { Starting, Running, Stopped }

        private const string Title = "Revit Server Stack";

        private readonly string root;
        private readonly string script;
        private readonly bool noBrowser;
        private readonly string urlFile;
        private readonly string logFile;
        private readonly object logLock = new object();
        private readonly NotifyIcon icon;
        private readonly ToolStripMenuItem openItem;
        private readonly ToolStripMenuItem restartItem;
        private readonly System.Windows.Forms.Timer timer;
        private Process server;
        private State state;
        private string url;
        private DateTime startedAt;

        public Tray(string root, string script, bool noBrowser)
        {
            this.root = root;
            this.script = script;
            this.noBrowser = noBrowser;
            this.urlFile = Path.Combine(root, @"panel\runtime\panel.url");
            this.logFile = Path.Combine(root, @"panel\runtime\launcher.log");

            openItem = new ToolStripMenuItem("Открыть панель", null, delegate { OpenPanel(); });
            openItem.Font = new Font(openItem.Font, FontStyle.Bold);
            restartItem = new ToolStripMenuItem("Запустить заново", null, delegate { StartServer(); });
            ToolStripMenuItem logItem = new ToolStripMenuItem("Журнал запуска", null, delegate { OpenLog(); });
            ToolStripMenuItem exitItem = new ToolStripMenuItem("Выход", null, delegate { ExitApp(); });

            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.AddRange(new ToolStripItem[] { openItem, restartItem, logItem, new ToolStripSeparator(), exitItem });

            icon = new NotifyIcon();
            icon.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            icon.ContextMenuStrip = menu;
            icon.DoubleClick += delegate { OpenPanel(); };
            icon.Visible = true;

            timer = new System.Windows.Forms.Timer();
            timer.Interval = 500;
            timer.Tick += OnTick;
            timer.Start();

            StartServer();
        }

        // ------------------------------------------------------------- server --

        private void StartServer()
        {
            DeleteQuietly(urlFile);
            url = null;
            startedAt = DateTime.Now;
            SetState(State.Starting, Title + ": запуск...");

            string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            string arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"" +
                " -UrlFile \"" + urlFile + "\" -ParentPid " + Process.GetCurrentProcess().Id +
                (noBrowser ? " -NoBrowser" : "");

            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(logFile));
                File.WriteAllText(logFile,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + powershell + " " + arguments + "\r\n\r\n",
                    new UTF8Encoding(true));

                ProcessStartInfo info = new ProcessStartInfo(powershell, arguments);
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.WorkingDirectory = root;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                info.StandardOutputEncoding = Encoding.UTF8;
                info.StandardErrorEncoding = Encoding.UTF8;

                server = new Process();
                server.StartInfo = info;
                server.OutputDataReceived += OnOutput;
                server.ErrorDataReceived += OnOutput;
                server.Start();
                server.BeginOutputReadLine();
                server.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                server = null;
                Log(ex.ToString());
                Fail("Не удалось запустить PowerShell: " + ex.Message);
            }
        }

        private void OnOutput(object sender, DataReceivedEventArgs e)
        {
            if (e.Data != null) Log(e.Data);
        }

        private void OnTick(object sender, EventArgs e)
        {
            if (state == State.Stopped || server == null) return;

            if (server.HasExited)
            {
                int code = server.ExitCode;
                if (state == State.Running && code == 0)
                {
                    ExitApp(); // closed with the button inside the panel
                    return;
                }
                Fail(string.Format(state == State.Running
                    ? "Панель остановилась (код {0}). Подробности в журнале запуска."
                    : "Панель не запустилась (код {0}). Подробности в журнале запуска.", code));
                return;
            }

            if (state == State.Starting)
            {
                string found = ReadUrl(urlFile, startedAt.AddSeconds(-2));
                if (found != null)
                {
                    url = found;
                    SetState(State.Running, Title + ": " + found);
                }
            }
        }

        private void Fail(string message)
        {
            SetState(State.Stopped, Title + ": панель не запущена");
            icon.ShowBalloonTip(5000, Title, message, ToolTipIcon.Error);
        }

        private void ExitApp()
        {
            timer.Stop();
            icon.Visible = false;
            icon.Dispose();

            // The panel also stops by itself once this process is gone; waiting
            // here only makes a quick restart find its port free.
            if (server != null && !server.HasExited && !server.WaitForExit(3000))
            {
                server.Kill(); // the server only: docker jobs it started keep running
            }
            ExitThread();
        }

        // --------------------------------------------------------------- menu --

        private void SetState(State next, string tip)
        {
            state = next;
            icon.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip; // NotifyIcon limit
            openItem.Enabled = next == State.Running;
            restartItem.Visible = next == State.Stopped;
        }

        private void OpenPanel()
        {
            if (state == State.Running && url != null) OpenUrl(url);
        }

        private void OpenLog()
        {
            if (File.Exists(logFile)) Process.Start("notepad.exe", "\"" + logFile + "\"");
        }

        // ------------------------------------------------------------ helpers --

        // Only an address the panel itself wrote, and only on localhost.
        internal static string ReadUrl(string path, DateTime notOlderThan)
        {
            try
            {
                if (!File.Exists(path) || File.GetLastWriteTime(path) < notOlderThan) return null;
                string text = File.ReadAllText(path, Encoding.UTF8).Trim();
                Uri uri;
                if (Uri.TryCreate(text, UriKind.Absolute, out uri) &&
                    uri.Scheme == Uri.UriSchemeHttp && uri.Host == "localhost")
                {
                    return uri.AbsoluteUri;
                }
                return null;
            }
            catch (IOException)
            {
                return null; // the panel is writing the file right now, read it on the next tick
            }
        }

        internal static void OpenUrl(string address)
        {
            ProcessStartInfo info = new ProcessStartInfo(address);
            info.UseShellExecute = true;
            Process.Start(info);
        }

        private void Log(string line)
        {
            lock (logLock)
            {
                try
                {
                    File.AppendAllText(logFile, line + "\r\n", Encoding.UTF8);
                }
                catch (IOException) { }                 // the log is advisory: never fail the launcher over it
                catch (UnauthorizedAccessException) { } // same
            }
        }

        private static void DeleteQuietly(string path)
        {
            try { File.Delete(path); }
            catch (IOException) { }                 // a stale file is rejected by its age in ReadUrl
            catch (UnauthorizedAccessException) { } // same
        }
    }
}
