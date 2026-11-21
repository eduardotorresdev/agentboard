package agentboard;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.HandlerThread;
import android.os.Looper;
import android.view.accessibility.AccessibilityNodeInfo;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;

/**
 * The screen's elements for a simulator card's snapshot, without uiautomator's wait for the UI
 * to go idle. Run as the shell user, the way scrcpy-server is:
 *
 *   CLASSPATH=/data/local/tmp/agentboard-ui-dumper.dex app_process / agentboard.UiDumper [socket]
 *
 * It connects a UiAutomation once (as uiautomator does, through hidden API), keeps the other
 * accessibility services running, leaves out views not important for accessibility (as
 * `uiautomator dump --compressed` does), and stays up until its stdin closes: each connection to
 * localabstract:<socket> ("agentboard-ui" by default) gets the active window's visible nodes,
 * one per line, tab-separated: depth, class, left, top, width, height, label, value. The label is
 * the content description, else the text; the value is the text when there is a description and it differs.
 * Build with build.sh next to this file.
 */
public final class UiDumper {
    public static void main(String[] args) throws Exception {
        // The accessibility client posts to the main looper, which app_process doesn't prepare.
        Looper.prepareMainLooper();
        HandlerThread thread = new HandlerThread("agentboard-ui");
        thread.start();
        UiAutomation automation = connect(thread.getLooper());
        AccessibilityServiceInfo info = automation.getServiceInfo();
        info.flags &= ~AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS;
        automation.setServiceInfo(info);
        LocalServerSocket server = new LocalServerSocket(args.length > 0 ? args[0] : "agentboard-ui");
        // The board holds the adb stream it was started on: when that closes, so does this.
        Thread watch = new Thread(() -> {
            try {
                while (System.in.read() >= 0) { }
            } catch (IOException ignored) {
            }
            System.exit(0);
        });
        watch.setDaemon(true);
        watch.start();
        System.out.println("ready");
        System.out.flush();
        while (true) {
            try (LocalSocket client = server.accept();
                 Writer out = new BufferedWriter(new OutputStreamWriter(client.getOutputStream(), "UTF-8"))) {
                AccessibilityNodeInfo root = null;
                // No active window for a moment while one replaces another.
                for (int attempt = 0; attempt < 20 && root == null; attempt++) {
                    root = automation.getRootInActiveWindow();
                    if (root == null) Thread.sleep(100);
                }
                if (root != null) write(root, 0, out);
                out.flush();
            } catch (IOException ignored) {
                // The board went away mid-answer: wait for the next one.
            }
        }
    }

    /** new UiAutomation(looper, new UiAutomationConnection()).connect(flags), all hidden. */
    private static UiAutomation connect(Looper looper) throws Exception {
        Object connection = Class.forName("android.app.UiAutomationConnection").getDeclaredConstructor().newInstance();
        Constructor<UiAutomation> constructor =
                UiAutomation.class.getDeclaredConstructor(Looper.class, Class.forName("android.app.IUiAutomationConnection"));
        constructor.setAccessible(true);
        UiAutomation automation = constructor.newInstance(looper, connection);
        Method connect = UiAutomation.class.getDeclaredMethod("connect", int.class);
        connect.setAccessible(true);
        connect.invoke(automation, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
        return automation;
    }

    private static void write(AccessibilityNodeInfo node, int depth, Writer out) throws IOException {
        if (!node.isVisibleToUser()) return;
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        String className = node.getClassName() == null ? "View" : node.getClassName().toString();
        String text = clean(node.getText()), description = clean(node.getContentDescription());
        String label = description.isEmpty() ? text : description;
        String value = description.isEmpty() || text.equals(description) ? "" : text;
        out.write(depth + "\t" + className.substring(className.lastIndexOf('.') + 1) + "\t" + bounds.left + "\t" + bounds.top + "\t"
                + bounds.width() + "\t" + bounds.height() + "\t" + label + "\t" + value + "\n");
        for (int index = 0; index < node.getChildCount(); index++) {
            AccessibilityNodeInfo child = node.getChild(index);
            if (child != null) write(child, depth + 1, out);
        }
    }

    private static String clean(CharSequence text) {
        return text == null ? "" : text.toString().replace('\t', ' ').replace('\n', ' ').replace('\r', ' ');
    }
}
