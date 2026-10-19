import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/build/build_options.dart';
import '../domain/build/flutter_build.dart';
import '../domain/signing/abi_split.dart';
import '../domain/signing/keystore.dart';
import '../domain/signing/signing.dart';
import 'apks.dart';
import 'providers.dart';
import 'toolchain_notifier.dart';

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

  factory WorkbenchDefaults.fromJson(Map<String, Object?> json) =>
      WorkbenchDefaults(
        abis: _abisFromJson(json['abis']) ?? const WorkbenchDefaults().abis,
        schemes: SigningSchemes.fromJson(json['schemes']),
        folded: json['folded'] as bool? ?? false,
      );

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

  Map<String, Object?> toJson() => {
    'abis': abiNames.toList(),
    'schemes': schemes.toJson(),
    'folded': folded,
  };
}

final defaultsProvider = NotifierProvider<DefaultsNotifier, WorkbenchDefaults>(
  DefaultsNotifier.new,
);

class DefaultsNotifier extends Notifier<WorkbenchDefaults> {
  @override
  WorkbenchDefaults build() {
    final saved = ref.read(settingsStoreProvider).read(SettingsKey.defaults);
    return saved == null
        ? const WorkbenchDefaults()
        : WorkbenchDefaults.fromJson(saved);
  }

  void update(WorkbenchDefaults Function(WorkbenchDefaults defaults) change) {
    state = change(state);
    ref.read(settingsStoreProvider).write(SettingsKey.defaults, state.toJson());
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
  if (store.read(SettingsKey.defaults) != null) return;
  // Where Build and Sign kept them, before Defaults.
  final abis = store.read(SettingsKey.build)?['abis'];
  final schemes = store.read(SettingsKey.signing)?['schemes'];
  if (abis == null && schemes == null) return;
  store.write(
    SettingsKey.defaults,
    WorkbenchDefaults(
      abis: _abisFromJson(abis) ?? const WorkbenchDefaults().abis,
      schemes: SigningSchemes.fromJson(schemes),
    ).toJson(),
  );
}

// ---------------------------------------------------------------- Build

final buildOptionsProvider =
    NotifierProvider<BuildOptionsNotifier, BuildOptions>(
      BuildOptionsNotifier.new,
    );

class BuildOptionsNotifier extends Notifier<BuildOptions> {
  /// The architectures are the ones in Defaults, and change there.
  @override
  BuildOptions build() {
    final abis = ref.watch(defaultsProvider.select((d) => d.abis));
    final saved = ref.read(settingsStoreProvider).read(SettingsKey.build);
    return saved == null
        ? BuildOptions(abis: abis)
        : BuildOptions.fromJson(saved, abis: abis);
  }

  void update(BuildOptions Function(BuildOptions options) change) {
    state = change(state);
    ref.read(settingsStoreProvider).write(SettingsKey.build, state.toJson());
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

/// Why Build can't run yet: no flutter, the project or the options, or the
/// signing when "Sign after build" is on. Empty when it can.
final buildProblemsProvider = Provider<List<String>>((ref) {
  final options = ref.watch(buildOptionsProvider);
  // Until the tools are found, flutter counts as missing.
  final canBuild = ref.watch(
    toolchainProvider.select((t) => t.value?.canBuild ?? false),
  );
  final signingProblem = ref.watch(signingProblemProvider);
  return [
    if (!canBuild) 'flutter was not found. Set it in Tools.',
    ...buildProblems(
      options,
      ref.watch(hostProvider),
      ref.watch(fileProbeProvider),
    ),
    if (options.signAfterBuild && signingProblem != null)
      'Signing: $signingProblem',
  ];
});

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

  /// What [toJson] saved: no password, and no key until they're loaded.
  factory SigningForm.fromJson(Map<String, Object?> json) => SigningForm(
    keystorePath: json['keystorePath'] as String? ?? '',
    alias: json['alias'] as String?,
    keyUsesStorePassword: json['keyUsesStorePassword'] as bool? ?? true,
    outputDir: json['outputDir'] as String? ?? '',
  );

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

  /// Everything but the passwords, and the keys read with them.
  Map<String, Object?> toJson() => {
    'keystorePath': keystorePath,
    'alias': alias,
    'keyUsesStorePassword': keyUsesStorePassword,
    'outputDir': outputDir,
  };
}

final signingFormProvider = NotifierProvider<SigningFormNotifier, SigningForm>(
  SigningFormNotifier.new,
);

class SigningFormNotifier extends Notifier<SigningForm> {
  @override
  SigningForm build() {
    final saved = ref.read(settingsStoreProvider).read(SettingsKey.signing);
    return saved == null ? const SigningForm() : SigningForm.fromJson(saved);
  }

  void update(SigningForm Function(SigningForm form) change) {
    state = change(state);
    ref.read(settingsStoreProvider).write(SettingsKey.signing, state.toJson());
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

/// What Sign signs with, or why it can't sign yet.
sealed class SigningSetup {
  const SigningSetup();
}

/// The key in Sign, with the schemes in Defaults.
final class ReadyToSign extends SigningSetup {
  const ReadyToSign(this.request, {this.expectedSha256});

  final SigningRequest request;

  /// The selected key's certificate: each signed APK must carry it.
  final String? expectedSha256;
}

final class NotReadyToSign extends SigningSetup {
  const NotReadyToSign(this.problem);

  final String problem;
}

/// [form]'s key with [schemes], or the first thing missing: the key, then
/// the schemes.
SigningSetup signingSetup(SigningForm form, SigningSchemes schemes) {
  final problem = form.problem ?? defaultSchemesProblem(schemes);
  if (problem != null) return NotReadyToSign(problem);
  return ReadyToSign(
    form.toRequest(schemes: schemes),
    expectedSha256: form.selectedEntry?.sha256,
  );
}

final signingSetupProvider = Provider<SigningSetup>(
  (ref) => signingSetup(
    ref.watch(signingFormProvider),
    ref.watch(defaultsProvider.select((d) => d.schemes)),
  ),
);

/// Why Sign can't sign yet, or `null`: its key, or the schemes in Defaults.
final signingProblemProvider = Provider<String?>(
  (ref) => switch (ref.watch(signingSetupProvider)) {
    ReadyToSign() => null,
    NotReadyToSign(:final problem) => problem,
  },
);

/// Why Sign can't sign yet: no apksigner, its key, or the schemes in
/// Defaults. Empty when it can.
final signProblemsProvider = Provider<List<String>>((ref) {
  // While the tools are being found, only the form speaks.
  final canSign = ref.watch(
    toolchainProvider.select((t) => t.value?.canSign ?? true),
  );
  return [
    if (!canSign) 'apksigner was not found (Android SDK build-tools).',
    ?ref.watch(signingProblemProvider),
  ];
});

/// Whether Sign's "Split per ABI and sign" can run on the APK selected in
/// Analyze APK, or, with none selected, on files picked then.
final splitAvailabilityProvider = Provider<SplitAvailability>((ref) {
  final chosen = ref.watch(defaultsProvider.select((d) => d.abiNames));
  final selected = ref.watch(apkListProvider.select((l) => l.selectedPath));
  return splitAvailability(
    chosen,
    contents: selected == null
        ? null
        : ref.watch(apkReportProvider(selected)).value?.contents,
  );
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
