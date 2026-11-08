// Mac Android Subsystem - the keyboard Android uses while it runs on the Mac.
//
// It has no keys on screen. Each Mac window connects to the abstract socket
// "msa_ime" over ADB and sends the text the Mac's keyboard and input methods
// produce, so text in any script reaches the app (scrcpy's text injection only
// carries characters Android's virtual key map has, so Persian, Russian or
// Chinese never arrived). Composing text from a Mac input method (Pinyin, Kana,
// dead keys) shows in the app underlined, as with a phone keyboard. Editing keys
// go the same way while an editor has input, so they stay in order with the text.
//
// The Mac selects it with
//   ime enable io.github.harkhowalia1.msa.bridge/.MacInputMethod
//   ime set io.github.harkhowalia1.msa.bridge/.MacInputMethod
// Only the shell user (ADB) and root may connect; other apps can't type with it.
//
// Messages, big-endian. Mac to Android:
//   1 hello     displayId:i32                the window's virtual display
//   2 commit    length:u32 UTF-8             text typed
//   3 compose   length:u32 UTF-8             the composing text so far
//   4 finish                                 keep the composing text as typed
//   5 key       action:u8 keycode:i32 metaState:i32 repeat:i32
// Android to Mac:
//   1 editing   displayId:i32 active:u8      an editor on that display got or lost input
//
// Licensed under the GNU General Public License v3 or later.

package io.github.harkhowalia1.msa.bridge;

import android.content.res.Configuration;
import android.inputmethodservice.InputMethodService;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.text.InputType;
import android.util.Log;
import android.view.Display;
import android.view.InputDevice;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CopyOnWriteArrayList;

public final class MacInputMethod extends InputMethodService {
    private static final String TAG = "MacInputMethod";
    private static final String SOCKET = "msa_ime";
    private static final int MAX_TEXT = 256 * 1024;

    // The socket and the Mac's connections belong to the process, not to one instance:
    // Android destroys and makes the service again (when input moves to another
    // display, for one), and the windows stay connected through that.
    private static final CopyOnWriteArrayList<Client> clients = new CopyOnWriteArrayList<>();
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static Thread server;
    /** The running instance, null between two. Main thread only. */
    private static MacInputMethod current;
    /** The display of the editor that has input, or -1 when none does. Main thread only. */
    private static int editingDisplay = Display.INVALID_DISPLAY;

    @Override
    public void onCreate() {
        super.onCreate();
        current = this;
        if (server == null || !server.isAlive()) {
            server = new Thread(MacInputMethod::serve, "msa-ime");
            server.setDaemon(true);
            server.start();
        }
    }

    @Override
    public void onDestroy() {
        if (current == this) {
            current = null;
            setEditingDisplay(Display.INVALID_DISPLAY);
        }
        super.onDestroy();
    }

    // Nothing to show: the keys are on the Mac.
    @Override
    public boolean onEvaluateInputViewShown() {
        return false;
    }

    @Override
    public boolean onEvaluateFullscreenMode() {
        return false;
    }

    @Override
    public void onStartInput(EditorInfo attribute, boolean restarting) {
        super.onStartInput(attribute, restarting);
        // A view that takes no text (a game's surface, a terminal) wants raw key events.
        boolean text = attribute != null && attribute.inputType != InputType.TYPE_NULL;
        setEditingDisplay(text ? currentDisplay() : Display.INVALID_DISPLAY);
    }

    @Override
    public void onFinishInput() {
        super.onFinishInput();
        setEditingDisplay(Display.INVALID_DISPLAY);
    }

