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
| `apksigner_verify_all_schemes.txt` | `apksigner verify --verbose --print-certs --v4-signature-file <apk>.idsig` | `flutter create` sample, release (minSdk 24), signed with v1, v2, v3 and v4 all on and the throwaway key `CN=APK Forge Schemes`: v1 reads false although `META-INF/UPLOAD.SF` and `.RSA` are there, and v4 true only because the `.idsig` is given (captured 2026-10-20 with build-tools 36.0.0) |
| `apksigner_verify_v4_idsig_mismatch.txt` | `apksigner verify --verbose --print-certs --v4-signature-file <other>.idsig <apk>` | `flutter create` sample, release arm64-v8a split, signed with v4 on and the throwaway key `CN=APK Forge Idsig`, given the `.idsig` of the x86_64 split signed the same way: it verifies, with v4 false and no reason. The `.idsig` of the same APK signed with another key (`CN=APK Forge Other Idsig`), and no `.idsig` at all, print the same, byte for byte (captured 2026-10-20 with build-tools 36.0.0) |
| `apksigner_verify_v4_idsig_corrupt.txt` | the same with 200 random bytes as the `.idsig` (exit code 1) | that APK: stderr, a crash before the verdict. An empty `.idsig` crashes with `java.io.EOFException` instead |
| `apksigner_lineage_rotated.txt` | `apksigner lineage --in <apk> --print-certs` | either rotated APK (both print the same lineage) |
| `apksigner_lineage_none.txt` | the same (exit code 1) | the old-key APK, which has no lineage |
| `apksigner_sign_key_password_missing.txt` | `apksigner sign --ks … --ks-pass env:… --ks-key-alias upload --out … <apk>` with its input closed (exit code 2) | a throwaway JKS whose key has a password of its own (`CN=APK Forge Key Password`), without `--key-pass`: what it wrote to stderr. Its stdout was only the prompt `Key "upload" password for signer #1: ` (captured 2026-10-19 with build-tools 36.0.0) |
| `apksigner_sign_wrong_key_password.txt` | the same with `--key-pass env:…` (exit code 2) | that keystore, a wrong key password: stderr |
| `apksigner_sign_wrong_store_password.txt` | the same (exit code 2) | that keystore, a wrong keystore password: stderr |
| `apksigner_sign_wrong_store_password_pkcs12.txt` | `apksigner sign --ks … --ks-pass env:… --ks-key-alias upload --out … <apk>` with its input closed (exit code 2) | a throwaway PKCS12 keystore (`CN=APK Forge PKCS12`), a wrong keystore password: stderr. PKCS12 words it `keystore password was incorrect` (captured 2026-10-21 with build-tools 36.0.0 and JDK 21) |
| `apksigner_sign_wrong_key_password_pkcs12.txt` | the same with `--key-pass env:…` (exit code 2) | that keystore, the right keystore password and a wrong key password: stderr |
| `keytool_certreq_ok.txt` | `keytool -J-Duser.language=en -certreq` | a throwaway JKS whose key has its own password, both passwords right (captured 2026-10-18) |
| `keytool_certreq_wrong_key_password.txt` | the same (exit code 1) | the same keystore, a wrong key password |
| `keytool_certreq_wrong_store_password.txt` | the same (exit code 1) | the same keystore, a wrong keystore password |
| `keytool_certreq_no_alias.txt` | the same (exit code 1) | the same keystore, an alias it doesn't have |
| `keytool_list_wrong_password.txt` | `keytool -J-Duser.language=en -list -v` (exit code 1) | that keystore, a wrong keystore password: `-v` adds the stack trace |
| `keytool_certreq_wrong_store_password_pkcs12.txt` | `keytool -J-Duser.language=en -certreq` (exit code 1) | the PKCS12 keystore of `apksigner_sign_wrong_store_password_pkcs12.txt`, a wrong keystore password (captured 2026-10-21) |
| `keytool_list.txt` | `keytool -J-Duser.language=en -list -v` | a throwaway JKS with an RSA and an EC key |
| `keytool_genkeypair_no_folder.txt` | `keytool -J-Duser.language=en -J-Duser.country=US -genkeypair -keystore … -storetype PKCS12 -storepass:env … -keypass:env … -alias upload -keyalg RSA -keysize 2048 -validity 9131 -dname …` (exit code 1) | a keystore path in a folder that doesn't exist: stdout. Its stderr held only keytool's `Generating 2,048 bit RSA key pair…` lines (captured 2026-10-21 with JDK 21) |
| `keytool_genkeypair_read_only_folder.txt` | the same (exit code 1) | a keystore path in a folder its owner can't write to |
| `keytool_genkeypair_bad_name.txt` | the same (exit code 1) | `-dname "CN=A, O=B, C"`, a field without a value |
| `adb_device_info_emulator.txt` | `adb shell "<deviceInfoScript()>"` | Pixel 8 emulator, API 33 (`persist.sys.timezone` and `vendor.qemu.timezone` set to `Etc/UTC`; they held the host's zone) |
| `adb_pm_path_single.txt` | `adb shell pm path com.google.android.apps.meetings` | a phone, Android 13: an app installed from Play as one APK (captured 2026-10-18) |
| `adb_pm_path_bundle.txt` | `adb shell pm path com.github.android` | the same phone: an app installed from Play as an App Bundle, `base.apk` plus an ABI and a density split |
| `adb_installed_package_settings.txt` | `adb shell "<installedPackageScript('com.android.settings')>"` | a physical device, Android 14 |
| `bundletool_dump_manifest.txt` | `java -jar bundletool-all-1.18.3.jar dump manifest --bundle=<aab>` | the sample's release bundle, signed with a throwaway key (captured 2026-10-21) |
| `bundletool_build_apks_wrong_password.txt` | `… build-apks --bundle=<aab> --output=… --connected-device --device-id=emulator-5554 --adb=… --ks=… --ks-key-alias=upload --ks-pass=file:… --key-pass=file:…` (exit code 1) | a throwaway PKCS12 keystore, a wrong password in both files: stderr |
| `bundletool_build_apks_wrong_key_password.txt` | the same (exit code 1) | a throwaway JKS whose key has a password of its own, the right keystore password and a wrong key password |
| `bundletool_build_apks_wrong_key_password_pkcs12.txt` | the same (exit code 1) | the PKCS12 keystore, the right keystore password and another `--key-pass` |
| `bundletool_build_apks_no_device.txt` | the same with `--device-id=emulator-9999` (exit code 1) | a device that isn't connected |
| `bundletool_install_apks.txt` | `… install-apks --apks=<apks> --device-id=emulator-5554 --adb=…` | an Android 13 emulator without the app: stderr. In the three `install-apks` captures, the system's temporary folder is shortened to `/var/folders/xx/T/` |
| `bundletool_install_apks_downgrade.txt` | the same (exit code 1) | the emulator with a higher versionCode of the app installed, signed with the debug key: stderr |
| `bundletool_install_apks_other_key.txt` | the same (exit code 1) | the emulator with the same version installed, signed with another throwaway key: stderr |
| `flutter_version_machine.txt` | `flutter --version --machine` | Flutter 3.47.5 on macOS. The Flutter root is replaced by `/Users/dev/flutter` (captured 2026-10-21) |
| `java_version.txt` | `java -version` (stderr) | Homebrew's OpenJDK 21.0.10 (captured 2026-10-21) |
| `bundletool_version.txt` | `java -jar bundletool-all-1.18.3.jar version` | the official jar, from github.com/google/bundletool (captured 2026-10-21 with JDK 21) |
| `flutter_build_appbundle.txt` | `flutter build appbundle --release --target-platform android-arm,android-arm64,android-x64 --obfuscate --split-debug-info=…` | the sample: stdout and stderr. The home folder in one Gradle warning is replaced by `/Users/dev` (captured 2026-10-21 with Flutter 3.47.5) |
| `jarsigner_verify_bundle.txt` | `jarsigner -J-Duser.language=en -J-Duser.country=US -verify <aab>` | that bundle without its debug signature, signed by `jarsigner` with the throwaway PKCS12 key `CN=APK Forge Bundle` (captured 2026-10-21 with JDK 21) |
| `jarsigner_verify_unsigned.txt` | the same | that bundle without its debug signature, unsigned |
| `jarsigner_verify_signed_over_debug.txt` | the same (exit code 1) | that bundle signed by `jarsigner` on top of its debug signature, with jarsigner's default digest: it no longer verifies |
| `keytool_printcert_jarfile.txt` | `keytool -J-Duser.language=en -J-Duser.country=US -printcert -jarfile <aab>` | the bundle of `jarsigner_verify_bundle.txt` |
| `keytool_printcert_jarfile_two_signers.txt` | the same | that bundle signed on top of its debug signature with `-sigalg SHA256withRSA -digestalg SHA-256`: it verifies, with two signers |
| `keytool_printcert_jarfile_unsigned.txt` | the same | the bundle without its debug signature, unsigned |
| `jarsigner_sign_wrong_store_password_pkcs12.txt` | `jarsigner -J-Duser.language=en -J-Duser.country=US -keystore … -storepass:env … -keypass:env … -signedjar … <aab> upload` with its input closed (exit code 1) | the PKCS12 keystore, a wrong keystore password |
| `jarsigner_sign_wrong_store_password_jks.txt` | the same (exit code 1) | a throwaway JKS whose key has a password of its own (`CN=APK Forge Bundle Key Password`), a wrong keystore password |
| `jarsigner_sign_wrong_key_password.txt` | the same (exit code 1) | that JKS, a wrong key password. A PKCS12 keystore with a wrong `-keypass` prints the same |
| `jarsigner_sign_key_password_missing.txt` | the same without `-keypass` (exit code 1) | that JKS: what it printed before giving up on the prompt |
| `flutter_build_split.txt` | `flutter build apk --release --split-per-abi --obfuscate --split-debug-info=…` | the sample |
| `flutter_build_debug.txt` | `flutter build apk --debug --target-platform android-arm64` | the sample |

The test keystore's certificates (`CN=APK Forge Test`, `CN=Second Key`), the
rotation's throwaway keys (`CN=APK Forge Old Key`, `CN=APK Forge New Key`),
the key check's throwaway key (`CN=APK Forge Key Check`, whose certificate
request is in `keytool_certreq_ok.txt`), the signing failures' throwaway key
(`CN=APK Forge Key Password`), the schemes' throwaway key
(`CN=APK Forge Schemes`), the v4 checks' throwaway keys
(`CN=APK Forge Idsig`, `CN=APK Forge Other Idsig`), the PKCS12 failures'
throwaway key (`CN=APK Forge PKCS12`), the App Bundle's throwaway keys
(`CN=APK Forge Bundle`, `CN=APK Forge Bundle Key Password`), the install's
throwaway keys (`CN=APK Forge Install A`, `B` and `Own`) and the Android debug
certificate are not secret.
