import '../core/process/command.dart';
import '../domain/tools/bundletool.dart';
import '../domain/tools/toolchain.dart';
import 'tool_executor.dart';

/// `bundletool version` → `1.18.3`. `null` when it can't tell, or without
/// bundletool.
Future<String?> readBundletoolVersion(
  ToolExecutor executor,
  Toolchain toolchain,
) async {
  final launch = toolchain.bundletoolLaunch;
  if (launch == null) return null;
  final result = await executor.run(
    Command(launch.executable, bundletoolVersionArguments(launch.arguments)),
    echoOutput: false,
  );
  return result.succeeded ? parseBundletoolVersion(result.stdout) : null;
}
