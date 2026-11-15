import java.awt.Robot;
import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;

/**
 * 极简 UI 驱动器：给桌面版做黑盒验证（等价 APK 侧 adb input）。
 * 用法（坐标一律是 Java 用户空间坐标，即"逻辑像素"）：
 *   java UiDrive.java click  <x> <y>
 *   java UiDrive.java dbl    <x> <y>
 *   java UiDrive.java drag   <x1> <y1> <x2> <y2>
 *   java UiDrive.java key    <KEYCODE>           例如 SPACE / LEFT / ESCAPE
 *   java UiDrive.java type   <text>
 */
public class UiDrive {
    public static void main(String[] args) throws Exception {
        Robot r = new Robot();
        r.setAutoDelay(70);
        String cmd = args[0];
        switch (cmd) {
            case "click":
            case "dbl": {
                int x = Integer.parseInt(args[1]), y = Integer.parseInt(args[2]);
                r.mouseMove(x, y);
                r.delay(200);
                r.mousePress(InputEvent.BUTTON1_DOWN_MASK);
                r.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);
                if (cmd.equals("dbl")) {
                    r.delay(90);
                    r.mousePress(InputEvent.BUTTON1_DOWN_MASK);
                    r.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);
                }
                break;
            }
            case "drag": {
                int x1 = Integer.parseInt(args[1]), y1 = Integer.parseInt(args[2]);
                int x2 = Integer.parseInt(args[3]), y2 = Integer.parseInt(args[4]);
                r.mouseMove(x1, y1);
                r.delay(150);
                r.mousePress(InputEvent.BUTTON1_DOWN_MASK);
                int steps = 24;
                for (int i = 1; i <= steps; i++) {
                    r.mouseMove(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps);
                    r.delay(12);
                }
                r.mouseRelease(InputEvent.BUTTON1_DOWN_MASK);
                break;
            }
            case "key": {
                int code = KeyEvent.class.getField("VK_" + args[1]).getInt(null);
                r.keyPress(code);
                r.delay(40);
                r.keyRelease(code);
                break;
            }
            case "type": {
                for (char c : args[1].toCharArray()) {
                    boolean upper = Character.isUpperCase(c);
                    int code = KeyEvent.getExtendedKeyCodeForChar(c);
                    if (code == KeyEvent.VK_UNDEFINED) continue;
                    if (upper) r.keyPress(KeyEvent.VK_SHIFT);
                    r.keyPress(code);
                    r.keyRelease(code);
                    if (upper) r.keyRelease(KeyEvent.VK_SHIFT);
                }
                break;
            }
            case "wheel": {
                int x = Integer.parseInt(args[1]), y = Integer.parseInt(args[2]);
                int notches = Integer.parseInt(args[3]);
                r.mouseMove(x, y);
                r.delay(150);
                for (int i = 0; i < Math.abs(notches); i++) {
                    r.mouseWheel(notches > 0 ? 1 : -1);
                    r.delay(35);
                }
                break;
            }
            default:
                System.err.println("unknown command: " + cmd);
                System.exit(2);
        }
        r.delay(120);
    }
}
