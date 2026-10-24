# APK Forge

A desktop app to **build, sign, verify and install Android APKs and App
Bundles** from one screen, instead of remembering the flags of
`flutter build`, `zipalign`, `apksigner`, `jarsigner`, `keytool`,
`bundletool` and `adb`.

APK Forge doesn't reimplement any of them. It drives the official tools you
already have installed, shows the exact command before and while it runs,
and streams every line of output into a log. When something fails you see
the tool's own reason, not a generic error.

![APK Forge: Defaults, Build and Sign on the left; Analyze APK with a signed APK, Analyze device with an emulator, and the log on the right](docs/screenshot.png)

## Features

| Panel | What it does |
|---|---|
| **Defaults** | What Build and Sign share, set once at the top: the architectures (any mix of `armeabi-v7a`, `arm64-v8a` and `x86_64`) and the signature schemes (Auto, or the ones you mark). Build and Sign show what they take from it. It folds into one line. |
| **Build** | Runs `flutter build apk`, or `flutter build appbundle` for a store such as Google Play, on any Flutter project, for the architectures in Defaults. Choose release or debug, and one universal APK, one APK per ABI (`--split-per-abi`, offered with two or more architectures), or an App Bundle (`.aab`). Optional Dart obfuscation keeps the symbols you need to read crash traces. The command is previewed before you run it. |
| **Sign** | Signs the APK selected in Analyze APK, the APKs a build just produced, or any APK you pick (from CI, another machine, a store), with your `.jks`, `.keystore` or `.p12` and the schemes in Defaults. It checks the alignment first and fixes it if needed, writes `<name>-signed.apk` without touching the original, and verifies that the result carries exactly the key you chose. An App Bundle, built or picked, is signed with `jarsigner` to `<name>-signed.aab`, without the debug signature Flutter gave it. **Split per ABI and sign** turns a universal APK (one from CI, say) into one signed APK per architecture in Defaults. **New key…** makes an upload key, a keystore and the `key.properties` Gradle reads, in the folder you choose, and loads it. |
| **Signing profiles** | Saves the steps to turn one APK into a signed APK per device, each with its ABI, its key (a `key.properties` file) and its folder, and runs them in one go. Every run is kept as a report you can copy or export. |
| **Agent access (MCP)** | Lets an agent (any MCP client) list the signing profiles, check a run and run one, through an MCP server inside the app. It's off until you turn it on, it needs a token, it asks you before each run unless you turn that off, and no password leaves the app. |
| **Analyze APK** | For any APK: whether the signature verifies; the schemes it carries (v1 to v4); the signer certificate (DN, SHA-256, SHA-1), a rotated key's lineage, and whether it is **your key** or the Android debug key; release or debug (`debuggable`); package, version and SDK levels; native code per ABI, flagging an ABI with no Flutter engine; size, MD5 and SHA-256. An App Bundle (`.aab`) opens too: its files, its manifest and its JAR signature. **Compare with…** puts an APK next to another APK (a previous release, another build) or the app installed on the device, and lists every difference, worst first: another signer, a lower versionCode, a debug build, lost ABIs, new permissions. |
| **Analyze device** | For the device on USB: maker, brand, model and codename; Android version, API level, security patch, build and build type; chip, ABIs, memory page size (16 KB pages are flagged), RAM, storage and screen; battery, locale and time zone. With an APK selected, it tells you which ABI the APK would run as, which version is installed, and whether installing would be a fresh install, an upgrade, a reinstall or a downgrade, or would be refused for another key. **Compare with the installed app** compares the two side by side. One click copies it all as text. |
| **Install** | Installs the selected APK with `adb install -r` (optionally `-d` to allow a downgrade). It warns first when the APK has no native code for the device, or is signed with another key than the installed app, and explains the common install failures. An App Bundle is installed the way a store delivers it: `bundletool` makes the device's APKs from it, signed with the key in Sign, and installs them. |
| **Log** | Every command and its output, live, with errors and warnings colored. A failed step also shows its reason in a banner above the log, Gradle's "What went wrong" included. **Cancel** stops the running step. |

## Requirements

