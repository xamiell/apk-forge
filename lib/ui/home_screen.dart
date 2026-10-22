import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/devices.dart';
import '../state/profiles.dart';
import 'app_logo.dart';
import 'analysis/apk_panel.dart';
import 'build/build_card.dart';
import 'defaults/defaults_card.dart';
import 'device/device_panel.dart';
import 'install/install_card.dart';
import 'log/log_panel.dart';
import 'profiles/profiles_view.dart';
import 'signing/signing_card.dart';
import 'theme.dart';
import 'tools/toolchain_bar.dart';

/// The app's only window: the toolchain on top, and a rail to switch between
/// the Workbench (one-off work) and Profiles (setting up repeated work).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // List the devices once at launch; the Install panel refreshes on demand.
    Future.microtask(() => ref.read(devicesProvider.notifier).refresh());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final view = ref.watch(appViewProvider);
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            color: scheme.surface,
            child: Row(
              children: [
                const AppLogo(size: 26),
                const SizedBox(width: 10),
                Text(
                  'APK Forge',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Build · Sign · Analyze · Install',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: context.status.muted,
                    ),
                  ),
                ),
                const ToolchainBar(),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NavigationRail(
                  selectedIndex: view.index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (index) => ref
                      .read(appViewProvider.notifier)
                      .show(AppView.values[index]),
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.build_outlined),
                      selectedIcon: Icon(Icons.build_rounded),
                      label: Text('Workbench'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.layers_outlined),
                      selectedIcon: Icon(Icons.layers_rounded),
                      label: Text('Profiles'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: switch (view) {
                    AppView.workbench => const _Workbench(),
                    AppView.profiles => const ProfilesView(),
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The steps on the left (the defaults they share, build, sign, install),
/// and what came out of them on the right (the APKs' analysis and the log).
class _Workbench extends StatelessWidget {
  const _Workbench();

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        width: 420,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            DefaultsCard(),
            SizedBox(height: 16),
            BuildCard(),
            SizedBox(height: 16),
            SigningCard(),
            SizedBox(height: 16),
            InstallCard(),
          ],
        ),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              Expanded(
                flex: 11,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: ApkPanel()),
                    SizedBox(width: 16),
                    Expanded(flex: 2, child: DevicePanel()),
                  ],
                ),
              ),
              SizedBox(height: 16),
              Expanded(flex: 7, child: LogPanel()),
            ],
          ),
        ),
      ),
    ],
  );
}
