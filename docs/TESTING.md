# Testing

The unit tests run on any machine with Flutter, with no Android SDK, device
or network. Everything that decides something is plain Dart (see
[ARCHITECTURE.md](ARCHITECTURE.md)), so the tests drive it with fakes at the
boundaries and real tool output captured once.

## What is tested, and how

| Layer | Tested with | Where |
|---|---|---|
| `core/` | Unit tests: ZIP reading and copying on temporary files, formatting, the shell environment, when a command starts through the shell. | `test/core` |
| `domain/` | Unit tests: parsers against real captured output, command builders, findings, comparisons, plans, the models' JSON. The MCP protocol: what each message gets, what the HTTP side refuses, and the tools' arguments and JSON (`mcp_test`). | `test/domain` |
| `services/` | Each service over `FakeProcessRunner`, with real captured output as the tools' answers. `McpHttpServer` has no unit test: what it refuses and answers is decided in `domain/mcp` and tested there, and the listener itself was checked with `curl` (#10). | `test/services` |
| `state/` | Each action built directly with fakes (`actions_test`). The MCP tools built with closures, and the server's notifier with its starter overridden (`mcp_test`). The notifiers and the providers' wiring through a `ProviderContainer` (`state_test`), the MCP tools included. What each setting saves (`settings_test`). | `test/state` |
| `ui/` | Checked by hand on macOS, every screen a change touches. Widget tests only where one rule must show the same way on several screens: a target's problems in the Profiles list, the Targets step and table, and Edit target. | `test/ui` |
| The real tools | `tool/smoke.dart`, end to end against a throwaway project and keystore (see the README's Development section). | `tool/` |

## Rules for every test

A test is only worth having if both its pass and its failure mean
something. Each test:

1. **Fails when the behavior breaks.** A bug fix starts with a test that
   fails. For new code, break the code once and watch the test catch it.
2. **Is deterministic.** It doesn't use the wall clock, the real tools, the
   network or an unseeded random, and it doesn't return early on some hosts.
   It writes only to its own temporary directory.
3. **Is isolated.** It builds its own state and deletes it, and the order
   the tests run in doesn't matter.
4. **Goes through the code's public behavior.** It fakes the boundaries,
   never the class under test.
5. **Asserts something real:** a value, a state, a command that ran, a line
   logged. "Doesn't throw" is asserted explicitly.
6. **Reads as a specification.** It tests one behavior and is named for it.
   It arranges, acts, then asserts.
7. **Is fast.** Time is never waited for.

## A fake for each boundary

There is no mocking library: every double is a small fake, in
`test/helpers/fakes.dart` unless noted.

| Boundary | In tests |
|---|---|
| The tools (processes) | `FakeProcessRunner` answers from rules (`whenFirstArg`, `when`) and records every call (`calls`, `callsWithFirstArg`). |
| What a tool prints | `fixture('<file>.txt')`: real output, captured once and listed in [test/fixtures/README.md](../test/fixtures/README.md). |
| The log | `RecordingLog` keeps every line, prefixed by its kind (`info: …`). |
| The file system | `FakeFileProbe` answers "does it exist?" from the paths it's given. For real files, a temporary directory (`Directory.systemTemp.createTempSync`) deleted in `tearDown`. `writeApk` writes a small APK with native code for the ABIs it's given. |
| The OS | A `Host` value: `macHost`, or `Host(os: HostOs.windows, …)`. |
| The settings | `MemorySettingsStore`, keyed by `SettingsKey`. `SharedPreferences.setMockInitialValues` for the real store. |
| The clock | An override of `clockProvider`, or a `DateTime Function()` given to the class. |
| The current task | `FakeTaskRunner` runs the task's body at once and keeps its `failure`, `labels` and `log`. Set `isRunning` to pretend another task runs. |
| The APK list | `RecordingApkSink` records what was listed and selected. |
| A profile run's progress | `_RecordingProgress` in `test/state/actions_test.dart`. |
| The OS file manager | An override of `fileRevealerProvider`, or a function given to the action. |
| Creating a folder | An override of `folderCreatorProvider` that adds the path to a `FakeFileProbe`. |
| A `key.properties` read | `keyFileSummaryProvider.overrideWith((ref, path) async => KeyFileSummary(…))`. |
| The MCP server's port | An override of `mcpServerStarterProvider` that records the port and the token, and returns a stop that records too. `mcpTokenMakerProvider` gives known tokens. |
| What the MCP tools call | Closures given to `ProfileMcpTools`, recording what they're asked, the user's Allow or Decline included (`_Tools` in `test/state/mcp_test.dart`). |
| The user allowing an agent's run | `McpRunRequestNotifier.answer`, called by the test, or from a `container.listen` on `mcpRunRequestProvider` (`state_test`). |

## Recipes

- **A service.** Build it with a `FakeProcessRunner` that answers like the
  tool, for example `runner.whenFirstArg('verify',
  ok(fixture('apksigner_verify_test_key.txt')))`. Assert the commands it ran
  and what it returned or threw.
- **A new tool output.** Capture it from the real tool into `test/fixtures`,
  list it in that folder's README (the command and the input), and test the
  parser against it. Never write one by hand.
- **An action.** Build it directly, with a `FakeTaskRunner`, a
  `RecordingApkSink`, the real services over `FakeProcessRunner`, and
  closures for what it reads. Assert the commands, what it listed,
  `task.failure` and `task.log.lines`.
- **A notifier, or a provider's wiring.** Use
  `ProviderContainer.test(retry: (_, _) => null, overrides: […])`. Override
  the boundary providers (the runner, the host, the settings, the
  toolchain) and keep the real notifiers. Act through the notifier, then
  assert the state and what was saved.
- **A new setting.** Add it to `savedByThisVersion()` in
  `test/state/settings_test.dart`. Its tests check that the setting comes
  back and saves to the same map.
- **A widget test.** Pump the real view in a `ProviderScope` with the
  boundaries overridden, inside a `MaterialApp` with `buildTheme`. Set
  `tester.view.physicalSize` to a desktop window and reset it in
  `addTearDown`. Call `tester.ensureVisible` before tapping something a list
  or table may have scrolled away. Look for text inside one panel with
  `find.descendant` and a `ValueKey` on that panel.
- **A secret.** Assert that the password is in none of these: the log, the
  settings, the history or the error (`isNot(contains(secret))`).
- **A new MCP tool.**
  - Add it to `profileTools`, with its arguments read and its JSON built
    in `domain/mcp`, and test both there.
  - Test its handler in `ProfileMcpTools` with closures: what it calls, what
    it refuses, and that its answer holds no password.

## Running

```bash
dart format .
dart analyze lib test tool
flutter test
```

CI runs the same checks on every pull request and on every push to `main`
and `develop`.
