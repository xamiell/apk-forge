# APK Forge

A desktop app to **build, sign, verify and install Android APKs** from one
screen, instead of remembering the flags of `flutter build`, `zipalign`,
`apksigner`, `keytool` and `adb`.

APK Forge doesn't reimplement any of them. It drives the official tools you
already have installed, shows the exact command before and while it runs,
and streams every line of output into a log. When something fails you see
the tool's own reason, not a generic error.

![APK Forge: Build, Sign and Install on the left; Analyze APK, Analyze device and the log on the right](docs/screenshot.png)

## Features

| Panel | What it does |
|---|---|
| **Build** | Runs `flutter build apk` on any Flutter project. Choose release or debug, any mix of `armeabi-v7a`, `arm64-v8a` and `x86_64`, and one universal APK or one APK per ABI (`--split-per-abi`, offered when two or more ABIs are selected). Optional Dart obfuscation keeps the symbols you need to read crash traces. The command is previewed before you run it. |
| **Sign** | Signs the APKs a build just produced, or any APK you pick (from CI, another machine, a store), with your `.jks`, `.keystore` or `.p12`. It checks the alignment first and fixes it if needed, writes `<name>-signed.apk` without touching the original, and verifies that the result carries exactly the key you chose. **Split per ABI and sign** turns a universal APK (one from CI, say) into one signed APK per ABI. |
| **Analyze APK** | For any APK: whether the signature verifies; the schemes it carries (v1 to v4); the signer certificate (DN, SHA-256, SHA-1), and whether it is **your key** or the Android debug key; release or debug (`debuggable`); package, version and SDK levels; native code per ABI, flagging an ABI with no Flutter engine; size, MD5 and SHA-256. |
| **Analyze device** | For the device on USB: maker, brand, model and codename; Android version, API level, security patch, build and build type; chip, ABIs, memory page size (16 KB pages are flagged), RAM, storage and screen; battery, locale and time zone. With an APK selected, it tells you which ABI the APK would run as, which version is installed, and whether installing would be a fresh install, an upgrade, a reinstall or a downgrade. One click copies it all as text. |
| **Install** | Installs the selected APK with `adb install -r` (optionally `-d` to allow a downgrade). It warns first when the APK has no native code for the device, and explains the common install failures. |
| **Log** | Every command and its output, live, with errors and warnings colored. A failed step also shows its reason in a banner above the log, Gradle's "What went wrong" included. **Cancel** stops the running step. |

## Requirements

