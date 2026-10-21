import '../core/process/command.dart';
import '../domain/tools/java.dart';
import 'tool_executor.dart';

/// `java -version` → `21.0.10`. `null` when it can't tell.
Future<String?> readJavaVersion(ToolExecutor executor, String java) async {
  final result = await executor.run(
    Command(java, javaVersionArguments),
    echoOutput: false,
  );
  return result.succeeded ? parseJavaVersion(result.allLines) : null;
}