    // The IME's window follows the editor to its display, and this service's context with it.
    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        if (editingDisplay != Display.INVALID_DISPLAY) setEditingDisplay(currentDisplay());
    }

    private int currentDisplay() {
        Display display = getDisplay();
        return display != null ? display.getDisplayId() : Display.INVALID_DISPLAY;
    }

    private static void setEditingDisplay(int display) {
        if (display == editingDisplay) return;
        int previous = editingDisplay;
        editingDisplay = display;
        for (Client client : clients) {
            if (previous != Display.INVALID_DISPLAY) client.sendEditing(previous, false);
            if (display != Display.INVALID_DISPLAY) client.sendEditing(display, true);
        }
    }

    /** The editor's connection, if it is on the window's display. */
    private static InputConnection connectionFor(int display) {
        MacInputMethod service = current;
        return service != null && display == editingDisplay ? service.getCurrentInputConnection() : null;
    }

    private static void serve() {
        try (LocalServerSocket listener = new LocalServerSocket(SOCKET)) {
            while (true) {
                LocalSocket socket = listener.accept();
                int uid = socket.getPeerCredentials().getUid();
                if (uid != Process.SHELL_UID && uid != Process.ROOT_UID) {
                    socket.close();
                    continue;
                }
                Client client;
                try {
                    client = new Client(socket);
                } catch (IOException e) {
                    socket.close();
                    continue;
                }
                clients.add(client);
                Thread thread = new Thread(client::run, "msa-ime-client");
                thread.setDaemon(true);
                thread.start();
            }
        } catch (IOException e) {
            Log.w(TAG, "socket closed", e);
        }
    }

    private static final class Client {
        private final LocalSocket socket;
        private final DataOutputStream out;
        /** The window's display, from its hello. Main thread only. */
        private int display = Display.INVALID_DISPLAY;

        Client(LocalSocket socket) throws IOException {
            this.socket = socket;
            out = new DataOutputStream(socket.getOutputStream());
        }

        void run() {
            try (DataInputStream in = new DataInputStream(socket.getInputStream())) {
                while (true) {
                    int type = in.readUnsignedByte();
                    switch (type) {
                        case 1:
                            int id = in.readInt();
                            main.post(() -> {
                                display = id;
                                if (editingDisplay == id) sendEditing(id, true);
                            });
                            break;
                        case 2: {
                            String text = readText(in);
                            main.post(() -> {
                                InputConnection ic = connectionFor(display);
                                if (ic != null) ic.commitText(text, 1);
                            });
                            break;
                        }
                        case 3: {
                            String text = readText(in);
                            main.post(() -> {
                                InputConnection ic = connectionFor(display);
                                if (ic != null) ic.setComposingText(text, 1);
                            });
                            break;
                        }
                        case 4:
                            main.post(() -> {
                                InputConnection ic = connectionFor(display);
                                if (ic != null) ic.finishComposingText();
                            });
                            break;
                        case 5: {
                            int action = in.readUnsignedByte();
                            int keycode = in.readInt();
                            int metaState = in.readInt();
                            int repeat = in.readInt();
                            main.post(() -> {
                                InputConnection ic = connectionFor(display);
                                if (ic != null) ic.sendKeyEvent(keyEvent(action, keycode, metaState, repeat));
                            });
                            break;
                        }
                        default:
                            throw new IOException("unknown message " + type);
                    }
                }
            } catch (EOFException ignored) {
                // The window closed.
            } catch (IOException e) {
                Log.w(TAG, "client", e);
            } finally {
                close();
            }
        }

        void sendEditing(int id, boolean active) {
            if (display != Display.INVALID_DISPLAY && display != id) return;
            try {
                synchronized (this) {
                    out.writeByte(1);
                    out.writeInt(id);
                    out.writeByte(active ? 1 : 0);
                    out.flush();
                }
            } catch (IOException e) {
                close();
            }
        }

        void close() {
            clients.remove(this);
            try {
                socket.close();
            } catch (IOException ignored) {
            }
        }
    }

    private static String readText(DataInputStream in) throws IOException {
        int length = in.readInt();
        if (length < 0 || length > MAX_TEXT) throw new IOException("text of " + length + " bytes");
        byte[] bytes = new byte[length];
        in.readFully(bytes);
        return new String(bytes, StandardCharsets.UTF_8);
    }

    private static KeyEvent keyEvent(int action, int keycode, int metaState, int repeat) {
        long now = SystemClock.uptimeMillis();
        return new KeyEvent(now, now, action, keycode, repeat, metaState, KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                KeyEvent.FLAG_SOFT_KEYBOARD | KeyEvent.FLAG_KEEP_TOUCH_MODE, InputDevice.SOURCE_KEYBOARD);
    }
}
