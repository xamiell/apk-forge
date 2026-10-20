import 'package:file_selector/file_selector.dart';

const apkTypes = XTypeGroup(label: 'APK', extensions: ['apk']);

const keystoreTypes = XTypeGroup(
  label: 'Keystores',
  extensions: ['jks', 'keystore', 'p12', 'pfx', 'ks'],
);

const keyPropertiesTypes = XTypeGroup(
  label: 'key.properties',
  extensions: ['properties'],
);

const profileTypes = XTypeGroup(
  label: 'APK Forge profile',
  extensions: ['json'],
);

const textTypes = XTypeGroup(label: 'Text', extensions: ['txt']);
