import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/system/host.dart';
import '../domain/analysis/apk_report.dart';
import '../domain/failure.dart';
import '../domain/profiles/key_properties.dart';
import '../domain/profiles/profile.dart';
import '../domain/profiles/profile_plan.dart';
import '../domain/profiles/profile_run.dart';
import '../services/profile_runner.dart';
import '../services/tool_executor.dart';
import 'apks.dart';
import 'forms.dart';
import 'log_notifier.dart';
import 'providers.dart';
import 'toolchain_notifier.dart';

/// The two places of the app: one-off work, and setting up profiles.
enum AppView { workbench, profiles }

final appViewProvider = NotifierProvider<AppViewNotifier, AppView>(
  AppViewNotifier.new,
);

class AppViewNotifier extends Notifier<AppView> {
  @override
  AppView build() => AppView.workbench;

  void show(AppView view) => state = view;
}

/// A profile's two tabs.
enum ProfileTab { setup, history }

final profileTabProvider = NotifierProvider<ProfileTabNotifier, ProfileTab>(
  ProfileTabNotifier.new,
);

class ProfileTabNotifier extends Notifier<ProfileTab> {
  @override
  ProfileTab build() => ProfileTab.setup;

  void show(ProfileTab tab) => state = tab;
}

class ProfilesState {
  const ProfilesState({this.profiles = const [], this.selectedId});

  /// A selection that's gone falls back to the first profile.
  factory ProfilesState.fromJson(Map<String, Object?> json) {
    final profiles = [
      for (final profile in json['profiles'] as List<Object?>? ?? const [])
        if (profile is Map<String, Object?>) SigningProfile.fromJson(profile),
    ];
    final selected = json['selected'] as String?;
    return ProfilesState(
      profiles: profiles,
      selectedId: profiles.any((profile) => profile.id == selected)
          ? selected
          : profiles.isEmpty
          ? null
          : profiles.first.id,
    );
  }

  final List<SigningProfile> profiles;
  final String? selectedId;

  SigningProfile? get selected => byId(selectedId);

  SigningProfile? byId(String? id) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'profiles': [for (final profile in profiles) profile.toJson()],
    'selected': selectedId,
  };
}

/// The saved profiles. They hold paths and choices; the passwords stay in
/// each `key.properties`.
final profilesProvider = NotifierProvider<ProfilesNotifier, ProfilesState>(
  ProfilesNotifier.new,
);

class ProfilesNotifier extends Notifier<ProfilesState> {
  @override
  ProfilesState build() {
    final saved = ref.read(settingsStoreProvider).read(SettingsKey.profiles);
    return saved == null
        ? const ProfilesState()
        : ProfilesState.fromJson(saved);
  }

  void _set(List<SigningProfile> profiles, String? selectedId) {
    state = ProfilesState(profiles: profiles, selectedId: selectedId);
    ref.read(settingsStoreProvider).write(SettingsKey.profiles, state.toJson());
  }

  /// A new id, unique among the profiles and their targets.
  String newId(String prefix) {
    final taken = {
      for (final profile in state.profiles) ...[
        profile.id,
        for (final target in profile.targets) target.id,
      ],
    };
    final base = '$prefix${ref.read(clockProvider)().microsecondsSinceEpoch}';
    var id = base;
    for (var copy = 2; taken.contains(id); copy++) {
      id = '$base-$copy';
    }
    return id;
  }

  Iterable<String> get _names => state.profiles.map((p) => p.name);

  /// Adds an empty profile and selects it.
  String create() {
    final profile = SigningProfile(
      id: newId('p'),
      name: uniqueProfileName('New profile', _names),
    );
    _set([...state.profiles, profile], profile.id);
    return profile.id;
  }

  /// Adds [profile] (from an import) as a new one and selects it. A name
  /// already in the list gets a number.
  String add(SigningProfile profile) {
    final added = profile.copyWith(
      id: newId('p'),
      name: uniqueProfileName(profile.name, _names),
    );
    _set([...state.profiles, added], added.id);
    return added.id;
  }

