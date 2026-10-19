import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/build/build_options.dart';
import '../domain/signing/keystore.dart';
import '../domain/signing/signing.dart';
import 'providers.dart';

// ---------------------------------------------------------------- Defaults

/// What Build and Sign share, set once at the top of the Workbench.
class WorkbenchDefaults {
  const WorkbenchDefaults({
    this.abis = const {
      AndroidAbi.armeabiV7a,
      AndroidAbi.arm64V8a,
      AndroidAbi.x8664,
    },
    this.schemes = const SigningSchemes.automatic(),
    this.folded = false,
  });

  /// What Build targets, and the APKs "Split per ABI and sign" writes.
  final Set<AndroidAbi> abis;

  /// What Sign writes, and a profile target without schemes of its own.
  final SigningSchemes schemes;

  /// The card shows one line.
  final bool folded;

  /// [abis] as the folder names under `lib/`, in the enum's order.
  Set<String> get abiNames => {
    for (final abi in AndroidAbi.values)
      if (abis.contains(abi)) abi.abiName,
  };

  WorkbenchDefaults copyWith({
    Set<AndroidAbi>? abis,
    SigningSchemes? schemes,
    bool? folded,
  }) => WorkbenchDefaults(
    abis: abis ?? this.abis,
    schemes: schemes ?? this.schemes,
    folded: folded ?? this.folded,
  );
}

final defaultsProvider = NotifierProvider<DefaultsNotifier, WorkbenchDefaults>(
  DefaultsNotifier.new,
);

class DefaultsNotifier extends Notifier<WorkbenchDefaults> {
  static const _key = 'defaults';

  @override
  WorkbenchDefaults build() {
    final saved = ref.read(settingsStoreProvider).read(_key);
    if (saved == null) return const WorkbenchDefaults();
    return WorkbenchDefaults(
      abis: _abisFromJson(saved['abis']) ?? const WorkbenchDefaults().abis,
      schemes: SigningSchemes.fromJson(saved['schemes']),
      folded: saved['folded'] as bool? ?? false,
    );
  }

  void update(WorkbenchDefaults Function(WorkbenchDefaults defaults) change) {
    state = change(state);
    ref.read(settingsStoreProvider).write(_key, {
      'abis': state.abiNames.toList(),
      'schemes': state.schemes.toJson(),
      'folded': state.folded,
    });
  }

  void toggleAbi(AndroidAbi abi) => update((defaults) {
    final abis = {...defaults.abis};
    if (!abis.remove(abi)) abis.add(abi);
    return defaults.copyWith(abis: abis);
  });
}

Set<AndroidAbi>? _abisFromJson(Object? json) => json is List
    ? json
          .whereType<String>()
          .map(AndroidAbi.fromAbiName)
          .whereType<AndroidAbi>()
          .toSet()
    : null;

/// Moves what older versions kept in Build and Sign, the architectures and
/// the signature schemes, to Defaults. Runs once, before anything reads or
/// writes the settings: Build and Sign no longer save them.
void migrateSettings(SettingsStore store) {
  if (store.read(DefaultsNotifier._key) != null) return;
  final build = store.read(BuildOptionsNotifier._key);
  final signing = store.read(SigningFormNotifier._key);
  if (build?['abis'] == null && signing?['schemes'] == null) return;
  store.write(DefaultsNotifier._key, {
    'abis': build?['abis'],
    'schemes': signing?['schemes'],
  });
}

// ---------------------------------------------------------------- Build

final buildOptionsProvider =
    NotifierProvider<BuildOptionsNotifier, BuildOptions>(
      BuildOptionsNotifier.new,
    );

class BuildOptionsNotifier extends Notifier<BuildOptions> {
  static const _key = 'build';

  /// The architectures are the ones in Defaults, and change there.
  @override
  BuildOptions build() {
    final abis = ref.watch(defaultsProvider.select((d) => d.abis));
    final saved = ref.read(settingsStoreProvider).read(_key);
    if (saved == null) return BuildOptions(abis: abis);
    const defaults = BuildOptions();
    return BuildOptions(
      projectDir: saved['projectDir'] as String? ?? '',
      mode: BuildMode.values.asNameMap()[saved['mode']] ?? defaults.mode,
      abis: abis,
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

  /// The schemes are the ones in Defaults.
  SigningRequest toRequest({required SigningSchemes schemes}) => SigningRequest(
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
    String? outputDir,
  }) => SigningForm(
    keystorePath: keystorePath ?? this.keystorePath,
    storePassword: storePassword ?? this.storePassword,
    entries: entries ?? this.entries,
    alias: clearAlias ? null : (alias ?? this.alias),
    keyUsesStorePassword: keyUsesStorePassword ?? this.keyUsesStorePassword,
    keyPassword: keyPassword ?? this.keyPassword,
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
    return SigningForm(
      keystorePath: saved['keystorePath'] as String? ?? '',
      alias: saved['alias'] as String?,
      keyUsesStorePassword: saved['keyUsesStorePassword'] as bool? ?? true,
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

/// Why Sign can't sign yet, or `null`: its key, or the schemes in Defaults.
final signingProblemProvider = Provider<String?>((ref) {
  final problem = ref.watch(signingFormProvider.select((f) => f.problem));
  if (problem != null) return problem;
  final schemes = ref.watch(defaultsProvider.select((d) => d.schemes.problem));
  return schemes == null ? null : 'Signature schemes in Defaults: $schemes';
});

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