| Tool | Used by | Where it comes from |
|---|---|---|
| Flutter SDK | Build | [flutter.dev](https://docs.flutter.dev/get-started/install), on your `PATH` or set in Tools |
| Android SDK build-tools: `apksigner`, `zipalign`, `aapt2` | Sign, signing profiles, Analyze APK | Android Studio → SDK Manager |
| Android SDK platform-tools: `adb` | Analyze device, Install, comparing with the installed app | Android Studio → SDK Manager |
| A JDK: `keytool`, `jarsigner`, and `java` for `apksigner` and the bundletool jar | Sign, New key, signing profiles, App Bundles | Android Studio's bundled JDK works |
| `bundletool` | Reading and installing App Bundles | Not in the SDK: the official jar from [github.com/google/bundletool](https://github.com/google/bundletool/releases), or `brew install bundletool` |

You don't configure paths by hand. At startup the app reads your login
shell's environment, the same one your terminal has. An app opened from
Finder or the Dock otherwise gets a bare `PATH`. It then looks at
`ANDROID_HOME`, `ANDROID_SDK_ROOT` and the default SDK folder for each OS,
and picks the newest build-tools.

The pills in the top bar show what was found. The gear opens **Tools**,
which lists every tool and its path, and lets you set:
- the Flutter SDK and Android SDK folders;
- the **build-tools** version, from the ones installed in that SDK (the
  newest by default);
- the **JDK folder**, whose `bin/` has `keytool`, `jarsigner` and `java`;
- **bundletool**: the jar, which runs with that `java`, or the `bundletool`
  command. Without it, `bundletool` is looked for on `PATH` and in
  Homebrew's `bin`.

What you set wins over what's detected. Each one is checked before it
counts:
- an Android SDK folder must have `build-tools` or `platform-tools`;
- Flutter, the JDK's `java` and bundletool must answer with their version.

So a folder that's gone, a version that isn't installed, or a file that
isn't the tool (any file picked as bundletool, say) shows in red with the
reason. That tool counts as missing: nothing else is used in its place.

A macOS JDK bundle (`/Library/Java/JavaVirtualMachines/….jdk`) works as the
JDK folder. Tools checks what's in its fields as you pick them; **Detect
again** checks what you typed, **Save** keeps it, and **Close** throws it
away.

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

`main` holds the released versions, each tagged (`v1.1.0`), and `develop`
the work in progress. What changed in each version is in
[CHANGELOG.md](CHANGELOG.md).

## Using it

### Build and sign a Flutter app

1. **Defaults:** choose the architectures, and the signature schemes if
   you don't want apksigner to pick them. Fold the card once they're set.
2. **Build:** choose the project folder, release or debug, and the output
   (universal, split per ABI, or App Bundle). Turn on obfuscation if you
   want it.
3. **Sign:** choose your keystore, enter its password, press **Load keys**
   and pick the key. The panel shows the key's owner and SHA-256, so you can
   confirm it's the right one before signing.
4. Press **Build and sign**. The build output streams into the log. Every
   APK the build produced is then signed and verified, and the last one opens
   in **Analyze APK**.

Uncheck **Sign the APKs with the key in Sign** to keep Gradle's own
signature: the debug key, or the project's `key.properties`.

**App Bundle** builds the `.aab` that stores take, Google Play among them
(it requires one for a new app). The store makes and signs the APK for each
device from it, so it isn't split per ABI here.
With signing on, the bundle is signed with the key in Sign:
- with `jarsigner`, because `apksigner` can't read a bundle;
- after removing the debug signature Flutter gave it. Signed on top of it,
  a bundle keeps both signers, or no longer verifies;
- then checked: it must verify and carry only your key's SHA-256.

The signed bundle is `<name>-signed.aab`, next to the one Flutter wrote or
in Sign's output folder. `jarsigner` warns in the log that the certificate
is self-signed and the signature has no timestamp. That's normal for an
upload key. The signed bundle joins the list in **Analyze APK**, ready to
check and install.

### Re-sign an APK you already have

Open the APK in **Analyze APK**, load a key in **Sign** and press
**Sign `<name>`**: Sign works on the APK selected in Analyze APK. **Sign
other APK or AAB files…** picks one or more APKs or App Bundles instead,
such as a bundle from CI. Each one is written next to the original as
`<name>-signed.apk` or `<name>-signed.aab`, or to the output folder if you
set one.

### Make a new upload key

To publish a new app you need an upload key. **New key…** at the top of
**Sign** makes one:

1. Choose a folder (**Create folder** makes it) and the keystore's file
   name, `upload-keystore.jks` by default.
2. Choose the alias (`upload` by default) and the type:
   - **PKCS12**, keytool's default and what Flutter's signing guide makes:
     one password for the keystore and its key;
   - **JKS**, when the key needs a password of its own.
3. Enter the password twice. keytool needs at least 6 characters.
4. Fill in the certificate: your name or your company's, the country code,
   and the rest if you want. The key is valid for 25 years by default.
   Google Play needs one valid past 22 October 2033.
5. Press **Create key**. It writes the keystore and a `key.properties` next
   to it, with the fields Flutter's guide uses and the keystore's full path.
   **Sign** then has the key loaded, ready to sign, and the log shows its
   SHA-1 and SHA-256, which Firebase and Google's APIs ask for.

To build with it, copy `key.properties` into the project's `android/`
folder, or point a signing profile's target at it.

Nothing is overwritten: a keystore or `key.properties` already in the
folder stops it, because keytool would add the key to the existing
keystore. `key.properties` holds the passwords in plain text, as Gradle
reads them, so only you can read it. Back up both files together: without
them you can't sign updates with this key. And keep them out of git.

### Split a universal APK per ABI

When CI hands you one universal APK, open it in **Analyze APK** and press
**Split `<name>` per ABI and sign** in **Sign**. It writes one signed APK per
architecture in Defaults, `<name>-<abi>-signed.apk`, next to the original or
to the output folder; the caption under the button says which ones before
you press it. Each one keeps everything but the other ABIs' `lib/` folders: for a
`flutter create` sample, the 42.1 MB universal APK gives 14.8 MB for
`arm64-v8a`, 12.1 MB for `armeabi-v7a` and 16.1 MB for `x86_64`.

- An architecture in Defaults that the APK has no native code for gets no
  APK, and one the APK has but Defaults doesn't is left out. The log says
  so.
- An ABI with native code but no Flutter engine gets no APK: it would crash
  at launch. The log says so.
- An APK with native code for one ABI or none is signed as it is.
- The splits keep the universal APK's `versionCode`. That's fine to install
  or to share directly. Google Play needs a different `versionCode` per APK:
  publish an App Bundle there, or build with **Split per ABI** in **Build**,
  which adds an offset per ABI.

### Signing profiles

When one APK has to go out signed for several devices, each with its own
ABI, key or folder, a profile saves those steps and runs them in one go.
Open **Profiles** in the left rail, or **Run profile…** in **Sign**.

- **A profile** holds:
  - an input check: the package the APK must be, and whether it must be
    unsigned;
  - its targets;
  - a file name pattern;
  - what to do after a run: open the output folders, or nothing.
- **A target** is one APK the profile writes, usually one per device. It
  has:
  - a name;
  - an ABI, or universal;
  - a key;
  - the signature schemes: its own, or the ones in Defaults when the
    profile runs;
  - an output folder.
- **A key** is a Gradle `key.properties` file, like a Flutter project's
  `android/key.properties`:

  ```properties
  storePassword=…
  keyPassword=…
  keyAlias=upload
  storeFile=upload-keystore.jks
  ```

  `storeFile` can be relative to the file. The profile saves only the
  file's path. **Edit target** shows what the file says (the keystore, the
  alias, whether both passwords are there) without showing the passwords.

**Create one.** Press **New profile**, then fill its steps:
1. **Input**: the input checks.
2. **Targets**: **Add target** for each one.
3. **File name**: the tokens are `{name}`, `{target}`, `{abi}`,
   `{versionName}`, `{versionCode}` and `{date}`, with a preview.
4. **After**: what to do once the run is done.

Targets with the same ABI, key and schemes are signed once and copied to
each folder. **Duplicate** copies a profile ("Release copy"). A name
already in the list gets a number ("New profile 2").

**Run it.** **Run…** opens the run dialog. Add the APK, or use the one
selected in **Analyze APK**. Before anything is signed, the dialog:
- reads the APK and checks it against the input checks;
- opens every key. A wrong keystore or key password, or an alias the
  keystore doesn't have, stops the run here and names the file;
- shows the plan: each target's ABI, key and the file it writes, and which
  targets are skipped and why (no native code for their ABI, say).

Press **Run**. Each target is cut to its ABI from a universal APK, signed,
verified against its key and written. The input is never modified, and a
target that fails doesn't stop the others. The signed APKs join the list in
**Analyze APK**.

**The history.** The **History** tab keeps every run, newest first, with
its outcome, versions and targets. A run's report says, for each target:
- the ABI, and whether the input was cut;
- the key: its alias and its `key.properties`;
- the schemes asked, next to the ones apksigner verified;
- the signer;
- the output, with its size and SHA-256, or why the target failed or was
  skipped.

**Copy as text** and **Export…** give the same report as text, for a
release note or a ticket. Editing the profile later doesn't change its
history; deleting the profile deletes it. A run saved by an older version
says "Not recorded" for what that version didn't keep.

**Share one.** **Export…** writes the profile to a `.json` file, with
paths and choices only. **Import profile…** reads one, and a name already
in the list gets a number. The paths come from the machine that exported
it:
- A `key.properties` or output folder that doesn't exist on this machine is
  flagged in the import dialog, in the Profiles list and on the target.
- It stops the run until you pick another file or folder in **Edit
  target**. For a folder, **Create folder** creates it.

**No password is saved.** The passwords stay in each `key.properties`:
- they're read when the run dialog opens the keys, and kept in memory only
  while the dialog is open;
- they go to `keytool` and `apksigner` through environment variables;
- they're never written to the settings, the history, an exported profile,
  the log or an error.

### Let an agent run a profile (MCP)

An agent can run a signing profile for you: "run the Universal profile on
build/app/outputs/flutter-apk/app-release.apk". Any agent works, with any
model, as long as its client speaks [MCP](https://modelcontextprotocol.io)
over HTTP. APK Forge has the MCP server inside the app. A run goes through
the Run dialog's check, shows in the log while it runs, and is kept in the
profile's History.

**Turn it on.** Press the robot in the top bar (**Agent access**) and turn
on **MCP server**:
- it listens on `127.0.0.1:7740`, on this computer only. You can change the
  port there;
- it makes a token the first time;
- a green **MCP** pill in the top bar says it's on;
- it comes back on at every launch until you turn it off.

**Ask before an agent runs a profile** is on unless you turn it off:
- On: once a run's check passes, APK Forge shows the plan (each target's
  ABI, key and the file it writes, and what's skipped) with **Allow** and
  **Decline**. The agent waits for your answer. **Decline** signs nothing,
  and the agent is told so.
- Off: a run starts as soon as its check passes.

The app asks, not the agent's client, so it works the same with any agent.

**Connect an agent.** In your agent's MCP settings, add an HTTP server
(Streamable HTTP) with:
- the **Address**, `http://127.0.0.1:7740/mcp`;
- the **Authorization** header, `Bearer <token>`.

Agent access has a copy button for each; the header's copy holds the token.
How you add a server depends on the client. With Claude Code, for example,
run this once in a terminal:

```bash
claude mcp add --scope user --transport http apk-forge http://127.0.0.1:7740/mcp --header "Authorization: Bearer <token>"
```

`--scope user` makes it available in every project, and `claude mcp list`
shows it connected while the app is open.

**See who's connected.** Agent access lists each agent connected since the
server started: its name and version, as its client gives them, when it
connected, and its last request and tool. It shows the three most recent;
**Show all** shows the rest. The log says when an agent
connects and disconnects. An agent that quits without disconnecting stays
listed, with the time of its last request, until the server stops. One
that connected before APK Forge restarted keeps working, and shows as such
until it connects again.

**The tools:**

| Tool | What it does | Writes? |
|---|---|---|
| `list_profiles` | Each profile: its targets (ABI, key and alias, folder, schemes), its input checks, its file name pattern, and what stops a target on this machine. | No |
| `check_profile_run` | The Run dialog's check, for a profile and some APKs: reads them, plans the run and opens the keys. | No |
| `run_profile` | Checks, then runs. Returns each target's result (status, output, size, signer SHA-256, or the reason) and the run's report. | The signed APKs, in each target's folder |
| `list_runs` | A profile's History, newest first. | No |

- A profile is named as in the app, ignoring case.
- The APKs are absolute paths, and the agent must give them. It never signs
  whatever APK is selected in **Analyze APK**.
- `run_profile` is refused while another task runs (a build, an install),
  while another agent's run waits for **Allow**, and when the check finds
  a problem. The answer says why.

**It does nothing else:** no build, no install, no change to a profile.
Passwords never leave the app: they're in no tool's answer, error, log line
or History entry.

**New token** replaces the token: give your agent the new header.
Turning the server off, changing its port or making a new token cuts the
open connections, ends the agents' sessions and declines a run waiting for
**Allow**. A run already started still finishes in the app.

### Check an APK

Press **Open APK…** in **Analyze APK**. The checks at the top of the report
say what matters:

- signed with your key, or with the Android debug key;
- release or debug;
- whether the signature verifies;
- architectures without a Flutter engine.

With a key loaded in **Sign**, the report also says whether that keystore
signed the APK.

**Open APK…** opens an App Bundle (`.aab`) too.
- **What's read in Dart:** its files, ABIs and hashes.
- **The signature:** read with `jarsigner`, and shown as a JAR signature,
  since the store signs the APKs it makes.
- **The manifest** (package, version, SDK levels, permissions): read with
  **bundletool**, set in Tools. Without bundletool the report shows the rest
  and says the manifest needs it.

**Compare** reads APKs only.

### Compare two APKs

Select an APK in **Analyze APK** and press **Compare with…**. Pick the
reference: another APK of the session, a file (a previous release), or the
app installed on the selected device. The selected APK is compared as an
update over the reference:

- **The signer.** It is the same signer, a **rotated key** (APK Signature
  Scheme v3: Android still accepts the update), or a different signer, with
  both SHA-256 digests.
- **Whether it installs as an update.** If it doesn't, the comparison says
  why: another package, another signer, a lower versionCode, or a signature
  that doesn't verify.
- **Every difference, worst first,** each with why it matters: the
  signature, the manifest (versions, SDK levels, debuggable, permissions
  added and removed), the native code per ABI and the Flutter build, and the
  file. The values that are the same are folded.

A part that couldn't be read in either APK (a missing tool, a file that
isn't an APK) is listed as not compared, never as a difference. **Swap**
turns the comparison around.

### Inspect a device and install

Connect a device by USB with USB debugging on, and press refresh. The first
ready device is selected; with several connected, pick one in **Analyze
device**. With an APK selected, **Analyze device** says what installing it
would do. **Install** installs it.

When the APK's app is already installed, **Install** warns before an
install Android would refuse because the APK is signed with another key.

**Install** also installs an App Bundle the way a store delivers one, so you
can try it before you send it:
- **bundletool** makes the APKs for that device from the bundle, signed with
  the key in **Sign**, and installs them;
- it needs bundletool set in Tools and a key loaded in Sign, and Install
  says when either is missing;
- the keystore password goes to bundletool in a file only you can read, and
  that file and the device's APKs are deleted as soon as it's done.

If the store signs your app with its own key (Google Play's app signing), a
build installed this way and one from the store can't update each other:
uninstall one first.

**Compare with the installed app** shows everything that differs. For that,
the installed APK is copied to a temporary folder, read and deleted. An app
installed from Play comes as a `base.apk` plus splits; the base and the ABI
splits are compared, and the density and language splits stay on the
device. Its size is of those files together. It isn't one file, so it has
no MD5 or SHA-256 to compare, and it's never "the same file" as an APK.

## Security

- **Passwords stay in memory.** They are never written to settings, and
  they're gone when you quit. Two files hold one, and only you can read
  them:
  - the `key.properties` that **New key** writes because you asked for it,
    which is never overwritten;
  - while an App Bundle installs, the temporary file bundletool reads it
    from, deleted as soon as the install ends.
- **Passwords never go on a command line.** `apksigner`, `jarsigner` and
  `keytool` read them from environment variables (`--ks-pass env:…`,
  `-storepass:env …`). `bundletool`, which can't, reads them from a
  temporary file only you can read, deleted right after. So they don't
  show up in `ps`. Any output line that contains one is masked
  in the log and in error messages.
- **The app saves only paths and choices** (project folder, keystore path,
  key alias, architectures…), in the OS's standard app preferences. A
  signing profile saves the path of each `key.properties`; the passwords
  stay in the file. The one secret saved there is the MCP server's token
  (below).
- **The MCP server is off until you turn it on**, and listens on
  `127.0.0.1` only:
  - every request needs its token. It's saved with the preferences, so the
    registered command keeps working, and **New token** replaces it;
  - a request from a web page (an `Origin` other than the server's own) is
    refused, token or not;
  - **Ask before an agent runs a profile** (on unless you turn it off)
    makes every run wait for your **Allow**, whatever the agent was told;
  - no tool answers with a password, and the token never goes to the log.
    Don't paste the copied header in an issue or a screenshot: **New
    token** replaces one that got out.
- **Reading a device changes nothing on it.** It runs `getprop`, `wm size`,
  `dumpsys battery`, `pm path` and similar read-only commands. A package name
  taken from an APK is validated before it goes into a device shell command.
  To compare with an installed app, `adb pull` copies its APK files to a
  temporary folder, which is deleted once they are read.

## Things worth knowing

- **apksigner and v1.** For an APK with minSdk 24 or higher, `apksigner
  verify` reports `v1: false` even when a v1 signature is there, because
  Android 7+ ignores it. Analyze APK, Compare and a profile run's History
  read the APK's files too, and show "v1 present".
- **A rotated signing key.** With APK Signature Scheme v3 an app can move
  to a new key and still update over installs signed with the old one.
  `apksigner verify` shows only the new key, so on its own a rotated key
  looks like another key. Analyze APK also runs `apksigner lineage` for a v3
  signature, and Compare calls it "Key rotated". With v3.1 (API 33+), the
  report lists one signer per API range.
- **v4 signatures** go in a separate `<apk>.idsig` file next to the APK.
  apksigner writes it on its own when its defaults call for it. You only need
  it for `adb install --incremental`. `apksigner verify` checks v4 only when
  it's given that file, so Sign, a profile run and Analyze APK pass the one
  next to the APK. Without one (an app copied from a device has none), v4
  shows as not checked, not as missing. An `.idsig` that doesn't match the
  APK still verifies with v4 false, and apksigner gives no reason: Analyze
  APK says the `.idsig` doesn't match. A corrupt one stops apksigner, so
  Analyze APK reads the rest of the signature without it and says why.
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
output captured from `apksigner`, `jarsigner`, `aapt2`, `keytool`, `adb`,
`bundletool`, `java` and `flutter` (see
[test/fixtures](test/fixtures/README.md)).

`tool/smoke.dart` runs the real tools end to end against a throwaway
project and keystore: reading the keys, a split and obfuscated build,
signing, analysis, splitting a universal build per ABI and signing the
splits, a signing profile with two targets and two throwaway keys of its
own (one with a key password of its own), a wrong password, an App Bundle
built and signed, and a new key of each type made as **New key** makes
them. It makes and deletes its own keys itself.

```bash
APK_FORGE_SMOKE_PASS=… dart run tool/smoke.dart <flutter project> <keystore> <alias> <output dir>
```

With `APK_FORGE_SMOKE_BUNDLETOOL` set to a bundletool jar, it also reads the
signed App Bundle's manifest.

The app icon is the logo in the window's header (`lib/ui/app_logo.dart`) on
the dark theme. After a change to either, draw it again; it writes macOS's
sizes:

```bash
flutter test tool/app_icon.dart
```

### Project layout

```
lib/
  core/       process running, host OS, ZIP reading and copying, file digests, formatting, log types
  domain/     models, command builders, output parsers, checks, the MCP protocol (pure Dart)
  services/   one class per tool job, through a ProcessRunner; the MCP server's HTTP listener
  state/      Riverpod notifiers (forms, the current task, the log, the MCP server), the actions and the MCP tools
  ui/         the screen and its panels
tool/         the end-to-end smoke test, and the app icon's drawing
test/         unit tests and the captured tool output
```

Dependencies only point down: `ui → state → services → domain → core`. The
rules, including how secrets are handled, are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and how the code is tested in
[docs/TESTING.md](docs/TESTING.md).

### Contributing

- A new external command gets its arguments from a pure builder in
  `domain/`, with a test.
- A new tool output gets a real captured fixture in `test/fixtures`, never a
  hand-written guess.
- Passwords never go in arguments, logs, settings or errors.
- Before a pull request: `dart format .`, `dart analyze lib test tool` with
  no issues, and `flutter test`. Check the change against ARCHITECTURE's
  "Every change" list.

### Releasing

A version, 1.1.0 say, goes from `develop` to `main` like this:

1. A `release/1.1.0` branch from `develop` adds the version's section to
   [CHANGELOG.md](CHANGELOG.md), from the issues and pull requests merged
   since the last version, and sets `version: 1.1.0+<build>` in
   `pubspec.yaml`. The build number goes up by one with each version.
2. A pull request from it to `main` says what the version brings. Merge it
   with a merge commit, not squashed or rebased, so `main` keeps
   `develop`'s commits.
3. Tag the merge commit `v1.1.0`, and publish a GitHub release with the
   version's section of the changelog as its notes.
4. Merge `main` back into `develop`, so the next version starts from the
   changelog and the version number.

## License

[MIT](LICENSE) © 2026 Elias Pujols

APK Forge's logo and app icon are the Android robot, drawn with the
`android_rounded` glyph of Google's Material Icons, which ships with Flutter
under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
The Android robot is reproduced or modified from work created and shared by
Google and used according to terms described in the
[Creative Commons 3.0 Attribution License](https://creativecommons.org/licenses/by/3.0/).
