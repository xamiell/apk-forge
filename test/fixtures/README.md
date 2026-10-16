# Test fixtures

Real output of the tools the app drives, so the parsers are tested against
what the tools print and not against a guess. Captured on 2026-10-16 on
macOS with Flutter 3.47.5 and Android SDK build-tools 36.0.0.

| File | Command | Input |
|---|---|---|
| `aapt2_badging_release.txt` | `aapt2 dump badging` | `flutter create` sample, release, arm64-v8a split |
| `aapt2_badging_debug.txt` | `aapt2 dump badging` | the same sample, debug |
| `apksigner_verify_debug_key.txt` | `apksigner verify --verbose --print-certs` | the release split, signed by Gradle with the Android debug key |
| `apksigner_verify_test_key.txt` | the same | that APK re-signed with the throwaway test key |
| `apksigner_verify_unsigned.txt` | the same | the universal APK with `META-INF/` deleted |
| `apksigner_verify_not_zip.txt` | the same | 100 random bytes named `.apk` |
| `keytool_list.txt` | `keytool -J-Duser.language=en -list -v` | a throwaway JKS with an RSA and an EC key |
| `adb_device_info_emulator.txt` | `adb shell "<deviceInfoScript()>"` | Pixel 8 emulator, API 33 (`persist.sys.timezone` and `vendor.qemu.timezone` set to `Etc/UTC`; they held the host's zone) |
| `adb_installed_package_settings.txt` | `adb shell "<installedPackageScript('com.android.settings')>"` | a Dspread D30, Android 14 |
| `flutter_build_split.txt` | `flutter build apk --release --split-per-abi --obfuscate --split-debug-info=…` | the sample |
| `flutter_build_debug.txt` | `flutter build apk --debug --target-platform android-arm64` | the sample |

The test keystore's certificates (`CN=APK Forge Test`, `CN=Second Key`) and
the Android debug certificate are not secret.
