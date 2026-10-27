# Architecture

```
 Mac                                                            Android (VM)
┌──────────────────────────────────────────┐                  ┌──────────────────────────────┐
│ Mac Android Subsystem.app  (menu bar)    │   QEMU + HVF     │ LineageOS 24, virtio_arm64only│
│  VirtualMachine ── qemu-system-aarch64 ──┼─────────────────▶│                              │
│  Subsystem (state, timers, status.json)  │                  │ adbd :5555                   │
│  AppCatalog / LauncherGenerator          │   ADB over TCP   │  ▲                           │
│  PackageInstaller / NotificationRelay ───┼─127.0.0.1:58526─▶│  │ content read …            │
│  ADBConnection (own client)              │                  │ bridge.apk (provider +       │
└──────────────────────────────────────────┘                  │   notification listener)    │
                                                              │                              │
 ~/Applications/Android Apps/F-Droid.app   (one per app)      │ scrcpy server (app_process)  │
┌──────────────────────────────────────────┐                  │  ├ virtual display #N        │
│ AndroidAppHost (copy)                    │   ADB stream     │  │   └ the app's activity     │
│  ScrcpySession ── localabstract:scrcpy_… ┼─────────────────▶│  └ H.264 encoder, input      │
│  AVSampleBufferDisplayLayer ◀── H.264 ───┼──────────────────│                              │
│  mouse/keys/clipboard ── control msgs ───┼─────────────────▶│                              │
└──────────────────────────────────────────┘                  └──────────────────────────────┘
```

## Processes

- **Mac Android Subsystem.app** is an agent (`LSUIElement`) with a menu bar item. It owns QEMU, keeps one ADB connection, and writes `status.json` (off / starting / running / failed, the ADB port).
- **Each Android app** has a launcher bundle in `~/Applications/Android Apps`. Its executable is a copy of `AndroidAppHost`; its `Info.plist` names the Android package (`MSAPackageName`). Separate processes give each Android app its own Dock icon, ⌘-Tab entry and menu bar.
- **QEMU** runs as a child process of the Subsystem: `-machine virt -accel hvf -cpu host`, UEFI from `edk2-aarch64-code.fd`, virtio-blk disks, user-mode networking with `hostfwd=tcp:127.0.0.1:58526-:5555`, `intel-hda` through Core Audio (`hda-output`), or through SDL (`hda-duplex`) when the microphone is on, since QEMU's Core Audio backend can't record, `-display none`.

## Starting Android

1. A launcher (or the person) opens `msa://start`. The Subsystem launches QEMU on the image's copy-on-write disks (`vm/disk*.qcow2`, backed by the read-only image in `rom/`). First `GrubEnvironment` turns on the image's GRUB *Insecure ADB* setting (`android_insecure_adb=1` in `grubenv` on the FAT32 PERSIST partition, written into the overlay with `qemu-img`) and sets `grub_timeout=0` to skip GRUB's 10 s menu. jqssun's images need it: they're Android 16 user builds, whose setup wizard otherwise starts trade-in mode, in which adbd refuses everything but `tradeinmode` commands.
2. It connects to adbd (RSA key in `adbkey`; neither image prompts), restarts Android once if an earlier boot left adbd in trade-in mode, waits for `sys.boot_completed`, and on the first boot marks Android as set up, keeps it awake and sets the time zone.
3. It installs or updates `bridge.apk` and grants its notification listener, pushes `scrcpy-server.jar`, then marks itself *running*.
4. Every 10 s it reads `apps.json` from the bridge and creates, refreshes or removes launchers (icons come from `icon/<package>`; adaptive icons are cropped onto the macOS icon grid). Every 3 s it reads `notifications.json` and posts new ones.

*As needed* turns Android off (`reboot -p`, then SIGTERM) once no launcher process has run for the idle time. *Continuous* starts it at launch.

## One app window

`AndroidWindowController` waits for `status.json` to say *running*, connects its own ADB transport, and starts the scrcpy server through `exec:` with:

```
new_display=<window pixels>/<dpi> flex_display=true vd_system_decorations=false
display_ime_policy=hide video_codec=h264 audio=false tunnel_forward=true
```

