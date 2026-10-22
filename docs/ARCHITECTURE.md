# Architecture

APK Forge is one screen over the external tools: `flutter`, `apksigner`,
`zipalign`, `aapt2`, `keytool`, `jarsigner`, `java`, `bundletool` and `adb`.
The design goal is that everything that decides something (which command
to run, what a tool's output means, what to warn about) is plain Dart that a
test can drive without the tools, and that the code which actually starts
the tools is thin.

## 1. Layers

```
lib/
  core/       Process running, the host OS, ZIP reading and copying, file digests,
              formatting, log types.
  domain/     Models, command builders, output parsers, findings. Pure.
  services/   One class per tool job; runs commands through a ProcessRunner.
  state/      Riverpod notifiers (forms, the current task, the log) and the
              actions the buttons run (state/actions/).
  ui/         The screen and its panels.
  main.dart   Loads the shell environment and settings, starts the app.
tool/
  smoke.dart     The services against the real tools (see README).
  app_icon.dart  Draws the app icon from the header's logo (see README).
```

**Dependencies only point down:** `ui → state → services → domain → core`.

- `domain/` and `core/` never import Flutter or Riverpod.
- `services/` never import `state/` or `ui/`.
- Only `state/` and `ui/` import Riverpod; only `ui/` imports Flutter widgets.

A layer folder is split by area (`build/`, `signing/`, `analysis/`,
`devices/`, `tools/`), not the other way round: the app is small and its
steps are tightly sequenced (build → sign → analyze → install), so the
actions in `state/actions/` composing the services read better than four
features calling each other.

## 2. The process boundary

- **Every external program starts through `ProcessRunner.run`**
  (`core/process/process_runner.dart`). `IoProcessRunner` is the only class
  that calls `Process.start`.
- **A tool's input is closed as soon as it starts.** None of them needs
  any, and one that asks for something (apksigner, for a key password it
  wasn't given) fails at once instead of waiting forever.
- **It never throws for a tool that fails or can't start.** That comes back
  as a `CommandResult` with a non-zero exit code (127 when it couldn't
  start), so every failure reaches the log the same way.
- **`ToolExecutor`** (`services/tool_executor.dart`) wraps a runner for one
  task: it logs the command line, streams the output to the log with the
  secrets masked, and carries the task's `CancelToken`.
- **Services throw `ToolFailure`** (`domain/failure.dart`) with a title and
  the tool lines that explain it. `errorDetails` picks those lines: Gradle's
  "What went wrong" block, else the error-looking lines, else the tail.

## 3. Secrets

Passwords come from three places: what you type in Sign, what you type
in New key, and the `key.properties` files a signing profile points to
(§7).

- Typed passwords live only in memory: in `SigningForm`, in the
  `SigningRequest` built from it for a task (`ReadyToSign`), and in
  `Command.environment`.
- A profile holds a `key.properties` path, never what's in it.
  - The file is read when a run's check opens the keys
    (`ProfileKeyService.open`). Its passwords then live in that check's
    `OpenedKey`s (`ProfileRunCheck.keys`), only while the Run dialog is
    open, and in the `SigningRequest`s and commands of the run.
  - The target editor reads the file too (`KeyFileSummary`), but keeps
    only whether each password is there.
- They are passed to tools through environment variables, never arguments:
  - `APK_FORGE_KS_PASS` holds the keystore password, and `APK_FORGE_KEY_PASS`
    holds a key password of its own;
  - for example `apksigner --ks-pass env:APK_FORGE_KS_PASS --key-pass
    env:APK_FORGE_KEY_PASS`, and `keytool` and `jarsigner -storepass:env …
    -keypass:env …`.
- `Command.secrets` lists them; the log and `ToolFailure.fromResult` mask
  them. `KeyProperties` and `OpenedKey` leave them out of `toString`.
- `SettingsStore` receives explicit maps without them: the forms, the
  profiles and the history.
- An exported profile is the profile's JSON, so it holds paths and choices
  only.
- A profile run's record (§7) keeps a key's alias and its `key.properties`
  path, never what's in the file.
- New key (§7) writes the only file that keeps a password: the
  `key.properties` you ask for, next to the new keystore.
  - The sheet keeps the passwords in its `NewKeyForm` while it's open, and
    the task in its `NewKeyRequest`. Both leave them out of `toString`.
  - `NewKeyService` creates the file empty, makes it its owner's only
    (`chmod 600`), and only then writes it (`writeOwnerOnly`). It never
    overwrites one. On Windows, which has no file modes, the file takes the
    folder's permissions.
- bundletool takes a password as an argument or a file only, so installing
  a bundle (§7) writes the keystore and key passwords to files with
  `writeOwnerOnly`, in a temporary folder. bundletool gets their paths
  (`--ks-pass=file:…`), and the folder is deleted when the install ends,
  failed or cancelled.

A test covers each of these. Keep it that way when a new tool takes a secret.

## 4. Tools and the host

- `Host` (`core/system/host.dart`) is the OS and the environment as values.
  Code that depends on them takes a `Host`, so tests can describe Windows
  while running on a Mac.
- `FileProbe` answers "does this exist?" for `ToolchainLocator`, which finds
  the tools from what Tools sets (`ToolOverrides`), then `ANDROID_HOME`,
  `ANDROID_SDK_ROOT`, the default SDK folders, `JAVA_HOME` and `PATH`.
  - Tools can set the Flutter SDK, the Android SDK, a build-tools version
    (`Toolchain.availableBuildTools` lists the installed ones), a JDK folder
    and bundletool.
  - Something set that can't be used is a `Toolchain.problems` entry, and
    its tool stays missing: the locator never falls back to another one.
    With an Android SDK set, adb comes from that SDK only.
  - A file existing doesn't make it the tool. An Android SDK folder must
    have `build-tools` or `platform-tools`. Each tool that's run is asked
    its version (`Toolchain.withVersions`): Flutter by `flutter --version`,
    the JDK by `java -version`, bundletool by `bundletool version`. One that
    gives none is dropped with the reason. The Tools dialog shows this for
    what's in its fields, before Save (`toolchainPreviewProvider`).
  - A macOS JDK bundle (`….jdk`) works as a JDK folder: its tools are in
    `Contents/Home/bin`.
  - `jarsigner` and `java` come from `keytool`'s folder. A bundletool jar
    runs with that `java` (`Toolchain.bundletoolLaunch`). Without one set,
    bundletool is looked for on `PATH`, then in Homebrew's `bin`, since an
    app opened from Finder may not have it on `PATH`.
- `loadShellEnvironment` reads the login shell's environment once at
  startup. Every process starts with it, because an app opened from Finder
  has a bare `PATH`.

## 5. State

- **One task at a time.** `TaskNotifier.run` refuses to start a second one,
  holds the cancel token, and turns a `ToolFailure` into the error banner.
  Builds, signings, profile runs, key loading, new keys and installs go
  through it. Listing devices, analyzing an APK and reading an installed app
  don't: they change nothing.
- **Actions** (`state/actions/`) are plain classes, one per job: build, sign,
  split and sign, run a profile, load keys, make a new key, create a folder,
  install. Each takes what it uses in its constructor: the services, a
  `TaskRunner`, an `ApkSink` for the APKs it writes, and functions that read
  the forms when the button is pressed (`SigningSetup` says what Sign signs
  with, or why it can't). Their providers are where that's wired; no action
  receives `ref`.
- **Forms** (`state/forms.dart`) persist their non-secret fields through
  `SettingsStore` on every change. What Build and Sign share, the
  architectures and the signature schemes, lives once in `defaultsProvider`:
  `BuildOptions.abis` follows it, and Sign passes its schemes to
  `SigningForm.toRequest`. `migrateSettings` runs in `main()` before
  anything reads the settings, and moves what older versions saved in Build
  and Sign there.
- **The log** (`state/log_notifier.dart`) is an append-only list with a
  revision number, capped at 5000 lines, so output doesn't copy the whole
  list per line.
- **Analysis** is a `FutureProvider.family` per APK path. Adding a path to
  the list again invalidates it (the file may have been re-signed).
- **Riverpod forbids writing to another provider during a provider's
  synchronous build.** A provider that logs does it after its first `await`.
- `ProviderScope(retry: …)` turns off automatic retries: a failed analysis
  must not run the tools again on its own.

## 6. Reading a device

- **One `adb shell` call per device** (`deviceInfoScript`): `getprop` and a
  few commands (`wm size`, `getconf PAGE_SIZE`, `df -k /data`,
  `dumpsys battery`…), each after an `__APK_FORGE__:<section>` marker.
  `parseDeviceInfo` splits the sections. A command the device lacks leaves
  its section empty instead of failing the read.
- **The device shell runs strings.** Anything from outside that goes into
  one must be validated first: a package name read from an APK passes
  `isValidPackageName` before `installedPackageScript` uses it.
- `deviceInfoProvider` and `installedPackageProvider` cache per serial (and
  package) until the device list is refreshed. A successful install also
  forgets what was read about the installed apps (`InstallAction`'s
  `onInstalled`), so the panels show the version just installed. The
  Install and Device panels
  share one selected device (`installOptionsProvider.selectedSerial`); a
  refresh keeps it while it's listed, else selects the first ready device.
- **An installed app is read like any APK** (`InstalledApkService`):
  1. `pm path` lists its files (`adbPackagePathArguments` validates the
     package name);
  2. `adb pull` copies `base.apk` and its ABI splits to a temporary folder
     (`InstalledApkFiles` picks them; density and language splits are
     resources only, so they stay on the device);
  3. `ApkAnalyzer` reads `base.apk`, and `installedContents` adds the native
     code of the splits;
  4. the folder is deleted, even on a failure.

  A `base.apk` that can't be copied fails; a split that can't leaves the
  native code unread, with the reason. `installedApkProvider` caches the
  result per serial and package until a refresh or an install.

## 7. Signing

`ApkSigningService.sign`:

1. `zipalign -c` (with `-P 16` on build-tools 35+). If it fails, an aligned
   copy is written to a temporary folder first.
2. `apksigner sign` writes `<name>-signed.apk.partial`.
3. `apksigner verify` must say it verifies, with the selected key's SHA-256.
   When v4 signing wrote an `.idsig`, verify is given it
   (`--v4-signature-file`): apksigner doesn't check v4 without it.
4. Only then is the `.partial` (and its `.idsig`) renamed over
   `<name>-signed.apk`. On any failure the `.partial` files are deleted, and
   an earlier signed APK stays as it was.

The input is never modified or overwritten (`signedFilePath`).

### A new key

**New key…** in Sign (`ui/signing/new_key_sheet.dart`) makes an upload key.

1. `newKeyProblems` (`domain/signing/new_key.dart`) checks the form field
   by field, through `FileProbe`:
   - the folder exists;
   - neither the keystore nor `key.properties` is there, because keytool
     would add the key to an existing keystore without a word;
   - the passwords have 6 characters or more and match;
   - a certificate field is filled in;
   - the key is valid past 22 October 2033, as Google Play needs.

   The sheet shows a field's problem once it's edited, and `NewKeyAction`
   checks again before anything runs.
2. `NewKeyService` runs `keytool -genkeypair` (`keytoolGenerateKeyArguments`:
   RSA 2048, the keystore type, `-validity` in days from `validityDays`, and
   the `-dname` escaped by `escapeDistinguishedNameValue`).
3. It then writes `key.properties` (§3) with `formatKeyProperties`, which
   `parseKeyProperties` reads back. `storeFile` is the keystore's absolute
   path, because Gradle resolves a relative one from `android/app/`. A
   failure after keytool deletes both files.
4. `NewKeyAction` reads the new keystore with `keytool -list`, loads it in
   Sign (`SigningFormNotifier.useKey`), and logs both paths and the key's
   SHA-1 and SHA-256.

### An App Bundle

`apksigner` can't read an App Bundle (`ApkFormatException: Missing
AndroidManifest.xml`): a bundle carries a JAR signature only, made with
`jarsigner`. `ToolchainLocator` finds `jarsigner` next to `keytool`, in the
same JDK. `ApkBatchSigner` sends a `.aab` to `BundleSigningService.sign`,
from Build or from Sign's file picker:

1. `copyZipEntries` writes a temporary copy without the JAR signature
   (`isJarSignatureFile`). Flutter signs its bundle with the debug key, and
   `jarsigner` signing on top of it keeps that signer, or breaks the bundle,
   depending on the digest.
2. `jarsigner` signs the copy to `<name>-signed.aab.partial`
   (`jarsignerSignArguments`, the passwords in the environment). A key that
   doesn't open is named by `parseKeyLoadFailure`, as for an APK.
3. `jarsigner -verify` must say `jar verified.` (`parseJarsignerVerify`).
   `keytool -printcert -jarfile` must list one signer
   (`parseJarSigners`), with the selected key's SHA-256.
4. Only then is the `.partial` renamed to `<name>-signed.aab`
   (`signedFilePath`). The temporary copy is deleted, even on a failure.

A bundle isn't zipaligned: the store aligns the APKs it makes from it. A
signed bundle joins the APK list like a signed APK.

`ApkAnalyzer` reads a bundle as well:
- its files with `ApkContents.fromBundleEntries`, each module's `lib/` and
  `assets/` read as an APK's;
- its manifest with `bundletool dump manifest` (`parseBundleManifest`);
- its JAR signature with `jarsigner -verify` and `keytool -printcert`
  (`bundleSignatureReport`).

The report shows a JAR signature instead of the v1 to v4 schemes, and
Compare stays off for bundles.

`BundleInstallService` installs a bundle as a store would deliver it. It
writes the passwords' files (§3) and runs `bundletool build-apks
--connected-device`, which makes the device's APKs signed with the key in
Sign. Then `install-apks` installs them. `parseInstallFailure` reads
Android's refusal from bundletool as from adb, and `parseKeyLoadFailure`
reads bundletool's password errors. The temporary folder, password files
and device APKs included, is deleted even when it fails.

### Splitting a universal APK per ABI

`ApkSplitService.withSplits` needs no tool, only the ZIP itself:

1. `planAbiSplit` (`domain/signing/abi_split.dart`) picks one APK per
   `lib/<abi>/` folder, leaving out a Flutter app's ABIs that have no engine.
2. `copyZipEntries` (`core/zip`) writes each split to a temporary folder,
   keeping the entries `keepsEntryForAbi` accepts: everything but the other
   ABIs and the v1 signature files. Kept entries are copied as stored,
   never recompressed, so uncompressed `.so` files stay uncompressed. The
   APK Signing Block isn't copied.
3. Each split is signed as above. `zipalign` realigns it, because removing
   entries moves the others. The signed APK goes next to the universal one
   (`SigningRequest.withDefaultOutputDir`), and the temporary folder is
   deleted even when signing fails.

The splits keep the universal APK's manifest, `versionCode` included:
changing it would mean rewriting the binary manifest.

### Signing profiles

A profile (`SigningProfile`, `domain/profiles/profile.dart`) saves the
steps to turn one APK into a signed APK per device. It holds:
- what the input must be (`InputChecks`);
- the targets, each with its ABI, its `key.properties`, its schemes (or
  Defaults') and its output folder;
- a file name pattern;
- what to do after the run.

A run goes through three steps, each in its layer:

1. **The plan** (`planProfileRun`, `domain/profiles/profile_plan.dart`) is
   pure, made from the inputs' reports.
   - It lists what stops the run: an input that fails the checks, a
     target's problems, or two targets that would write the same file.
     A target's problems come from `targetProblems` (§10), such as a
     `key.properties` or folder missing on this machine, through
     `FileProbe`.
   - It skips a target the input has no native code or Flutter engine
     for.
   - It groups the targets that share the input, the ABI, the key and the
     schemes into one `SignJob`: signed once, then copied to each folder.
2. **The check** (`profileRunCheckProvider`, `state/profiles.dart`) runs
   while the Run dialog is open.
   - It reads the inputs (`ApkAnalyzer`) and makes the plan.
   - Only when the plan has no problem, it opens the keys the jobs use
     (`ProfileKeyService`, `services/profile_runner.dart`): `keytool -list`
     checks the keystore password and the alias, then `keytool -certreq`
     checks the key password, which `-list` doesn't.
   - A key that doesn't open stops the run before anything is signed.
3. **The run** (`ProfileRunAction`, `state/actions/profile_run_action.dart`)
   is one task, through `ProfileRunner` (`services/profile_runner.dart`).
   - Each job cuts the input to its ABI with `copyZipEntries`, as a split
     does.
   - It signs the cut APK with `ApkSigningService` (aligned, signed, then
     verified against the key's SHA-256).
   - It copies the signed APK to each target's folder through a `.partial`
     file.
   - A failed job doesn't stop the others, and cancelling skips what
     hasn't run.
   - The progress goes to `ProfileRunProgress`, and each signed APK to the
     APK list.

`exportProfile` and `importProfile` write and read a profile as JSON. An
imported profile whose name is taken gets a number ("Release 2"). Its
targets' problems show at once, because its paths may not exist on this
machine.

#### A run's record

`ProfileRunner` returns one `TargetResult` per target and input. Each one
keeps:
- how it was signed (`TargetSetup`): the ABI and whether the input was cut,
  the key's alias and `key.properties`, the schemes asked and whether they
  came from Defaults, and the target it shares a signing with;
- what `apksigner verify` said of each scheme;
- whether the APK carries a JAR signature, read from its files, since
  apksigner skips v1 from minSdk 24;
- the signer and the output's SHA-256.

`ProfileRunAction` adds the inputs, the file name pattern, the input
checks and the build-tools version, and saves the record.

The record is the only account of a run: the profile can change or go
after it. `runReport` (`domain/profiles/run_report.dart`) turns it into
the report the History tab shows, and `runReportText` into the text Copy
and Export write. A record saved before a field existed loads with it
`null`, and the report says "Not recorded" rather than reading today's
profile.

## 8. Comparing APKs

`compareApks` (`domain/analysis/comparison.dart`) is pure, over two
`ApkReport`s: the reference (a previous release, the installed app) and the
candidate, compared as an update over it.

- **Signers.** The same set of certificates by SHA-256 is the same signer:
  Android's rule for an update. Otherwise, if every reference certificate is
  in the candidate's v3 lineage or among its v3.1 per-API-level signers, it
  is a rotated key, which Android accepts. Anything else is another signer.
  `apksigner verify` doesn't print a v3 lineage, so `ApkAnalyzer` runs
  `apksigner lineage` for a signature that verifies with v3.
- **v4.** `ApkAnalyzer` gives verify the `<apk>.idsig` next to the APK when
  there is one (`SignatureReport.v4SignatureFile`). If apksigner crashes on
  it, verify runs again without it and keeps the reason
  (`v4SignatureError`). `schemeStatus` tells a v4 that couldn't be checked
  (no `.idsig`) from one that's absent or failed, and Compare notes a v4
  that only one of the two APKs could check.
- **What blocks an update:** another package, another signer, a lower
  versionCode, a signature that doesn't verify (`ComparedField.blocksUpdate`).
- **A part either report couldn't read** is a `NotCompared`, never a
  difference.
- **An app installed as splits isn't one file** (`referenceIsSplit`). Its
  report's size is the files compared together, but its hashes are
  `base.apk`'s alone, so they aren't compared, and it's never the same
  file as the candidate.

`apkComparisonProvider` compares two APKs of the list from their reports,
so nothing is read twice. `installedComparisonProvider` compares with the
installed app. `installSignerWarningProvider` gives Install's warning: it
reads the installed version first (`dumpsys`) and copies the installed app
only when there is one.

## 9. Tests

What is tested and how, the fake for each boundary, and the rules every
test follows are in [TESTING.md](TESTING.md).

## 10. Patterns

| Pattern | Where | What it's for |
|---|---|---|
| Composition root | The providers: `state/providers.dart` for the boundaries and services, each action's provider for its wiring. `main()` overrides the environment and the settings. | The one place that builds things and hands them to whoever uses them. Tests override the boundary providers, or skip them and build the class directly. |
| Adapter behind an app-owned interface | `ProcessRunner` (`IoProcessRunner`), `FileProbe` (`IoFileProbe`), `SettingsStore` (`PreferencesSettingsStore`), `TaskLog` (`LogNotifier`); `Host` for the OS | Every boundary is an interface shaped by what the app needs. Tests fake the interface, never the tool or the OS. |
| Pure builder and parser | `domain/`: the `…Arguments` builders and the `parse…` functions | What to run and what its output means, tested without the tools (§2, `test/fixtures`). |
| Service per tool job | `services/` | Runs one job's commands through a `ToolExecutor`, and throws `ToolFailure`. |
| Action per job | `state/actions/` | What a button does: read the forms, run the services as one task, put the results in the state (§5). |
| Function as a dependency | `clockProvider`, `FileRevealer`, `ToolchainSource`, the actions' readers (`BuildOptions Function()`…) | A dependency with one call is a function type. One with two or more is an interface (`TaskRunner`, `ApkSink`, `ProfileRunProgress`). |
| Closed set | `SettingsKey`; the sealed `SigningSetup` and `SplitAvailability`; enums such as `TargetStatus` | A new case doesn't compile until every `switch` handles it. |
| Model owns its JSON | `fromJson`/`toJson` next to each other on each saved model | One place per field name. `settings_test` pins what this version saves. |
| One report, every way out | `runReport` (`domain/profiles/run_report.dart`) | History's detail, Copy as text and Export say a run the same way: the text is `runReportText` of the same report. |
| One rule, every screen | `targetProblems` (`domain/profiles/target_problems.dart`), through `targetProblemsProvider` and `profileProblemsProvider` | The run check, the import dialog, the Profiles list, the Targets table and Edit target say what's wrong with a target in the same words, so they can't disagree. |
| Observer | Riverpod notifiers and providers | The UI rebuilds from the state; it shows rules, it doesn't hold them. |

## 11. Every change

Check a change against this list before it's done, and say in the pull
request which point it fails, if any:

- [ ] Each piece is in its layer (§1), and no import points up.
- [ ] Dependencies come in through the constructor. A plain class never
      receives `ref`, and there's no new global or singleton.
- [ ] Every boundary (a process, the file system, the settings, the clock,
      the OS) is behind an interface or a provider that a test can replace.
      No `DateTime.now()` or `Platform.is…` outside `core/system` and the
      composition root.
- [ ] No rule in a widget: it's in `domain/` or `state/`, with a test.
- [ ] No rule, message, settings key or field name written twice.
- [ ] A new external command goes through `ProcessRunner` via
      `ToolExecutor`, with its arguments from a pure builder in `domain/` and
      a test.
- [ ] A new tool output has a real captured fixture in `test/fixtures`
      (listed in its README) and a parser test against it.
- [ ] Passwords never go in arguments, logs, settings, errors or the
      history (§3).
- [ ] New behavior has tests, and a bug fix has a test that failed before
      the fix ([TESTING.md](TESTING.md)).
- [ ] `dart format .`, `dart analyze lib test tool` (no issues) and
      `flutter test` pass.
- [ ] A change to the screen was checked by hand on macOS, or the pull
      request says what wasn't checked.
- [ ] The docs that describe the change (README, this file, TESTING.md)
      changed with it.

## 12. Changing the architecture

A change to the rules in this document is decided in an issue and approved
by the owner. It lands with this document updated in the same pull
request. Until then, code that can't follow a rule is listed under Known
deviations, with the reason.

## 13. Known deviations

| Since | Rule | Where | Why, and until when |
|---|---|---|---|
| 2026-10-19 (#11) | Feature-first folders, the default of the owner's mobile-app-architecture rules | `lib/` is layer-first (§1) | The app is small and its steps run in sequence. Layers split by area read better than features calling each other. Moving to features was left out of #11; it needs its own decision (§12). |
