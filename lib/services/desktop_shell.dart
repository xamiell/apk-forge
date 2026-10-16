import 'dart:io';

import '../core/system/host.dart';

/// Shows [path] in the OS file manager, selected where the OS allows it.
Future<void> revealInFileManager(String path, Host host) async {
  switch (host.os) {
    case HostOs.macos:
      await Process.run('open', ['-R', path]);
    case HostOs.windows:
      await Process.run('explorer', ['/select,', path]);
    case HostOs.linux:
      await Process.run('xdg-open', [host.path.dirname(path)]);
  }
}
