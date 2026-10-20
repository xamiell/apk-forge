# Architecture

APK Forge is one screen over five external tools: `flutter`, `apksigner`,
`zipalign`, `aapt2`, `keytool` and `adb`. The design goal is that everything
that decides something (which command to run, what a tool's output means,
what to warn about) is plain Dart that a test can drive without the tools,
and that the code which actually starts the tools is thin.

## 1. Layers

```
lib/
  core/       Process running, the host OS, ZIP reading and copying, formatting, log types.
  domain/     Models, command builders, output parsers, findings. Pure.
  services/   One class per tool job; runs commands through a ProcessRunner.
  state/      Riverpod notifiers (forms, the current task, the log) and the
              actions the buttons run (state/actions/).
  ui/         The screen and its panels.
  main.dart   Loads the shell environment and settings, starts the app.
tool/
  smoke.dart  The services against the real tools (see README).
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

- Passwords live only in memory: in `SigningForm`, in the `SigningRequest`
  built from it for a task (`ReadyToSign`), and in `Command.environment`.
- They are passed to tools through environment variables, never arguments:
  `apksigner --ks-pass env:APK_FORGE_KS_PASS`, `keytool -storepass:env …`.
- `Command.secrets` lists them; the log and `ToolFailure.fromResult` mask
  them.
- `SettingsStore` receives explicit maps without them.

A test covers each of these. Keep it that way when a new tool takes a secret.

## 4. Tools and the host

- `Host` (`core/system/host.dart`) is the OS and the environment as values.
  Code that depends on them takes a `Host`, so tests can describe Windows
  while running on a Mac.
- `FileProbe` answers "does this exist?" for `ToolchainLocator`, which finds
  the tools from overrides, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, the default
  SDK folders and `PATH`.
- `loadShellEnvironment` reads the login shell's environment once at
  startup. Every process starts with it, because an app opened from Finder
  has a bare `PATH`.

## 5. State

- **One task at a time.** `TaskNotifier.run` refuses to start a second one,
  holds the cancel token, and turns a `ToolFailure` into the error banner.
  Builds, signings, key loading and installs go through it. Listing devices,
  analyzing an APK and reading an installed app don't: they change nothing.
- **Actions** (`state/actions/`) are plain classes, one per job: build, sign,
  split and sign, run a profile, load keys, install. Each takes what it uses
  in its constructor: the services, a `TaskRunner`, an `ApkSink` for the
  APKs it writes, and functions that read the forms when the button is
  pressed (`SigningSetup` says what Sign signs with, or why it can't). Their
  providers are where that's wired; no action receives `ref`.
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
  package) until the device list is refreshed. The Install and Device panels
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
  result per serial and package until a refresh.

## 7. Signing

`ApkSigningService.sign`:

1. `zipalign -c` (with `-P 16` on build-tools 35+). If it fails, an aligned
   copy is written to a temporary folder first.
2. `apksigner sign` writes `<name>-signed.apk.partial`.
3. `apksigner verify` must say it verifies, with the selected key's SHA-256.
4. Only then is the `.partial` (and its `.idsig`) renamed over
   `<name>-signed.apk`. On any failure the `.partial` files are deleted, and
   an earlier signed APK stays as it was.

The input is never modified or overwritten (`signedApkPath`).

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
- **What blocks an update:** another package, another signer, a lower
  versionCode, a signature that doesn't verify (`ComparedField.blocksUpdate`).
- **A part either report couldn't read** is a `NotCompared`, never a
  difference.

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
| 2026-10-19 (#11) | No boundary or rule in a widget | `ui/profiles/profile_history.dart` (`_RunResults`) asks the `FileProbe` whether a signed APK is still there | #14 reworks the history. |
