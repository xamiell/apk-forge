import 'package:apk_forge/domain/profiles/key_properties.dart';
import 'package:apk_forge/state/profiles.dart';
import 'package:apk_forge/state/providers.dart';
import 'package:apk_forge/ui/profiles/profiles_view.dart';
import 'package:apk_forge/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

const _noKey = 'Choose its key.properties file.';
const _noFolder = 'Its output folder does not exist on this machine.';

/// A profile with one target that has no key, and one whose folder isn't
/// on this machine.
Map<SettingsKey, Map<String, Object?>> _saved() => {
  SettingsKey.profiles: {
    'profiles': [
      {
        'id': 'p1',
        'name': 'Release',
        'targets': [
          {'id': 't1', 'name': 'Phone', 'outputDir': '/out/phone'},
          {
            'id': 't2',
            'name': 'Kiosk',
            'keyProperties': '/keys/key.properties',
            'outputDir': '/out/kiosk',
          },
        ],
      },
    ],
    'selected': 'p1',
  },
};

void main() {
  late FakeFileProbe probe;

  Future<void> pumpProfiles(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1600, 1000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    probe = FakeFileProbe(
      files: {'/keys/key.properties'},
      directories: {'/out/phone'},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(
            MemorySettingsStore(_saved()),
          ),
          hostProvider.overrideWithValue(macHost),
          fileProbeProvider.overrideWithValue(probe),
          folderCreatorProvider.overrideWithValue(
            (path) async => probe.directories.add(path),
          ),
          keyFileSummaryProvider.overrideWith(
            (ref, path) async => KeyFileSummary(
              path: path,
              alias: 'upload',
              storeFile: 'upload.jks',
              keystorePath: '/keys/upload.jks',
              keystoreExists: true,
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: const Scaffold(body: ProfilesView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens [target] in the editor. Its button may be scrolled out of the
  /// table's view.
  Future<void> edit(WidgetTester tester, String target) async {
    final button = find.byTooltip('Edit $target');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Finder inSheet(Finder finder) => find.descendant(
    of: find.byKey(const ValueKey('target-sheet')),
    matching: finder,
  );

  testWidgets(
    'the list, the Targets step and the table show the same problems',
    (tester) async {
      await pumpProfiles(tester);

      // The profile in the list and the Targets step: a count, and the
      // reasons in the tooltip.
      expect(find.text('2 problems'), findsNWidgets(2));
      expect(
        find.byTooltip('Phone: $_noKey\nKiosk: $_noFolder'),
        findsNWidgets(2),
      );
      // The table writes each one out under its field.
      expect(find.text(_noKey), findsOneWidget);
      expect(find.text(_noFolder), findsOneWidget);
      expect(find.text('Create folder'), findsOneWidget);
    },
  );

  testWidgets('Edit target marks the field with the problem, and lists it', (
    tester,
  ) async {
    await pumpProfiles(tester);

    await edit(tester, 'Phone');

    // Under the key field, and in the footer.
    expect(inSheet(find.text(_noKey)), findsNWidgets(2));
    expect(inSheet(find.text(_noFolder)), findsNothing);
    // Saving stays possible: the path can be fixed later.
    expect(
      tester.widget<FilledButton>(inSheet(find.byType(FilledButton))).onPressed,
      isNotNull,
    );
  });

  testWidgets('a folder created from Edit target clears it everywhere', (
    tester,
  ) async {
    await pumpProfiles(tester);
    await edit(tester, 'Kiosk');
    expect(inSheet(find.text(_noFolder)), findsNWidgets(2));

    await tester.tap(inSheet(find.text('Create folder')));
    await tester.pumpAndSettle();

    expect(probe.directories, contains('/out/kiosk'));
    expect(find.text(_noFolder), findsNothing);
    expect(find.text('1 problem'), findsNWidgets(2));
  });
}