  void update(SigningProfile profile) => _set([
    for (final existing in state.profiles)
      existing.id == profile.id ? profile : existing,
  ], state.selectedId);

  String duplicate(String id) {
    final source = state.byId(id)!;
    final copy = source.copyWith(
      id: newId('p'),
      name: uniqueProfileName('${source.name} copy', _names),
    );
    final index = state.profiles.indexOf(source);
    _set([
      ...state.profiles.take(index + 1),
      copy,
      ...state.profiles.skip(index + 1),
    ], copy.id);
    return copy.id;
  }

  void delete(String id) {
    final profiles = state.profiles.where((p) => p.id != id).toList();
    final selected = state.selectedId == id
        ? (profiles.isEmpty ? null : profiles.first.id)
        : state.selectedId;
    _set(profiles, selected);
    ref.read(profileHistoryProvider.notifier).clear(id);
  }

  void select(String id) => _set(state.profiles, id);
}

/// Every profile's runs, newest first, kept across restarts. Names,
/// versions, paths and digests; never a password.
final profileHistoryProvider =
    NotifierProvider<ProfileHistoryNotifier, List<ProfileRunRecord>>(
      ProfileHistoryNotifier.new,
    );

class ProfileHistoryNotifier extends Notifier<List<ProfileRunRecord>> {
  /// The oldest runs go beyond this, so the settings stay small.
  static const limit = 200;

  static const _runs = 'runs';

  @override
  List<ProfileRunRecord> build() {
    final saved = ref
        .read(settingsStoreProvider)
        .read(SettingsKey.profileHistory);
    return [
      for (final json in saved?[_runs] as List<Object?>? ?? const [])
        if (json is Map<String, Object?>) ProfileRunRecord.fromJson(json),
    ];
  }

  void _set(List<ProfileRunRecord> runs) {
    state = runs.take(limit).toList();
    ref.read(settingsStoreProvider).write(SettingsKey.profileHistory, {
      _runs: [for (final run in state) run.toJson()],
    });
  }

  void add(ProfileRunRecord run) => _set([run, ...state]);

  void clear(String profileId) =>
      _set(state.where((run) => run.profileId != profileId).toList());

  List<ProfileRunRecord> of(String profileId) =>
      state.where((run) => run.profileId == profileId).toList();
}

/// What the target editor shows about a `key.properties`, read again when
/// the editor opens.
final keyFileSummaryProvider = FutureProvider.autoDispose
    .family<KeyFileSummary, String>(
      (ref, path) => ref.read(profileKeyServiceProvider).summarize(path),
    );

/// Everything checked before a run: the inputs read, the plan, and every
/// key opened.
class ProfileRunCheck {
  const ProfileRunCheck({
    required this.inputs,
    required this.plan,
    this.keys,
    this.keyFailure,
  });

  final List<ApkReport> inputs;
  final ProfileRunPlan plan;

  /// The opened keys, by `key.properties` path; `null` until the plan has
  /// no problem, or when one didn't open ([keyFailure] says which and why).
  /// They hold passwords: this check lives only while the Run dialog is
  /// open.
  final Map<String, OpenedKey>? keys;
  final ToolFailure? keyFailure;

  bool get canRun => plan.canRun && keys != null;
}

