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
| `apksigner_verify_old_key.txt` | the same | `flutter create` sample, release arm64-v8a, re-signed with the throwaway old key (captured 2026-10-18) |
| `apksigner_verify_rotated_v3.txt` | the same | that APK signed with the old key, `--next-signer` the new key, `--lineage` from `apksigner rotate` and `--rotation-min-sdk-version 28`: v3 carries the new key |
| `apksigner_verify_rotated_v31.txt` | the same | the same rotation with the default `--rotation-min-sdk-version` (33): v3.1 carries the new key, v3 the old one |
| `apksigner_lineage_rotated.txt` | `apksigner lineage --in <apk> --print-certs` | either rotated APK (both print the same lineage) |
| `apksigner_lineage_none.txt` | the same (exit code 1) | the old-key APK, which has no lineage |
| `keytool_list.txt` | `keytool -J-Duser.language=en -list -v` | a throwaway JKS with an RSA and an EC key |
| `adb_device_info_emulator.txt` | `adb shell "<deviceInfoScript()>"` | Pixel 8 emulator, API 33 (`persist.sys.timezone` and `vendor.qemu.timezone` set to `Etc/UTC`; they held the host's zone) |
| `adb_pm_path_single.txt` | `adb shell pm path com.google.android.apps.meetings` | a phone, Android 13: an app installed from Play as one APK (captured 2026-10-18) |
| `adb_pm_path_bundle.txt` | `adb shell pm path com.github.android` | the same phone: an app installed from Play as an App Bundle, `base.apk` plus an ABI and a density split |
| `adb_installed_package_settings.txt` | `adb shell "<installedPackageScript('com.android.settings')>"` | a physical device, Android 14 |
| `flutter_build_split.txt` | `flutter build apk --release --split-per-abi --obfuscate --split-debug-info=…` | the sample |
| `flutter_build_debug.txt` | `flutter build apk --debug --target-platform android-arm64` | the sample |

The test keystore's certificates (`CN=APK Forge Test`, `CN=Second Key`), the
rotation's throwaway keys (`CN=APK Forge Old Key`, `CN=APK Forge New Key`)
and the Android debug certificate are not secret.
