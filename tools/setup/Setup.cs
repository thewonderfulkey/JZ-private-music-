using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// JZ Music 安装程序（.NET Framework 4.x，csc 直接编译）。
//
//   · 把整份 app-image（JZ Music.exe + app\ + runtime\）作为 payload.zip 嵌在自身里；
//   · 装到用户选的文件夹（默认 D:\JZ Music，没有 D 盘就用 %LOCALAPPDATA%\Programs\JZ Music）；
//   · 建好 Download / Log / Cache / Data / Backup / 说明 这些文件夹，写入说明文档；
//   · 放一个「卸载 JZ Music.exe」，建桌面/开始菜单快捷方式，登记到「设置 → 应用」；
//   · 重复安装 = 覆盖程序文件，Download / Data / Log 里的东西保留。
//
// 用法：
//   JZ Music Setup-2.1.95.exe                       图形界面安装
//   JZ Music Setup-2.1.95.exe --silent --dir="D:\JZ Music"   静默安装（--no-launch 不自动启动）
internal static class Setup
{
    private const string AppName = "JZ Music";
    private const string Version = "2.1.95";
    private const string InnerExe = "JZ Music.exe";
    private const string UninstallName = "卸载 JZ Music.exe";

    private static readonly string[] UserDirs = new string[] { "Download", "Log", "Cache", "Data", "Backup", "说明" };

    private static readonly string LogPath =
        Path.Combine(Path.GetTempPath(), "jz-music-setup.log");

    private static void Log(string msg)
    {
        try
        {
            File.AppendAllText(LogPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + msg + Environment.NewLine,
                new UTF8Encoding(true));
        }
        catch { }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool silent = HasFlag(args, "--silent");
        bool noLaunch = HasFlag(args, "--no-launch");
        bool noShortcut = HasFlag(args, "--no-shortcut");
        string dir = GetOption(args, "--dir");
        if (dir == null || dir.Trim().Length == 0) dir = DefaultDir();

        Log("==== setup start, silent=" + silent + " dir=" + dir + " ====");

        if (silent)
        {
            try
            {
                Install(dir, delegate(int p, string m) { Log(p + "% " + m); }, !noShortcut);
                if (!noLaunch) Launch(dir);
                Log("silent install OK");
                return 0;
            }
            catch (Exception e)
            {
                Log("silent install FAILED: " + e);
                return 1;
            }
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using (var form = new InstallForm(dir, !noShortcut))
        {
            Application.Run(form);
            if (!form.Installed) return 1;
            if (form.LaunchAfter) Launch(form.InstallDir);
            return 0;
        }
    }

    // ---------------------------------------------------------------- 安装

    private static void Install(string targetDir, Action<int, string> report, bool makeShortcut)
    {
        string dir = Path.GetFullPath(targetDir);
        if (IsDriveRoot(dir)) throw new Exception("不能直接装到磁盘根目录：" + dir);

        report(1, "检查目录…");
        KillRunning(dir);
        Directory.CreateDirectory(dir);

        // 程序目录整体换新（升级时避免旧 jar 残留），用户数据目录原样保留
        foreach (string sub in new string[] { "app", "runtime" })
        {
            string p = Path.Combine(dir, sub);
            if (Directory.Exists(p))
            {
                report(2, "清理旧版本 " + sub + "\\ …");
                for (int attempt = 0; attempt < 5 && Directory.Exists(p); attempt++)
                {
                    TryDeleteDir(p);
                    if (Directory.Exists(p))
                    {
                        KillRunning(dir);
                        Thread.Sleep(700);
                    }
                }
                if (Directory.Exists(p))
                    throw new Exception("旧文件删不掉，程序可能还在运行。先退出 JZ Music 再装：" + p);
            }
        }

        foreach (string sub in UserDirs) Directory.CreateDirectory(Path.Combine(dir, sub));

        report(3, "解包程序文件…");
        ExtractPayload(dir, report);

        report(94, "写入说明文档…");
        WriteDocs(dir);

        report(96, "安装卸载程序…");
        ExtractUninstaller(dir);

        report(97, "创建快捷方式…");
        if (makeShortcut) CreateShortcuts(dir);

        report(99, "登记到「设置 → 应用」…");
        WriteUninstallRegistry(dir);

        report(100, "安装完成");
        Log("installed to " + dir);
    }

    private static void ExtractPayload(string dir, Action<int, string> report)
    {
        string dirPrefix = dir.TrimEnd('\\') + "\\";
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
        {
            if (s == null) throw new Exception("安装包损坏：找不到内置的程序文件（payload.zip）。");
            using (var zip = new ZipArchive(s, ZipArchiveMode.Read))
            {
                int total = zip.Entries.Count;
                int done = 0;
                foreach (ZipArchiveEntry entry in zip.Entries)
                {
                    done++;
                    string rel = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                    if (rel.Length == 0) continue;
                    string dest = Path.GetFullPath(Path.Combine(dir, rel));
                    if (!dest.StartsWith(dirPrefix, StringComparison.OrdinalIgnoreCase))
                        throw new Exception("安装包内容异常：" + entry.FullName);

                    if (rel.EndsWith(Path.DirectorySeparatorChar.ToString()))
                    {
                        Directory.CreateDirectory(dest);
                        continue;
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(dest));
                    using (var outStream = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None))
                    using (Stream inStream = entry.Open())
                    {
                        inStream.CopyTo(outStream);
                    }
                    if (done % 20 == 0 || done == total)
                    {
                        int pct = 3 + (int)(90.0 * done / total);
                        report(pct, "解包程序文件… " + done + " / " + total);
                    }
                }
            }
        }
        string exe = Path.Combine(dir, InnerExe);
        if (!File.Exists(exe)) throw new Exception("解包后找不到 " + InnerExe);
    }

