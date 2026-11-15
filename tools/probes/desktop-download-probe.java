import com.jz.musichelper.data.AppEnv;
import com.jz.musichelper.data.DownloadManager;
import com.jz.musichelper.data.HistoryStore;
import com.jz.musichelper.model.DownloadItem;
import com.jz.musichelper.model.DownloadStatus;
import com.jz.musichelper.model.MusicPlatform;
import com.jz.musichelper.model.QualityLevel;
import com.jz.musichelper.model.Song;
import kotlin.Unit;
import kotlin.jvm.functions.Function1;

/**
 * 桌面版「下载落盘」探针：不点界面，直接走 DownloadManager 的真实链路
 * （候选解析 → 自动换源 → 体积校验 → 写盘），确认文件落在安装目录的 Download\。
 *
 * 这弥补了一个验证盲区：界面自动化点不到时，仍能证明「下载的音乐进 Download 文件夹」。
 *
 * 用法（**在安装目录里**执行，classpath 指向 app\ 下的 jar）：
 *
 *   cd "D:\JZ Music"
 *   java -cp "app\*" D:\Projects\Private_music\tools\probes\desktop-download-probe.java 003aAYrm3GE0Ac 稻香 周杰伦 223
 *
 * 参数：QQ songmid / 歌名 / 歌手 / 时长秒（可省，默认 223）。
 * 输出：downloadDir、状态变化、localPath、Download 目录里的文件清单。
 * 注意：会往 Data\ 的下载记录里写一条真实记录（和界面里点下载等价）。
 */
public class DesktopDownloadProbe {

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.out.println("用法: <QQ songmid> <歌名> <歌手> [时长秒]");
            return;
        }
        String songmid = args[0];
        String name = args[1];
        String singer = args[2];
        int duration = args.length > 3 ? Integer.parseInt(args[3]) : 223;

        AppEnv.INSTANCE.ensureLayout();
        HistoryStore.INSTANCE.init();
        DownloadManager.INSTANCE.init();
        System.out.println("downloadDir=" + AppEnv.INSTANCE.getDownloadDir());

        Song song = new Song(MusicPlatform.QQ, songmid, name, singer, "", duration, null);
        DownloadManager.INSTANCE.startDownload(song, QualityLevel.HIGH, new Function1<String, Unit>() {
            public Unit invoke(String msg) {
                System.out.println("MSG: " + msg);
                return Unit.INSTANCE;
            }
        });

        DownloadStatus lastStatus = null;
        for (int i = 0; i < 120; i++) {
            Thread.sleep(1000);
            java.util.List<DownloadItem> items = DownloadManager.INSTANCE.getItems().getValue();
            if (items.isEmpty()) continue;
            DownloadItem item = items.get(0);
            if (item.getStatus() != lastStatus) {
                System.out.println(item.getStatus() + " p=" + item.getProgress());
                lastStatus = item.getStatus();
            }
            if (item.getStatus() == DownloadStatus.COMPLETED || item.getStatus() == DownloadStatus.FAILED) {
                System.out.println("localPath=" + item.getLocalPath());
                System.out.println("note=" + item.getNote());
                System.out.println("error=" + item.getErrorMessage());
                break;
            }
        }

        System.out.println("files in " + AppEnv.INSTANCE.getDownloadDir() + ":");
        java.io.File[] files = AppEnv.INSTANCE.getDownloadDir().listFiles();
        if (files != null) {
            for (java.io.File f : files) System.out.println("  " + f.getName() + "  " + f.length() + "B");
        }
        System.exit(0);
    }
}