It then opens `localabstract:scrcpy_<scid>` twice through ADB (video, then control; no port forwarding), switches the new virtual display to fullscreen with `cmd window set-display-windowing-mode` (the image declares `android.hardware.type.pc`, so Android would otherwise open the app as a small freeform window) and sends `START_APP <package>`. Video packets become `CMSampleBuffer`s (`H264SampleBuilder`) for an `AVSampleBufferDisplayLayer`, which decodes in hardware. Mouse buttons become touches, the wheel becomes scroll events, a trackpad pinch or rotation becomes two fingers around the pointer (scrcpy's generic and virtual finger pointers, the ones its own pinch uses), printable keys become text and the rest become Android keycodes. Resizing the window sends `RESIZE_DISPLAY`, so the Android display (and the app's layout) follows the window. `dpi = 160 × backing scale × App size`, so one Android dp is one Mac point at the default size.

Sound doesn't go through scrcpy: Android plays through the VM's `intel-hda` device, so all apps share one audio path.

## Always Ready and the menu bar

*Always ready* turns on the login item (`SMAppService.mainApp`) and the *Continuous* resources setting, so Android boots at login. A launch at login stays in the menu bar (detected from the open-application event's login-item flag, or a launch within three minutes of the login session starting with the login item on). The menu bar item shows status and the current level, and offers start/restart/turn off, the performance modes, Always Ready, open/install apps, Settings and Quit. Quitting runs `reboot -p` inside Android before QEMU exits.

## Performance modes

`PerformanceManager` resolves the chosen mode to a level and applies it live:

| Level | QEMU scheduling | Android cores online | Memory kept (balloon) | Android power | Window stream |
|---|---|---|---|---|---|
| Saver | `PRIO_DARWIN_BG` (efficiency cores, throttled I/O) | 25%, at least 2 (userdebug image only) | 60% | battery saver on | 30 fps, 6 Mb/s |
| Balanced | normal | 50% (userdebug image only) | 85% | normal | 60 fps, 10 Mb/s |
| Standard | normal | all | 100% | normal (Android's defaults) | 60 fps, 10 Mb/s |
| Performance | normal | all | 100% | fixed-performance mode, `cmd game mode performance <pkg>` | up to 120 fps, 20 Mb/s |

Cores go offline with CPU hotplug (`su 0 sh -c 'echo 0 > /sys/devices/system/cpu/cpuN/online'`). That needs root: adbd runs as shell (uid 2000), which can't write `cpuN/online`, and only the project's userdebug image has `su`. `PerformanceManager` asks `su 0 id -u` once per boot and skips hotplug when it fails, so on jqssun's user builds every core stays online and the other levers do the saving; memory goes back through `-device virtio-balloon-pci` and QMP `balloon`; Android's settings through `cmd power set-mode` and `set-fixed-performance-mode-enabled`. The level is written to `status.json`; app windows read it when they open (frame rate, bitrate) and hold a latency-critical activity in Performance.

Modes map to levels as follows. Standard → Standard and Performance → Performance, always. (Gaming was merged into Performance; a saved `game` mode reads as Performance.)

*Power Saver* (a hybrid of saving and Smart): Saver when constrained (below) or on battery; otherwise Balanced while an Android app is in front, Saver when not. Android only runs while an app is open.

*Smart* (stays ready) re-evaluates every 10 s and whenever the front app, power source, Low Power Mode or thermal state changes. It is *constrained* when Low Power Mode is on, the Mac is hot (thermal state serious or critical), the battery is under 20%, memory pressure is at warning or above (`kern.memorystatus_vm_pressure_level`), or other processes have used more than 70% of the processor for two samples in a row (host CPU ticks minus QEMU's own time from `proc_pid_rusage`, sampled at most every 5 s). Constrained → Saver, except while an Android app is in front → Balanced (Saver's `PRIO_DARWIN_BG` starved the app in front: frames took seconds on SwiftShader and apps hit ANRs); no Android window open → Saver; a game in front (the bridge reports `ApplicationInfo.category == CATEGORY_GAME`) → Performance; another Android app in front → Performance (Balanced on battery); Android windows open behind a Mac app → Balanced (Saver on battery).

## When Android turns off

`Subsystem.idleShutdownDelay()` decides how long Android may run with no launcher process: Power Saver 30 s (always, and Always Ready doesn't start it); *As needed* the chosen minutes; *Continuous* never; *Automatic* (default) never for Smart, Standard and Performance. The check runs every 10 s and whenever the mode or setting changes.

## Storage clean-up

`StorageJanitor` runs at launch (after 60 s), every 6 h and 20 s after Android turns off. Light: finished/abandoned downloads, `rom/.staging-*`, images that aren't current, overlays of replaced images, `msa-install-*` temp folders, notification attachment copies older than a day, icons of removed apps, logs over 2 MB (cut to their last 256 KB while QEMU is off), and a daily `sm fstrim` in Android (disks use `discard=unmap`, so trimmed space leaves the qcow2 files; also run before shutdown when due). Deep (under 15 GB free, or *Clean Up Now*): `pm trim-caches` in Android and, while Android is off, `qemu-img convert -O qcow2 -B <base>` on each overlay, kept only if smaller. Compaction also runs weekly on power; `Subsystem.start()` waits for it.

## Game controllers

`GamepadBridge` in each window host listens to the Game Controller framework. While its window is key, each controller becomes a UHID device in Android through scrcpy's `UHID_CREATE`/`UHID_INPUT` control messages, with scrcpy's gamepad report descriptor (an Xbox 360-style pad, vendor 045e product 028e). The scrcpy server associates UHID devices with its session's virtual display, so input reaches the game in that window. When the window resigns key the devices are destroyed, so the controller follows the window in front.

## The bridge app

`android/bridge` has no UI. Its content provider (readable only by the shell user, through `android.permission.DUMP`) serves:

| Path | Contents |
|---|---|
| `version` | the bridge's versionCode (`MSA_BRIDGE_VERSION`) |
| `apps.json` | launchable apps: package, activity, label, versionName, system, adaptive, game, updated |
| `icon/<package>` | 512×512 PNG; adaptive icons drawn without a mask |
| `notifications.json` | active notifications from `NotificationRelayService` |

The Mac reads them with `content read --uri content://io.github.harkhowalia1.msa.bridge/<path>`.

## Files

```
~/Library/Application Support/Mac Android Subsystem/
    adbkey  status.json  apps.json  icons/
    rom/current.json  rom/<image>/LineageOS_on_ARM64.utm/{config.plist,Data/…}
    vm/disk0-….qcow2  vm/efi_vars.fd  vm/qemu.log  vm/console.log
~/Applications/Android Apps/<App>.app
```

## Next steps

- GPU acceleration: virtio-gpu-gl with virglrenderer and ANGLE (as UTM does) instead of software rendering.
- Camera, location and shared folders.
- Close the Mac window when the Android app finishes its last activity.
- Faster *As needed* starts with a saved VM snapshot.

## Identity and renaming

Android calls itself "Mac Android Subsystem (MAS)": QEMU's SMBIOS (`-smbios type=1/2`) sets the manufacturer and model Android reads at boot, and `settings put global device_name` / `secure bluetooth_name` set the device name on every boot (`AndroidSetup.applyIdentity`). The name comes from `APP_NAME` and `APP_SHORT_NAME` in `apple/Config/Base.xcconfig`.

When the app is renamed, `SubsystemPaths.support` moves the folder from any name in `LEGACY_SUPPORT_FOLDERS`, `AndroidImage.runtimeDisks` repoints the qcow2 overlays at their base disks' new path (`qemu-img rebase -u`, header only), and `RenameMigration` moves the old copy of the app (same bundle identifier and URL scheme) to the Trash and renews the login item. Launchers are rebuilt because their generation includes the app version.

## Settings that apply at start

`Subsystem.launchedWith` records the memory, processor cores, microphone and Android-screen settings Android was started with; `changesNeedingRestart` lists those that differ now. The settings window shows a banner with *Restart Now* and the menu bar menu shows *Restart Android to Apply Changes* while the list isn't empty.
