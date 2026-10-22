# Changelog

What changed in each version of APK Forge. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-10-22

Signing profiles, Compare, App Bundles and new upload keys.

### Added

- **Split per ABI and sign** in Sign turns a universal APK, one from CI
  say, into one signed APK per architecture in Defaults. An ABI with
  native code but no Flutter engine gets no APK. ([#1])
- **Compare with…** in Analyze APK compares an APK, as an update, with
  another APK or with the app installed on the device. It lists every
  difference, worst first: another signer, a lower versionCode, a debug
  build, lost ABIs, new permissions. ([#3])
- Analyze APK reads a rotated signing key with `apksigner lineage`, and
  Compare accepts it, as Android does. A v3.1 signer is labelled by the
  API levels it signs for. ([#3])
- Install warns before an install Android would refuse because the APK is
  signed with another key than the installed app. ([#3])
- **Signing profiles** save the steps to turn one APK into a signed APK per
  device, each with its ABI, its key (a `key.properties` file), its schemes
  and its folder, and run them in one go. Targets that share an ABI, a key
  and the schemes are signed once. A profile exports to JSON and imports,
  with paths and choices only, never a password. ([#4], [#7], [#8])
- **Defaults** holds what Build and Sign share, the architectures and the
  signature schemes, once at the top, and folds into one line. Sign works
  on the APK selected in Analyze APK. ([#4])
- A target's problems, such as a `key.properties` or a folder missing on
  this machine, show in the same words in the Profiles list, the Targets
  table and Edit target. **Create folder** makes a missing folder. ([#13])
- **History** keeps every profile run as a report: for each target, its
  ABI, its key, the schemes asked and the ones verified, the signer and the
  output. **Copy as text** and **Export…** give the same report. ([#14])
- **New key…** in Sign makes an upload key, PKCS12 or JKS: the keystore and
  the `key.properties` Gradle reads, in a folder you choose. It loads the
  key in Sign and never overwrites a file. ([#26])
- **App Bundles.** Build makes an `.aab` with `flutter build appbundle` and
  signs it with `jarsigner` and the key in Sign, without the debug
  signature Flutter gave it. Sign signs a picked `.aab` too. ([#27])
- Analyze APK opens an App Bundle: its files, its manifest (with
  bundletool) and its JAR signature. Install installs one the way a store
  delivers it: bundletool makes the device's APKs, signed with the key in
  Sign. ([#28])
- **Tools** sets the build-tools version, the JDK folder and bundletool,
  next to the Flutter and Android SDK folders. Each one is checked before
  it counts. One that can't be used shows in red with the reason, and
  nothing else is used in its place. ([#30])
- The macOS app icon is APK Forge's logo. ([#35])

### Changed

- The code follows the architecture rules: one closed set of settings
  keys, one action class per job with its dependencies in the constructor,
  and no rule in a widget. [ARCHITECTURE.md](docs/ARCHITECTURE.md) gained
  the patterns, the "Every change" list and the known deviations, and
  [TESTING.md](docs/TESTING.md) the rules every test follows. ([#11])
- `tool/smoke.dart` also runs a signing profile, an App Bundle and a new
  key of each type against the real tools. ([#8], [#26], [#27])

### Fixed

- Sign waited until Cancel when the key had a password of its own but
  "The key uses the keystore password" was ticked. Every tool's input is
  now closed as it starts, so apksigner fails at once, and Sign says which
  password it couldn't use and what to do. ([#9])
- After Install, Analyze device said the app wasn't installed until the
  devices were refreshed. It now shows the version just installed. ([#16])
- A v4 signature always showed as not verified, because `apksigner verify`
  checks v4 only with the `.idsig` file. Sign, a profile run and Analyze
  APK now pass the one next to the APK. Without one, v4 shows as not
  checked. ([#14], [#21])
- A PKCS12 keystore with a wrong password said "Signing failed" with a
  stack trace. It now says the keystore password is wrong. ([#24])
- Compare called an app installed as splits "The same file" as an APK
  whose size and files differed. Such an app's hashes are `base.apk`'s
  alone, so they're no longer compared. ([#33])
- Two profiles could share a name, and a key or folder missing on this
  machine failed only during the run. A name already taken now gets a
  number, and the run stops before anything is signed. ([#7])
- Text fields lost characters when keys came faster than a frame, and the
  APK list could hold APKs with none selected. ([#4])
- Edit and Remove went out of view when the Targets table showed a
  target's problems. ([#13])

## [1.0.0] - 2026-10-16

The first version: one screen over `flutter build`, `zipalign`,
`apksigner`, `keytool` and `adb` that shows every command and its output
as it runs.

### Added

- **Build** runs `flutter build apk`, release or debug, for any mix of
  ABIs, as one universal APK or one per ABI, with optional Dart
  obfuscation.
- **Sign** aligns the APK if needed, signs a `.partial` copy with the
  chosen key, and keeps it only if it verifies with that key's SHA-256.
- **Analyze APK** shows whether the signature verifies, its schemes, the
  signer (yours or the debug key), release or debug, the native code per
  ABI and the hashes.
- **Analyze device** shows the Android version, the ABIs, the memory page
  size, the hardware and its status, and what installing the selected APK
  would do.
- **Install** runs `adb install` and explains the common failures.
- Passwords stay in memory and reach the tools through environment
  variables, never arguments, settings or logs.

[1.1.0]: https://github.com/xamiell/apk-forge/compare/43ff62a...v1.1.0
[1.0.0]: https://github.com/xamiell/apk-forge/commit/43ff62a
[#1]: https://github.com/xamiell/apk-forge/issues/1
[#3]: https://github.com/xamiell/apk-forge/issues/3
[#4]: https://github.com/xamiell/apk-forge/issues/4
[#7]: https://github.com/xamiell/apk-forge/issues/7
[#8]: https://github.com/xamiell/apk-forge/issues/8
[#9]: https://github.com/xamiell/apk-forge/issues/9
[#11]: https://github.com/xamiell/apk-forge/issues/11
[#13]: https://github.com/xamiell/apk-forge/issues/13
[#14]: https://github.com/xamiell/apk-forge/issues/14
[#16]: https://github.com/xamiell/apk-forge/issues/16
[#21]: https://github.com/xamiell/apk-forge/issues/21
[#24]: https://github.com/xamiell/apk-forge/issues/24
[#26]: https://github.com/xamiell/apk-forge/issues/26
[#27]: https://github.com/xamiell/apk-forge/issues/27
[#28]: https://github.com/xamiell/apk-forge/issues/28
[#30]: https://github.com/xamiell/apk-forge/issues/30
[#33]: https://github.com/xamiell/apk-forge/issues/33
[#35]: https://github.com/xamiell/apk-forge/issues/35