| Tool | Used by | Where it comes from |
|---|---|---|
| Flutter SDK | Build | [flutter.dev](https://docs.flutter.dev/get-started/install), on your `PATH` or set in Tools |
| Android SDK build-tools: `apksigner`, `zipalign`, `aapt2` | Sign, Analyze APK | Android Studio → SDK Manager |
| Android SDK platform-tools: `adb` | Analyze device, Install | Android Studio → SDK Manager |
| A JDK: `keytool`, and Java for `apksigner` | Sign | Android Studio's bundled JDK works |

You don't configure paths by hand. At startup the app reads your login
shell's environment, the same one your terminal has. An app opened from
Finder or the Dock otherwise gets a bare `PATH`. It then looks at
`ANDROID_HOME`, `ANDROID_SDK_ROOT` and the default SDK folder for each OS,
and picks the newest build-tools.

The pills in the top bar show what was found. The gear lets you point to a
different Flutter or Android SDK.

### Platforms

| OS | Status |
|---|---|
| macOS | Tested |
| Windows | The code handles its paths and tool names (`apksigner.bat`, `adb.exe`, `%LOCALAPPDATA%`); not tried yet |
| Linux | The code handles its paths and tool names; not tried yet |

## Getting started

```bash
git clone https://github.com/xamiell/apk-forge.git
cd apk-forge
flutter pub get
flutter run -d macos
```

To build the app itself:

```bash
flutter build macos --release
# → build/macos/Build/Products/Release/APK Forge.app
```

The macOS app runs **without the App Sandbox**, because a sandboxed app
can't start `flutter`, `adb` or `apksigner`. A local build isn't notarized.
If you copy it to another Mac, Gatekeeper may block it. Right-click it and
choose Open, or remove the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/APK Forge.app"
```

## Using it

### Build and sign a Flutter app

1. **Build:** choose the project folder, release or debug, the
   architectures and the output (universal or split per ABI). Turn on
   obfuscation if you want it.
2. **Sign:** choose your keystore, enter its password, press **Load keys**
   and pick the key. The panel shows the key's owner and SHA-256, so you can
   confirm it's the right one before signing.
3. Press **Build and sign**. The build output streams into the log. Every
   APK the build produced is then signed and verified, and the last one opens
   in **Analyze APK**.

Uncheck **Sign the APKs with the key in Sign** to keep Gradle's own
signature: the debug key, or the project's `key.properties`.

### Re-sign an APK you already have

Load a key in **Sign**, press **Sign APK files…** and pick one or more APKs.
Each one is written next to the original as `<name>-signed.apk`, or to the
output folder if you set one.

### Split a universal APK per ABI

When CI hands you one universal APK, press **Split per ABI and sign…** in
**Sign** and pick it. It writes one signed APK per ABI the APK has native
code for, `<name>-<abi>-signed.apk`, next to the original or to the output
folder. Each one keeps everything but the other ABIs' `lib/` folders: for a
`flutter create` sample, the 42.1 MB universal APK gives 14.8 MB for
`arm64-v8a`, 12.1 MB for `armeabi-v7a` and 16.1 MB for `x86_64`.

- An ABI with native code but no Flutter engine gets no APK: it would crash
  at launch. The log says so.
- An APK with native code for one ABI or none is signed as it is.
- The splits keep the universal APK's `versionCode`. That's fine to install
  or to share directly. Google Play needs a different `versionCode` per APK:
  publish an App Bundle there, or build with **Split per ABI** in **Build**,
  which adds an offset per ABI.

### Check an APK

Press **Open APK…** in **Analyze APK**. The checks at the top of the report
say what matters:

- signed with your key, or with the Android debug key;
- release or debug;
- whether the signature verifies;
- architectures without a Flutter engine.

With a key loaded in **Sign**, the report also says whether that keystore
signed the APK.

### Inspect a device and install

Connect a device by USB with USB debugging on, and press refresh. The first
ready device is selected; with several connected, pick one in **Analyze
device**. With an APK selected, **Analyze device** says what installing it
would do. **Install** installs it.

## Security

- **Passwords stay in memory.** They are never written to disk or settings,
  and they're gone when you quit.
- **Passwords never go on a command line.** `apksigner` and `keytool` read
  them from environment variables (`--ks-pass env:…`, `-storepass:env …`),
  so they don't show up in `ps`. Any output line that contains one is masked
  in the log and in error messages.
- **The app saves only paths and choices** (project folder, keystore path,
  key alias, architectures…), in the OS's standard app preferences.
- **Reading a device changes nothing on it.** It runs `getprop`, `wm size`,
  `dumpsys battery` and similar read-only commands. A package name taken from
  an APK is validated before it goes into a device shell command.

## Things worth knowing

- **apksigner and v1.** For an APK with minSdk 24 or higher, `apksigner
  verify` reports `v1: false` even when a v1 signature is there, because
  Android 7+ ignores it. Analyze APK reads the APK's files too, and shows
  "v1 present".
- **v4 signatures** go in a separate `<apk>.idsig` file next to the APK.
  apksigner writes it on its own when its defaults call for it. You only need
  it for `adb install --incremental`.
- **`--target-platform` only filters the Flutter engine.** A plugin's own
  `.so` files can still make the APK advertise an ABI you left out. A device
  that picks that ABI crashes at launch. Analyze APK flags it as "No Flutter
  engine for …". Drop the ABI with `ndk.abiFilters` in Gradle.
- **A 64-bit chip doesn't mean a 64-bit device.** Some devices ship 32-bit
  firmware and only accept `armeabi-v7a`. Analyze device shows the ABIs the
  device actually reports.
- **Obfuscation symbols.** Flutter skips the Dart compile when nothing
  changed, and with it the symbols, so a deleted symbols folder stays empty.
  The log warns about it; `flutter clean` fixes it.
- **R8** (Java/Kotlin shrinking and obfuscation) is your project's Gradle
  setting (`isMinifyEnabled`), not something this app turns on.

## Development

```bash
flutter test                  # unit tests, against recorded tool output
dart analyze lib test tool
dart format .
```

The unit tests never run the real tools. Every parser is tested against real
output captured from `apksigner`, `aapt2`, `keytool`, `adb` and
`flutter build` (see [test/fixtures](test/fixtures/README.md)).

`tool/smoke.dart` runs the real tools end to end against a throwaway
project and keystore: reading the keys, a split and obfuscated build,
signing, analysis, splitting a universal build per ABI and signing the
splits, and a wrong password.

```bash
APK_FORGE_SMOKE_PASS=… dart run tool/smoke.dart <flutter project> <keystore> <alias> <output dir>
```

### Project layout

```
lib/
  core/       process running, host OS, ZIP reading and copying, formatting, log types
  domain/     models, command builders, output parsers, checks (pure Dart)
  services/   one class per tool job, through a ProcessRunner
  state/      Riverpod notifiers: forms, the current task, actions, the log
  ui/         the screen and its panels
tool/         the end-to-end smoke test
test/         unit tests and the captured tool output
```

Dependencies only point down: `ui → state → services → domain → core`. The
rules, including how secrets are handled, are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Contributing

- A new external command gets its arguments from a pure builder in
  `domain/`, with a test.
- A new tool output gets a real captured fixture in `test/fixtures`, never a
  hand-written guess.
- Passwords never go in arguments, logs, settings or errors.
- Before a pull request: `dart format .`, `dart analyze lib test tool` with
  no issues, and `flutter test`.

## License

[MIT](LICENSE) © 2026 Elias Pujols