    private static void WriteDocs(string dir)
    {
        WriteResourceText("doc_readme", Path.Combine(dir, "使用说明.txt"));
        WriteResourceText("doc_changelog", Path.Combine(dir, "说明", "更新日志.txt"));
        WriteResourceText("doc_uninstall", Path.Combine(dir, "说明", "卸载说明.txt"));
        WriteResourceText("doc_faq", Path.Combine(dir, "说明", "常见问题.txt"));
        WriteResourceText("doc_log", Path.Combine(dir, "Log", "日志说明.txt"));
        File.WriteAllText(
            Path.Combine(dir, "说明", "安装信息.txt"),
            Normalize(
                "JZ Music " + Version + Environment.NewLine +
                "安装时间：" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + Environment.NewLine +
                "安装位置：" + dir + Environment.NewLine +
                "安装包生成：tools/build-setup.ps1（app-image + .NET 自解压安装器）" + Environment.NewLine),
            new UTF8Encoding(true));
    }

    private static void WriteResourceText(string resource, string dest)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
        {
            if (s == null) return;
            using (var reader = new StreamReader(s, Encoding.UTF8))
            {
                string text = Normalize(reader.ReadToEnd());
                Directory.CreateDirectory(Path.GetDirectoryName(dest));
                File.WriteAllText(dest, text, new UTF8Encoding(true));
            }
        }
    }

    private static string Normalize(string text)
    {
        return text.Replace("\r\n", "\n").Replace("\r", "\n").Replace("\n", "\r\n");
    }

    private static void ExtractUninstaller(string dir)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("uninstall.exe"))
        {
            if (s == null) throw new Exception("安装包损坏：找不到内置的卸载程序（uninstall.exe）。");
            string dest = Path.Combine(dir, UninstallName);
            using (var outStream = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                s.CopyTo(outStream);
            }
        }
    }

    // ---------------------------------------------------------------- 快捷方式 / 注册表

    private static void CreateShortcuts(string dir)
    {
        string exe = Path.Combine(dir, InnerExe);
        string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        if (desktop != null && desktop.Length > 0)
            CreateShortcut(Path.Combine(desktop, AppName + ".lnk"), exe, "", dir, "JZ Music", exe);

        string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
        if (programs != null && programs.Length > 0)
        {
            string menuDir = Path.Combine(programs, AppName);
            CreateShortcut(Path.Combine(menuDir, AppName + ".lnk"), exe, "", dir, "JZ Music", exe);
            CreateShortcut(
                Path.Combine(menuDir, "卸载 JZ Music.lnk"),
                Path.Combine(dir, UninstallName), "", dir, "卸载 JZ Music", Path.Combine(dir, UninstallName));
        }
    }

    private static void CreateShortcut(string lnk, string target, string arguments, string workDir, string desc, string icon)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(lnk));
            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
            object shell = Activator.CreateInstance(shellType);
            object shortcut = shellType.InvokeMember(
                "CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnk });
            Type t = shortcut.GetType();
            t.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { target });
            t.InvokeMember("Arguments", BindingFlags.SetProperty, null, shortcut, new object[] { arguments });
            t.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { workDir });
            t.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { desc });
            t.InvokeMember("IconLocation", BindingFlags.SetProperty, null, shortcut, new object[] { icon });
            t.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
        }
        catch (Exception e)
        {
            Log("create shortcut failed: " + lnk + " -> " + e.Message);
        }
    }

    private static void WriteUninstallRegistry(string dir)
    {
        try
        {
            string key = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\JZ Music";
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(key))
            {
                if (k == null) return;
                k.SetValue("DisplayName", AppName);
                k.SetValue("DisplayVersion", Version);
                k.SetValue("Publisher", "JZ");
                k.SetValue("InstallLocation", dir);
                k.SetValue("DisplayIcon", Path.Combine(dir, InnerExe));
                k.SetValue("UninstallString", "\"" + Path.Combine(dir, UninstallName) + "\"");
                k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }
        }
        catch (Exception e)
        {
            Log("registry write failed: " + e.Message);
        }
    }

    // ---------------------------------------------------------------- 工具

    private static void KillRunning(string dir)
    {
        // 覆盖安装前把正在跑的 JZ Music 停掉。
        // jpackage 启动器是「父进程 + JVM 子进程」两个同名进程，而且子进程有时读不到
        // MainModule（权限/时序），只按路径判断会漏杀一个，接着删 app\ 就失败。
        // 所以：路径明确且不在安装目录 → 放过；路径读不到 → 按进程名杀（同一产品，不误伤别的软件）。
        for (int round = 0; round < 6; round++)
        {
            bool any = false;
            foreach (Process p in Process.GetProcessesByName("JZ Music"))
            {
                try
                {
                    string path = null;
                    try { path = p.MainModule.FileName; } catch { path = null; }
                    bool sameDir = path != null &&
                        path.StartsWith(dir.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
                    if (path == null || sameDir)
                    {
                        any = true;
                        Log("killing " + p.Id + " " + (path ?? "(path unknown)"));
                        try { p.Kill(); } catch { }
                        try { p.WaitForExit(6000); } catch { }
                    }
                }
                catch (Exception e)
                {
                    Log("kill failed: " + e.Message);
                }
                finally { p.Dispose(); }
            }
            if (!any) return;
            Thread.Sleep(600);
        }
    }

    private static bool IsDriveRoot(string dir)
    {
        string d = dir.TrimEnd('\\');
        return d.Length == 2 && d[1] == ':';
    }

    private static void TryDeleteDir(string path)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, true);
        }
        catch (Exception e)
        {
            Log("delete dir failed: " + path + " " + e.Message);
        }
    }

    private static void Launch(string dir)
    {
        try
        {
            string exe = Path.Combine(dir, InnerExe);
            if (File.Exists(exe))
                Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = dir, UseShellExecute = true });
        }
        catch (Exception e)
        {
            Log("launch failed: " + e.Message);
        }
    }

    private static string DefaultDir()
    {
        // 有 D 盘就装 D:\JZ Music（用户口径），否则装到当前用户目录下
        if (Directory.Exists("D:\\"))
            return Path.Combine("D:\\", AppName);
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(local, "Programs", AppName);
    }

    private static bool HasFlag(string[] args, string name)
    {
        foreach (string a in args)
            if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static string GetOption(string[] args, string name)
    {
        foreach (string a in args)
        {
            if (a.StartsWith(name + "=", StringComparison.OrdinalIgnoreCase))
                return a.Substring(name.Length + 1).Trim('"');
        }
        return null;
    }

    // ---------------------------------------------------------------- 图形界面

    private sealed class InstallForm : Form
    {
        private readonly TextBox _dir = new TextBox();
        private readonly CheckBox _shortcut = new CheckBox();
        private readonly CheckBox _launch = new CheckBox();
        private readonly ProgressBar _bar = new ProgressBar();
        private readonly Label _status = new Label();
        private readonly Button _install = new Button();
        private readonly Button _cancel = new Button();

        public bool Installed;
        public bool LaunchAfter;

        public string InstallDir { get { return _dir.Text.Trim(); } }

        public InstallForm(string defaultDir, bool shortcutChecked)
        {
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
            catch { }

            Text = "JZ Music 安装程序";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(600, 452);
            BackColor = Color.FromArgb(247, 245, 240);
            Font = new Font("Microsoft YaHei UI", 9F);

            var title = new Label();
            title.Text = "JZ Music  " + Version;
            title.Font = new Font("Microsoft YaHei UI", 18F, FontStyle.Bold);
            title.ForeColor = Color.FromArgb(32, 30, 28);
            title.AutoSize = true;
            title.Location = new Point(28, 22);
            Controls.Add(title);

            var sub = new Label();
            sub.Text = "Windows 桌面版 · 音乐聚合播放器";
            sub.ForeColor = Color.FromArgb(110, 104, 98);
            sub.AutoSize = true;
            sub.Location = new Point(31, 62);
            Controls.Add(sub);

            var body = new Label();
            body.Text =
                "整个软件装进一个文件夹：程序、下载的音乐、日志、配置都在一起，\r\n" +
                "拷走文件夹就能搬机，卸载就是删文件夹。\r\n\r\n" +
                "安装后会创建：\r\n" +
                "    Download\\    下载的音乐自动保存到这里\r\n" +
                "    Log\\         运行日志（反馈问题时用它）\r\n" +
                "    Cache\\       播放缓存，可随时清空\r\n" +
                "    Data\\        设置、收藏、播放历史、下载记录\r\n" +
                "    Backup\\      一键备份\r\n" +
                "    说明\\        使用说明、更新日志、常见问题";
            body.AutoSize = false;
            body.Size = new Size(544, 210);
            body.Location = new Point(31, 92);
            body.ForeColor = Color.FromArgb(60, 58, 55);
            Controls.Add(body);

            var dirLabel = new Label();
            dirLabel.Text = "安装位置";
            dirLabel.AutoSize = true;
            dirLabel.Location = new Point(31, 306);
            Controls.Add(dirLabel);

            _dir.Text = defaultDir;
            _dir.Location = new Point(31, 330);
            _dir.Size = new Size(454, 26);
            Controls.Add(_dir);

            var browse = new Button();
            browse.Text = "浏览…";
            browse.Location = new Point(493, 329);
            browse.Size = new Size(82, 27);
            browse.Click += delegate
            {
                using (var dlg = new FolderBrowserDialog())
                {
                    dlg.Description = "选择 JZ Music 的安装文件夹";
                    dlg.SelectedPath = _dir.Text;
                    if (dlg.ShowDialog(this) == DialogResult.OK) _dir.Text = dlg.SelectedPath;
                }
            };
            Controls.Add(browse);

            _shortcut.Text = "创建桌面快捷方式";
            _shortcut.Checked = shortcutChecked;
            _shortcut.AutoSize = true;
            _shortcut.Location = new Point(31, 368);
            Controls.Add(_shortcut);

            _launch.Text = "安装完成后启动 JZ Music";
            _launch.Checked = true;
            _launch.AutoSize = true;
            _launch.Location = new Point(200, 368);
            Controls.Add(_launch);

            _bar.Location = new Point(31, 400);
            _bar.Size = new Size(544, 14);
            _bar.Minimum = 0;
            _bar.Maximum = 100;
            Controls.Add(_bar);

            _status.Text = "准备就绪";
            _status.AutoSize = false;
            _status.Size = new Size(380, 22);
            _status.Location = new Point(31, 420);
            _status.ForeColor = Color.FromArgb(110, 104, 98);
            Controls.Add(_status);

            _install.Text = "安装";
            _install.Location = new Point(400, 416);
            _install.Size = new Size(84, 30);
            _install.Click += delegate { StartInstall(); };
            Controls.Add(_install);

            _cancel.Text = "取消";
            _cancel.Location = new Point(491, 416);
            _cancel.Size = new Size(84, 30);
            _cancel.Click += delegate { Close(); };
            Controls.Add(_cancel);
        }

        private void StartInstall()
        {
            string dir = _dir.Text.Trim();
            if (dir.Length == 0)
            {
                MessageBox.Show(this, "请先选择安装位置。", "JZ Music", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            if (File.Exists(Path.Combine(dir, InnerExe)))
            {
                DialogResult r = MessageBox.Show(
                    this,
                    "这个文件夹里已经有一份 JZ Music。\r\n\r\n继续安装会覆盖程序文件；\r\n" +
                    "Download（下载的音乐）、Data（配置）、Log（日志）里的东西会保留。\r\n\r\n继续吗？",
                    "JZ Music", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (r != DialogResult.Yes) return;
            }

            SetBusy(true);
            string captured = dir;
            var thread = new Thread(delegate()
            {
                try
                {
                    Install(captured, delegate(int pct, string msg)
                    {
                        try
                        {
                            BeginInvoke((Action)delegate
                            {
                                if (pct < 0) pct = 0;
                                if (pct > 100) pct = 100;
                                _bar.Value = pct;
                                _status.Text = msg;
                            });
                        }
                        catch { }
                    }, _shortcut.Checked);
                    BeginInvoke((Action)delegate
                    {
                        Installed = true;
                        LaunchAfter = _launch.Checked;
                        MessageBox.Show(this,
                            "安装完成！\r\n\r\n" + captured + "\r\n\r\n" +
                            "以后双击这个文件夹里的「JZ Music.exe」即可打开。",
                            "JZ Music", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        Close();
                    });
                }
                catch (Exception e)
                {
                    Log("install failed: " + e);
                    BeginInvoke((Action)delegate
                    {
                        MessageBox.Show(this,
                            "安装失败：" + e.Message + "\r\n\r\n日志：" + LogPath,
                            "JZ Music", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        SetBusy(false);
                    });
                }
            });
            thread.IsBackground = true;
            thread.Start();
        }

        private void SetBusy(bool busy)
        {
            _install.Enabled = !busy;
            _cancel.Enabled = !busy;
            _dir.Enabled = !busy;
            _shortcut.Enabled = !busy;
            _launch.Enabled = !busy;
            if (busy) _status.Text = "开始安装…";
        }
    }
}
