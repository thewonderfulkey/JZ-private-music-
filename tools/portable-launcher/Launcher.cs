using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

// 单文件启动器：把整份 app-image 作为资源嵌在自身里。
//   · 首次运行：解包到 %LOCALAPPDATA%\JZ Music\app-<版本>\ 并写 .ready 标记
//   · 之后运行：直接拉起里面的 JZ Music.exe（不重复解包，秒开）
// 这样分发给别人的就是一个 exe，双击即用，不需要安装、不需要目录。
internal static class Launcher
{
    private const string AppVersion = "2.1.95";
    private const string InnerExe = "JZ Music.exe";
    private const string ResourceName = "payload.zip";
    // 同一版本只解包一次；升级时版本目录变了会重新解
    private static string TargetRoot()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "JZ Music",
            "app-" + AppVersion + "-" + PayloadStamp.Value);
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string root = TargetRoot();
            string exe = Path.Combine(root, InnerExe);
            string ready = Path.Combine(root, ".ready");

            if (!File.Exists(exe) || !File.Exists(ready))
            {
                if (!Extract(root))
                {
                    return 1;
                }
            }

            var psi = new ProcessStartInfo(exe)
            {
                WorkingDirectory = root,
                UseShellExecute = true,
                // 把"用户双击的这个 exe 所在目录"传进去：应用据此向上找项目根，
                // 日志就落在项目目录里（而不是解包目录所在的 C 盘）
                Arguments = "--launch-dir=\"" + Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location) + "\"",
            };
            Process.Start(psi);
            return 0;
        }
        catch (Exception e)
        {
            MessageBox.Show(
                "启动失败：" + e.Message + "\r\n\r\n" + e,
                "JZ Music",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 2;
        }
    }

    private static bool Extract(string root)
    {
        try
        {
            Directory.CreateDirectory(root);
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
            {
                if (s == null)
                {
                    MessageBox.Show("安装包损坏：找不到内置资源。", "JZ Music",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return false;
                }
                using (var zip = new ZipArchive(s, ZipArchiveMode.Read))
                {
                    foreach (ZipArchiveEntry entry in zip.Entries)
                    {
                        string name = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                        if (string.IsNullOrEmpty(name)) continue;
                        string dest = Path.Combine(root, name);
                        if (name.EndsWith(Path.DirectorySeparatorChar.ToString()))
                        {
                            Directory.CreateDirectory(dest);
                            continue;
                        }
                        Directory.CreateDirectory(Path.GetDirectoryName(dest));
                        // FileMode.Create：覆盖上次可能残留的半截文件
                        using (var outStream = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None))
                        using (Stream inStream = entry.Open())
                        {
                            inStream.CopyTo(outStream);
                        }
                    }
                }
            }
            File.WriteAllText(Path.Combine(root, ".ready"), DateTime.Now.ToString("s"));
            return true;
        }
        catch (Exception e)
        {
            MessageBox.Show(
                "解包失败：" + e.Message + "\r\n\r\n目标目录：" + root,
                "JZ Music",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return false;
        }
    }
}
