// Tray launcher of the Revit Server Stack control panel.
//
// Starts panel\server.ps1 in a hidden PowerShell, keeps an icon in the
// notification area and opens the panel in the browser. Closing the icon stops
// the panel; containers keep running. Plain C# 5 on the compiler that ships with
// Windows (see Build.ps1), no SDK and no packages.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
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
                MessageBox.Show(L10n.Get("missingScript"), Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
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
                        MessageBox.Show(L10n.Get("alreadyRunning"), Title, MessageBoxButtons.OK, MessageBoxIcon.Information);
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

            openItem = new ToolStripMenuItem(L10n.Get("open"), null, delegate { OpenPanel(); });
            openItem.Font = new Font(openItem.Font, FontStyle.Bold);
            restartItem = new ToolStripMenuItem(L10n.Get("restart"), null, delegate { StartServer(); });
            ToolStripMenuItem logItem = new ToolStripMenuItem(L10n.Get("log"), null, delegate { OpenLog(); });
            ToolStripMenuItem exitItem = new ToolStripMenuItem(L10n.Get("exit"), null, delegate { ExitApp(); });

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
            SetState(State.Starting, Title + ": " + L10n.Get("starting"));

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
                Fail(string.Format(L10n.Get("powershellFailed"), ex.Message));
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
                Fail(string.Format(L10n.Get(state == State.Running ? "stopped" : "notStarted"), code));
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
            SetState(State.Stopped, Title + ": " + L10n.Get("notRunning"));
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

    // The texts of the icon in the language of Windows (the page of the panel has
    // its own catalogs in panel\www\i18n). Columns: en, ru, de, fr, es, pt, zh, ja.
    // Chinese and Portuguese stand for every variant of the language.
    internal static class L10n
    {
        private static readonly string[] Languages = { "en", "ru", "de", "fr", "es", "pt", "zh", "ja" };

        private static readonly Dictionary<string, string[]> Texts = new Dictionary<string, string[]>
        {
            { "missingScript", new[] {
                "The file panel\\server.ps1 was not found next to the program.\n\nUnpack the whole archive and run RevitServerStack.exe from its folder.",
                "Не найден файл panel\\server.ps1 рядом с программой.\n\nРаспакуйте архив целиком и запускайте RevitServerStack.exe из его папки.",
                "Die Datei panel\\server.ps1 wurde neben dem Programm nicht gefunden.\n\nEntpacken Sie das ganze Archiv und starten Sie RevitServerStack.exe aus seinem Ordner.",
                "Le fichier panel\\server.ps1 est introuvable à côté du programme.\n\nExtrayez toute l'archive et lancez RevitServerStack.exe depuis son dossier.",
                "No se encuentra el archivo panel\\server.ps1 junto al programa.\n\nDescomprima todo el archivo y ejecute RevitServerStack.exe desde su carpeta.",
                "O arquivo panel\\server.ps1 não foi encontrado ao lado do programa.\n\nExtraia o arquivo inteiro e execute o RevitServerStack.exe a partir da pasta dele.",
                "在程序旁边找不到 panel\\server.ps1 文件。\n\n请解压整个压缩包，并从其文件夹中运行 RevitServerStack.exe。",
                "プログラムと同じ場所に panel\\server.ps1 が見つかりません。\n\nアーカイブ全体を展開し、そのフォルダーから RevitServerStack.exe を実行してください。" } },
            { "alreadyRunning", new[] {
                "Revit Server Stack is already running. Its icon is in the notification area.",
                "Revit Server Stack уже запущен. Его значок находится в области уведомлений.",
                "Revit Server Stack läuft bereits. Das Symbol befindet sich im Infobereich.",
                "Revit Server Stack est déjà lancé. Son icône se trouve dans la zone de notification.",
                "Revit Server Stack ya está en ejecución. Su icono está en el área de notificaciones.",
                "O Revit Server Stack já está em execução. O ícone dele está na área de notificação.",
                "Revit Server Stack 已在运行。其图标位于通知区域。",
                "Revit Server Stack はすでに実行中です。アイコンは通知領域にあります。" } },
            { "open", new[] {
                "Open the panel", "Открыть панель", "Oberfläche öffnen", "Ouvrir le panneau",
                "Abrir el panel", "Abrir o painel", "打开面板", "パネルを開く" } },
            { "restart", new[] {
                "Start again", "Запустить заново", "Erneut starten", "Redémarrer",
                "Iniciar de nuevo", "Iniciar novamente", "重新启动", "もう一度起動" } },
            { "log", new[] {
                "Startup log", "Журнал запуска", "Startprotokoll", "Journal de démarrage",
                "Registro de inicio", "Registro de inicialização", "启动日志", "起動ログ" } },
            { "exit", new[] {
                "Exit", "Выход", "Beenden", "Quitter", "Salir", "Sair", "退出", "終了" } },
            { "starting", new[] {
                "starting...", "запуск...", "startet...", "démarrage...",
                "iniciando...", "iniciando...", "正在启动...", "起動中..." } },
            { "notRunning", new[] {
                "the panel is not running", "панель не запущена", "Oberfläche läuft nicht", "le panneau n'est pas lancé",
                "el panel no está en ejecución", "o painel não está em execução", "面板未运行", "パネルは動作していません" } },
            { "powershellFailed", new[] {
                "Could not start PowerShell: {0}", "Не удалось запустить PowerShell: {0}", "PowerShell konnte nicht gestartet werden: {0}",
                "Impossible de lancer PowerShell : {0}", "No se pudo iniciar PowerShell: {0}", "Não foi possível iniciar o PowerShell: {0}",
                "无法启动 PowerShell：{0}", "PowerShell を起動できませんでした: {0}" } },
            { "stopped", new[] {
                "The panel stopped (code {0}). See the startup log.",
                "Панель остановилась (код {0}). Подробности в журнале запуска.",
                "Die Oberfläche wurde beendet (Code {0}). Siehe das Startprotokoll.",
                "Le panneau s'est arrêté (code {0}). Voir le journal de démarrage.",
                "El panel se detuvo (código {0}). Vea el registro de inicio.",
                "O painel parou (código {0}). Veja o registro de inicialização.",
                "面板已停止（代码 {0}）。请查看启动日志。",
                "パネルが停止しました (コード {0})。起動ログを確認してください。" } },
            { "notStarted", new[] {
                "The panel did not start (code {0}). See the startup log.",
                "Панель не запустилась (код {0}). Подробности в журнале запуска.",
                "Die Oberfläche konnte nicht starten (Code {0}). Siehe das Startprotokoll.",
                "Le panneau n'a pas démarré (code {0}). Voir le journal de démarrage.",
                "El panel no se inició (código {0}). Vea el registro de inicio.",
                "O painel não iniciou (código {0}). Veja o registro de inicialização.",
                "面板未能启动（代码 {0}）。请查看启动日志。",
                "パネルを起動できませんでした (コード {0})。起動ログを確認してください。" } },
        };

        internal static string Get(string key)
        {
            int column = Array.IndexOf(Languages, CultureInfo.CurrentUICulture.TwoLetterISOLanguageName);
            return Texts[key][column < 0 ? 0 : column];
        }
    }
}
