# Headroom (formerly Claude Usage)

macOS menu-bar app showing Claude and Codex usage limits (AppKit, zero
dependencies). Claude data comes from the authenticated usage API; Codex data
is reconstructed READ-ONLY from `~/.codex/sessions` rollout logs (never
`auth.json`, never the network).

## Gates (run both before handing a change back)

- `./build.sh`: canonical app build, plain `swiftc` over `Sources/*.swift`.
  That glob compiles EVERY file under `Sources/` into the app: keep them
  dependency-free and plain-swiftc-safe; fixtures and helpers go under
  `Tests/`, one-shot harnesses under `tools/`.
- `swift test`: unit gate via `Package.swift` (Sources minus `main.swift`).
  Includes pixel-parity corpora under `Tests/Fixtures/render-goldens/` that
  pin the renderer; regenerate only deliberately (README in that directory).

## Conventions and traps

- Comments explain WHY (constraints, reasoning), never what the next line does.
- The installed app in /Applications and dev builds in `build/` share the
  bundle id; a single-instance guard means you must quit one to run the other.
  Restore the installed app after manual checks.
- `design/` is gitignored by convention (design records, review archives).
- Rollout file/dir names are LOCAL time, timestamps UTC: order by mtime only.

## Status

Codex support is complete; the effort's records (package contract, plan,
amendments, review archives) live under `design/codex-support/`. Shipped as
Headroom v0.9 (2026-07-12): in-app rebrand, README rewrite, notarized release
on GitHub. v0.10 (2026-07-12) moved all options into a tabbed Settings window
(`Sources/SettingsWindow.swift`, records under `design/settings-window/`),
added the About tab, removed the menu-bar corner pip, and made the graph
projection follow the series ink. v0.10.1 (2026-07-13) keys Codex windows by
`window_minutes` instead of their `primary`/`secondary` position: OpenAI moved
the weekly window into `primary` and dropped `secondary` for some accounts on
2026-07-12, so the near-term slot is now OPTIONAL everywhere (single ring, sole
value promoted to the headline, severity and forecast keyed on the window that
exists). v0.11 (2026-07-13) adds the in-app updater
(`Sources/UpdateChecker.swift`, records under `design/update-mechanism/`):
daily GitHub releases check, verified in-place install (zip preflight,
Developer ID requirement, spctl gate, Applications-folder eligibility) and
relaunch; release invariants live in README's maintainer section, and
`tools/update_probe.swift` exercises the real verify/swap chain against a
scratch bundle. v0.12 (2026-07-31) adds Claude's model-scoped weekly caps
(`design/claude-scoped-limits/plan.md`): the usage endpoint now reports them in
a `limits[]` array while the legacy `seven_day_opus` / `_sonnet` /
`_omelette` fields sit null, so an account could be 2 points from a Fable
block while the app showed a calm weekly 82%. Caps become
`ProviderUsageSnapshot.extras` (worst-first, ids from the model name), the menu
rows are a dynamic pool, and the weekly ring gained an OPACITY channel:
`StatusRenderer.weeklyCalmAlpha` (0.5) at rest, solid when anything in the
weekly group is >= 90. That is achromatic on purpose — Monochrome and Accent
have no severity color, so every ink-based cue was invisible to them — and it
also settled a v0.8 split where the bar drew the weekly ring solid while the
panel drew it at 0.5. `Severity` (Providers.swift) is now the ONE threshold
predicate, evaluated on the DISPLAYED (rounded) percentage so a value printing
as "90%" can never render as calm. The render goldens were regenerated
deliberately; their README records the new baseline and the cell-by-cell proof
that only the weekly arc moved. Bundle id stays
`eu.smeingast.claude-menubar-usage` unless a migration is deliberately built:
it keys Application Support, defaults, the Keychain ACL, and the login item.
