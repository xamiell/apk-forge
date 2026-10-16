import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/build/build_options.dart';
import '../domain/signing/keystore.dart';
import '../domain/signing/signing.dart';
import 'providers.dart';

// ---------------------------------------------------------------- Build

final buildOptionsProvider =
    NotifierProvider<BuildOptionsNotifier, BuildOptions>(
      BuildOptionsNotifier.new,
    );

class BuildOptionsNotifier extends Notifier<BuildOptions> {
  static const _key = 'build';

  @override
  BuildOptions build() {
    final saved = ref.read(settingsStoreProvider).read(_key);
    if (saved == null) return const BuildOptions();
    const defaults = BuildOptions();
    final abis = (saved['abis'] as List?)
        ?.whereType<String>()
        .map(AndroidAbi.fromAbiName)
        .whereType<AndroidAbi>()
        .toSet();
    return BuildOptions(
      projectDir: saved['projectDir'] as String? ?? '',
      mode: BuildMode.values.asNameMap()[saved['mode']] ?? defaults.mode,
      abis: abis ?? defaults.abis,
      packaging:
          ApkPackaging.values.asNameMap()[saved['packaging']] ??
          defaults.packaging,
      obfuscate: saved['obfuscate'] as bool? ?? false,
      symbolsDir: saved['symbolsDir'] as String? ?? '',
      signAfterBuild:
          saved['signAfterBuild'] as bool? ?? defaults.signAfterBuild,
    );
  }

  void update(BuildOptions Function(BuildOptions options) change) {
    state = change(state);
    ref.read(settingsStoreProvider).write(_key, {
      'projectDir': state.projectDir,
      'mode': state.mode.name,
      'abis': [
        for (final abi in AndroidAbi.values)
          if (state.abis.contains(abi)) abi.abiName,
      ],
      'packaging': state.packaging.name,
      'obfuscate': state.obfuscate,
      'symbolsDir': state.symbolsDir,
      'signAfterBuild': state.signAfterBuild,
    });
  }

  /// Picking a project also proposes `<project>/build/symbols` for the
  /// obfuscation symbols when none was chosen.
  void setProject(
    String projectDir, {
    required String Function(String) defaultSymbolsDir,
  }) {
    update(
      (options) => options.copyWith(
        projectDir: projectDir,
        symbolsDir: options.symbolsDir.isEmpty
            ? defaultSymbolsDir(projectDir)
            : null,
      ),
    );
  }

  void toggleAbi(AndroidAbi abi) => update((options) {
    final abis = {...options.abis};
    if (!abis.remove(abi)) abis.add(abi);
    return options.copyWith(abis: abis);
  });
}

// ---------------------------------------------------------------- Sign

class SigningForm {
  const SigningForm({
    this.keystorePath = '',
    this.storePassword = '',
    this.entries = const [],
    this.alias,
    this.keyUsesStorePassword = true,
    this.keyPassword = '',
    this.schemes = const SigningSchemes.automatic(),
    this.outputDir = '',
  });

  final String keystorePath;

  /// Kept in memory only, for this run of the app.
  final String storePassword;

  /// Read from the keystore with "Load keys". Empty until then.
  final List<KeystoreEntry> entries;
  final String? alias;
  final bool keyUsesStorePassword;
  final String keyPassword;
  final SigningSchemes schemes;

  /// Empty: next to each APK.
  final String outputDir;

  KeystoreEntry? get selectedEntry {
    for (final entry in entries) {
      if (entry.alias == alias) return entry;
    }
    return null;
  }

  bool get canLoadKeys =>
      keystorePath.trim().isNotEmpty && storePassword.isNotEmpty;

  /// Why signing can't happen yet, or `null` when it can.
  String? get problem {
    if (keystorePath.trim().isEmpty) return 'Choose a keystore.';
    if (storePassword.isEmpty) return 'Enter the keystore password.';
    if (entries.isEmpty) return 'Load the keys from the keystore.';
    final entry = selectedEntry;
    if (entry == null) return 'Choose the key to sign with.';
    if (!entry.canSign) return '“${entry.alias}” is a certificate, not a key.';
    if (!keyUsesStorePassword && keyPassword.isEmpty) {
      return 'Enter the key password.';
    }
    return null;
  }

  bool get isReady => problem == null;

