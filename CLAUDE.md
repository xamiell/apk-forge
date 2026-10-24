# CLAUDE.md

- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
  [docs/TESTING.md](docs/TESTING.md) before a change. The dependency rule
  (`ui → state → services → domain → core`) and the secrets rules (§3) are
  not optional.
- Check every change against ARCHITECTURE's "Every change" list (§12). A
  rule the code can't follow yet goes under its Known deviations (§14), with
  the reason.
- Plain classes take their dependencies in the constructor, never `ref`;
  rules live in `domain/` or `state/`, never in a widget.
- Everything is in English: UI, code, comments, docs, commits.
- A new external command goes through `ProcessRunner` via `ToolExecutor`,
  and its arguments come from a pure builder in `domain/` with a test.
- A new tool output gets a real captured fixture in `test/fixtures` (listed
  in its README) and a parser test against it. Never a hand-written guess.
- Passwords never go in arguments, logs, settings or errors.
- Before finishing: `dart format .`, `dart analyze lib test tool` (no
  issues), `flutter test`.
- Commits follow Conventional Commits (`feat(sign): …`, `fix(analyze): …`).
