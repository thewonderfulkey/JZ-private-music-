using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

// JZ Music 卸载程序（.NET Framework 4.x，csc 直接编译；由安装程序释放到安装目录）。
//
//   · 先停掉正在运行的 JZ Music（只停安装目录里的那份）；
//   · 删程序文件（JZ Music.exe / app\ / runtime\ / 说明\），
//     按用户选择决定是否连 Download（音乐）与 Data（配置）一起删；
//   · 清桌面/开始菜单快捷方式、「设置 → 应用」里的登记项；
//   · 自己删掉自己（cmd 延迟删除），所以不会留下一个孤零零的卸载程序。
//
// 用法：
//   卸载 JZ Music.exe                      弹窗确认
//   卸载 JZ Music.exe --yes=keep           静默：保留音乐与配置
//   卸载 JZ Music.exe --yes=all            静默：全部删除
//   卸载 JZ Music.exe --dir="D:\JZ Music"  指定要卸载的目录（默认取自身所在目录）
internal static class Uninstall
{
    private const string AppName = "JZ Music";
    private const string UninstallName = "卸载 JZ Music.exe";

    private static readonly string LogPath =
        Path.Combine(Path.GetTempPath(), "jz-music-uninstall.log");

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
        string dir = GetOption(args, "--dir");
        if (dir == null || dir.Trim().Length == 0)
            dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        if (dir == null || dir.Trim().Length == 0)
        {
            MessageBox.Show("找不到 JZ Music 的安装目录。", AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        dir = Path.GetFullPath(dir);
        Log("==== uninstall start: " + dir + " ====");

        bool keepUserData;
        string mode = GetOption(args, "--yes");
        bool quiet = mode != null || HasFlag(args, "--quiet");
        if (string.Equals(mode, "keep", StringComparison.OrdinalIgnoreCase)) keepUserData = true;
        else if (string.Equals(mode, "all", StringComparison.OrdinalIgnoreCase)) keepUserData = false;
        else
        {
            DialogResult r = MessageBox.Show(
                "确定要卸载 JZ Music 吗？\r\n\r\n" +
                "「是」：卸载程序，保留 Download（下载的音乐）、Data（设置/收藏/历史）、Backup、Log、Cache。\r\n" +
                "「否」：卸载程序，并且把整个文件夹删掉——音乐和配置都会没。\r\n" +
                "「取消」：什么都不做。",
                "卸载 JZ Music",
                MessageBoxButtons.YesNoCancel,
                MessageBoxIcon.Question,
                MessageBoxDefaultButton.Button1);
            if (r == DialogResult.Cancel) return 0;
            keepUserData = r == DialogResult.Yes;
        }

        try
        {
            DoUninstall(dir, keepUserData);
            Log("uninstall done, keep=" + keepUserData);
            if (!quiet)
            {
                MessageBox.Show(
                    keepUserData
                        ? "JZ Music 已卸载。\r\n\r\nDownload（下载的音乐）和 Data（配置）留在了原文件夹里。"
                        : "JZ Music 已卸载，整个文件夹已删除。",
                    AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            return 0;
        }
        catch (Exception e)
        {
            Log("uninstall failed: " + e);
            if (!quiet)
            {
                MessageBox.Show("卸载时出错：" + e.Message + "\r\n\r\n日志：" + LogPath,
                    AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            return 2;
        }
    }

    private static bool HasFlag(string[] args, string name)
    {
        foreach (string a in args)
            if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static void DoUninstall(string dir, bool keepUserData)
    {
        KillRunning(dir);
        RemoveShortcuts();
        RemoveRegistry();

        string self = Assembly.GetExecutingAssembly().Location;

        // 程序文件
        string[] programFiles = new string[] { "JZ Music.exe", "使用说明.txt", UninstallName };
        foreach (string f in programFiles)
        {
            if (string.Equals(Path.Combine(dir, f), self, StringComparison.OrdinalIgnoreCase)) continue;
            TryDeleteFile(Path.Combine(dir, f));
        }
        foreach (string d in new string[] { "app", "runtime", "说明" })
        {
            TryDeleteDir(Path.Combine(dir, d));
        }

        if (!keepUserData)
        {
            foreach (string sub in new string[] { "Download", "Log", "Cache", "Data", "Backup" })
                TryDeleteDir(Path.Combine(dir, sub));
        }

        // 自己删自己：等 2 秒让本进程退出，再 del 掉 exe，空文件夹顺手 rmdir
        string cmd = "/c ping 127.0.0.1 -n 3 >nul & del /f /q \"" + self + "\"";
        cmd += keepUserData
            ? " & rmdir \"" + dir + "\" 2>nul"
            : " & rmdir /s /q \"" + dir + "\" 2>nul";
        try
        {
            Process.Start(new ProcessStartInfo("cmd.exe", cmd)
            {
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                UseShellExecute = false
            });
        }
        catch (Exception e)
        {
            Log("schedule self-delete failed: " + e.Message);
        }
    }

    // ---------------------------------------------------------------- 清理

    private static void KillRunning(string dir)
    {
        // 和安装器同一套：jpackage 是父子两个同名进程，路径读不到时也要按进程名处理，
        // 否则卸载会留下一个还在跑的实例，接着 app\ / runtime\ 删不掉。
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
                catch (Exception e) { Log("kill failed: " + e.Message); }
                finally { p.Dispose(); }
            }
            if (!any) return;
            System.Threading.Thread.Sleep(600);
        }
    }

    private static void RemoveShortcuts()
    {
        string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        if (!string.IsNullOrEmpty(desktop))
            TryDeleteFile(Path.Combine(desktop, AppName + ".lnk"));

        string programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
        if (!string.IsNullOrEmpty(programs))
            TryDeleteDir(Path.Combine(programs, AppName));
    }

    private static void RemoveRegistry()
    {
        try
        {
            Registry.CurrentUser.DeleteSubKeyTree(
                "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\JZ Music", false);
        }
        catch (Exception e)
        {
            Log("registry delete failed: " + e.Message);
        }
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception e) { Log("delete file failed: " + path + " " + e.Message); }
    }

    private static void TryDeleteDir(string path)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, true);
        }
        catch (Exception e) { Log("delete dir failed: " + path + " " + e.Message); }
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
}