  SigningRequest toRequest() => SigningRequest(
    keystorePath: keystorePath.trim(),
    storePassword: storePassword,
    alias: alias!,
    keyPassword: keyUsesStorePassword ? null : keyPassword,
    schemes: schemes,
    outputDir: outputDir.trim().isEmpty ? null : outputDir.trim(),
  );

  SigningForm copyWith({
    String? keystorePath,
    String? storePassword,
    List<KeystoreEntry>? entries,
    String? alias,
    bool clearAlias = false,
    bool? keyUsesStorePassword,
    String? keyPassword,
    SigningSchemes? schemes,
    String? outputDir,
  }) => SigningForm(
    keystorePath: keystorePath ?? this.keystorePath,
    storePassword: storePassword ?? this.storePassword,
    entries: entries ?? this.entries,
    alias: clearAlias ? null : (alias ?? this.alias),
    keyUsesStorePassword: keyUsesStorePassword ?? this.keyUsesStorePassword,
    keyPassword: keyPassword ?? this.keyPassword,
    schemes: schemes ?? this.schemes,
    outputDir: outputDir ?? this.outputDir,
  );
}

final signingFormProvider = NotifierProvider<SigningFormNotifier, SigningForm>(
  SigningFormNotifier.new,
);

class SigningFormNotifier extends Notifier<SigningForm> {
  static const _key = 'signing';

  @override
  SigningForm build() {
    final saved = ref.read(settingsStoreProvider).read(_key);
    if (saved == null) return const SigningForm();
    final schemes = saved['schemes'] as Map<String, Object?>?;
    return SigningForm(
      keystorePath: saved['keystorePath'] as String? ?? '',
      alias: saved['alias'] as String?,
      keyUsesStorePassword: saved['keyUsesStorePassword'] as bool? ?? true,
      schemes: SigningSchemes(
        v1: schemes?['v1'] as bool?,
        v2: schemes?['v2'] as bool?,
        v3: schemes?['v3'] as bool?,
        v4: schemes?['v4'] as bool?,
      ),
      outputDir: saved['outputDir'] as String? ?? '',
    );
  }

  void update(SigningForm Function(SigningForm form) change) {
    state = change(state);
    // Everything but the passwords.
    ref.read(settingsStoreProvider).write(_key, {
      'keystorePath': state.keystorePath,
      'alias': state.alias,
      'keyUsesStorePassword': state.keyUsesStorePassword,
      'schemes': {
        'v1': state.schemes.v1,
        'v2': state.schemes.v2,
        'v3': state.schemes.v3,
        'v4': state.schemes.v4,
      },
      'outputDir': state.outputDir,
    });
  }

  /// Another keystore: its keys and password are unknown again.
  void setKeystore(String path) => update(
    (form) => form.copyWith(
      keystorePath: path,
      storePassword: '',
      entries: const [],
      clearAlias: true,
    ),
  );

  /// A new password invalidates the keys read with the old one.
  void setStorePassword(String password) {
    if (password == state.storePassword) return;
    update((form) => form.copyWith(storePassword: password, entries: const []));
  }

  void setEntries(List<KeystoreEntry> entries) => update((form) {
    final signing = entries.where((entry) => entry.canSign).toList();
    final keep = entries.any((entry) => entry.alias == form.alias);
    return form.copyWith(
      entries: entries,
      alias: keep ? form.alias : (signing.isEmpty ? null : signing.first.alias),
      clearAlias: !keep && signing.isEmpty,
    );
  });
}

// ---------------------------------------------------------------- Install

class InstallOptions {
  const InstallOptions({this.selectedSerial, this.allowDowngrade = false});

  final String? selectedSerial;
  final bool allowDowngrade;
}

final installOptionsProvider =
    NotifierProvider<InstallOptionsNotifier, InstallOptions>(
      InstallOptionsNotifier.new,
    );

class InstallOptionsNotifier extends Notifier<InstallOptions> {
  @override
  InstallOptions build() => const InstallOptions();

  void select(String? serial) => state = InstallOptions(
    selectedSerial: serial,
    allowDowngrade: state.allowDowngrade,
  );

  void setAllowDowngrade(bool value) => state = InstallOptions(
    selectedSerial: state.selectedSerial,
    allowDowngrade: value,
  );
}