/// The check for running [profileId] on [inputs] (paths, one per line).
///
/// The keys open only once the plan has no problem, and only the keys its
/// jobs use. Nothing is signed here.
final profileRunCheckProvider = FutureProvider.autoDispose
    .family<ProfileRunCheck, ({String profileId, String inputs})>((
      ref,
      key,
    ) async {
      final profile = ref.watch(
        profilesProvider.select((state) => state.byId(key.profileId)),
      );
      if (profile == null) throw StateError('No profile ${key.profileId}.');
      final schemes = ref.watch(defaultsProvider.select((d) => d.schemes));
      final paths = key.inputs.isEmpty
          ? const <String>[]
          : key.inputs.split('\n');
      final inputs = [
        for (final path in paths)
          await ref.watch(apkReportProvider(path).future),
      ];
      final plan = planProfileRun(
        profile,
        inputs,
        defaultSchemes: schemes,
        host: ref.read(hostProvider),
        probe: ref.read(fileProbeProvider),
        date: ref.read(clockProvider)(),
      );
      if (!plan.canRun) return ProfileRunCheck(inputs: inputs, plan: plan);

      final keytool = (await ref.read(toolchainProvider.future)).keytool;
      if (keytool == null) {
        return ProfileRunCheck(
          inputs: inputs,
          plan: plan,
          keyFailure: const ToolFailure(
            'keytool was not found',
            details: ['Install a JDK, or set JAVA_HOME.'],
          ),
        );
      }
      final log = ref.read(logProvider.notifier);
      log.step('Check profile ${profile.name}');
      try {
        final keys = await ref
            .read(profileKeyServiceProvider)
            .open(
              ToolExecutor(ref.read(processRunnerProvider), log),
              keytool: keytool,
              keyFiles: {for (final job in plan.jobs) job.keyProperties}
                  .toList(),
            );
        return ProfileRunCheck(inputs: inputs, plan: plan, keys: keys);
      } on ToolFailure catch (failure) {
        log.error(failure.title);
        for (final line in failure.details) {
          log.error('  $line');
        }
        return ProfileRunCheck(inputs: inputs, plan: plan, keyFailure: failure);
      }
    });

/// The running (or last) profile run, for its progress list.
class ProfileRunState {
  const ProfileRunState({
    required this.profileId,
    required this.progress,
    this.record,
  });

  final String profileId;

  /// One entry per target and input, in the plan's order.
  final List<TargetProgress> progress;

  /// Set once the run has finished.
  final ProfileRunRecord? record;

  bool get running => record == null;

  int get finished =>
      progress.where((entry) => entry.stage == TargetStage.finished).length;
}

/// Where a run reports its progress. [ProfileRunNotifier] is the app's.
abstract interface class ProfileRunProgress {
  /// Every target of [plan], waiting.
  void start(String profileId, ProfileRunPlan plan, Host host);
  void update(TargetProgress progress);
  void finish(ProfileRunRecord record);
}

final profileRunProvider =
    NotifierProvider<ProfileRunNotifier, ProfileRunState?>(
      ProfileRunNotifier.new,
    );

class ProfileRunNotifier extends Notifier<ProfileRunState?>
    implements ProfileRunProgress {
  @override
  ProfileRunState? build() => null;

  @override
  void start(String profileId, ProfileRunPlan plan, Host host) =>
      state = ProfileRunState(
        profileId: profileId,
        progress: [
          for (final job in plan.jobs)
            for (final output in job.outputs)
              TargetProgress(
                target: output.target.name,
                input: host.path.basename(job.input.path),
                stage: TargetStage.waiting,
              ),
          for (final skipped in plan.skipped)
            TargetProgress(
              target: skipped.target.name,
              input: host.path.basename(skipped.input.path),
              stage: TargetStage.waiting,
            ),
        ],
      );

  @override
  void update(TargetProgress progress) {
    final current = state;
    if (current == null) return;
    state = ProfileRunState(
      profileId: current.profileId,
      progress: [
        for (final entry in current.progress)
          entry.target == progress.target && entry.input == progress.input
              ? progress
              : entry,
      ],
    );
  }

  @override
  void finish(ProfileRunRecord record) {
    final current = state;
    if (current == null) return;
    state = ProfileRunState(
      profileId: current.profileId,
      progress: current.progress,
      record: record,
    );
  }

  void dismiss() => state = null;
}
