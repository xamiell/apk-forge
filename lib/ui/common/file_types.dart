import 'package:file_selector/file_selector.dart';

const apkTypes = XTypeGroup(label: 'APK', extensions: ['apk']);

const keystoreTypes = XTypeGroup(
  label: 'Keystores',
  extensions: ['jks', 'keystore', 'p12', 'pfx', 'ks'],
);
