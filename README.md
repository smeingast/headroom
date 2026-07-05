<p align="center">
  <img src="assets/icon.png" width="120" height="120" alt="Claude Usage icon">
</p>

<h1 align="center">Claude Usage</h1>

<p align="center">
  A tiny native macOS menu-bar app that shows your current Claude usage as
  <b>5-hour</b> and <b>weekly</b> utilization.
</p>

It reads the OAuth token Claude Code already stores in your login Keychain and
polls the same usage data that powers Claude Code's `/usage` command. No servers,
no accounts, no config files, no telemetry. It talks only to Anthropic.

```
Menu bar:   ◍   concentric rings (default), or 14% / 4%, single ring, bars, ...

Dropdown:   ◎  5-hour  14%   resets 17:40 · in 3h 12m
                Weekly   4%   resets Sun 03:00 · in 6 days
            ●  At this pace the 5-hour window settles near 32%
               before it resets at 17:40. Plenty of headroom.
            [5h] [24h] [7d] [30d]              [Usage | Rate]
            ▁▂▄▆█▇▅▃▁▁▂▂▃ ┊ ╌╌╌●   history + forecast (hover for values)
            ─────────────
            2 ACTIVE SESSIONS
            ● claude-usage  Opus  ▂▂▂▂▂  125K
            ● vircampype    Opus  ▂▂▂▂▂  535K
            ─────────────
            Updated 14:26
            Refresh Now
            Display Style  ▸   Concentric rings · Single ring · Percentages · ...
            Color          ▸   Claude · Thresholds · Monochrome · Heatmap · ...
            ✓ Launch at Login
              Show Dock Icon
            ─────────────
            Quit
```

> **Unofficial.** Not affiliated with, or endorsed by, Anthropic. It relies on a
> private endpoint that Claude Code uses internally: undocumented, and liable to
> change or break without notice. It reads your local Claude Code OAuth token from
> the Keychain and sends requests only to `api.anthropic.com` and
> `console.anthropic.com`. Use at your own risk.

## Display styles & color

Pick how the two values look from the **Display Style** menu: concentric rings
(default; outer = 5-hour, inner = weekly), percentages, bars, twin rings, gauges,
pie slices, or segments.

![Display styles](assets/styles.png)

The **Color** menu controls how usage maps to color:

- **Claude** (default): Anthropic's coral, tuned for light / dark menu bars; red ≥ 90 %
- **Monochrome**: adapts to the menu bar (light / dark)
- **Thresholds**: normal, orange ≥ 70 %, red ≥ 90 %
- **Heatmap**: green to red as usage climbs
- **System accent**: your macOS accent color

## Usage history & forecast

The dropdown draws an inline graph of past usage; hover it for exact values and
timestamps. In **Usage** mode the right edge of the plot looks ahead to the
5-hour reset: the last hour's burn rate is projected forward as a dotted run,
turning amber (with a red dot at the crossing) when the pace would reach 100%
before the reset — the same projection the banner sentence and the faint ghost
arc on the menu-bar rings are built from. **Rate** mode shows how fast each
window is filling. Ranges (last 5h / 24h / 7d / 30d) and the mode switch sit as
pills directly above the graph. Samples are kept locally in a small append-only
file and trimmed after about a month, so nothing leaves your Mac.

## Requirements

- Apple Silicon Mac, macOS 13 (Ventura) or later.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and
  **signed in**. That is what creates the Keychain item the app reads.

## Install

### Download (recommended)

Grab the latest **notarized** build from the
[Releases page](https://github.com/smeingast/claude-usage/releases/latest), unzip,
and drag **Claude Usage.app** to `/Applications`. It is signed with a Developer ID
and notarized by Apple, so it opens with no Gatekeeper warning.

### Build from source

Needs the Swift toolchain (Xcode, or Command Line Tools via `xcode-select --install`):

```sh
./build.sh              # build/Claude Usage.app  (ad-hoc signed)
./build.sh --install    # also copies to /Applications and clears quarantine
```

The result is a self-contained `.app` that uses only system frameworks. It is
deliberately light: one status item and a roughly 5-minute poll (plus an on-demand
refresh when you open the menu) with rate-limit backoff.

<details>
<summary><b>Maintainer: cutting a notarized release</b></summary>

With a **Developer ID Application** certificate installed, `build.sh` signs with a
hardened runtime automatically. To produce and zip the notarized, stapled `.app`:

```sh
./tools/notarize_setup.sh   # one-time: store Apple notary credentials in the keychain
./build.sh --notarize       # sign, submit to Apple, staple, verify
ditto -c -k --keepParent "build/Claude Usage.app" "build/Claude-Usage-v0.1.zip"
```

`build.sh` does not bundle the versioned zip itself, hence the `ditto` step.
`notarize_setup.sh` needs an **app-specific password** (account.apple.com,
Sign-In and Security). Your Apple ID and Team ID live only in the keychain and
never touch the repo.
</details>

## First run

- **Keychain prompt: normally none.** The app reads the shared credentials the
  same way Claude Code itself does, which macOS allows silently. If macOS ever
  does ask (unusual setups), click **Always Allow** once.
- **Can't see it?** A menu-bar manager (Bartender, Ice, and similar) may be hiding
  it. Reveal the hidden section and ⌘-drag the item where you want it.

## How it works

| Piece | Detail |
|-------|--------|
| Data source | `GET /api/oauth/usage`: `five_hour.utilization`, `seven_day.utilization` (plus model-specific weekly caps when in use) |
| Auth | OAuth token shared with Claude Code (Keychain service `Claude Code-credentials`), read silently and cached in memory. The token is refreshed only as a last resort and **never while any Claude Code process is running** — the refresh token is single-use, so spending it would log a live Claude Code out. While one runs, the app adopts whatever fresh token Claude Code writes |
| Active sessions | Live Claude Code sessions **on this Mac** — project, model, status, and context tokens — read from `~/.claude/sessions/*.json` and each session's transcript tail. Local only, no network; undocumented internal state, so liable to change between CLI versions |
| Usage history | Inline graph of past 5-hour and weekly utilization (or fill rate), spanning the last 5h to 30d. Sampled on each successful poll into an append-only file under Application Support, trimmed to about 32 days. Local only |
| Display | `NSStatusItem` rendered as text or a drawn glyph: 8 styles × 5 color modes, with an optional forecast ghost arc on the ring styles |
| Footprint | Menu-bar only (`LSUIElement`); optional Dock icon; launch-at-login via `SMAppService` |

## Project layout

```
Sources/
  main.swift           App entry + single-instance guard
  AppDelegate.swift    Status item, menu, polling
  StatusRenderer.swift Display styles + color modes (text / drawn glyphs)
  Forecast.swift       Burn-rate projection + the panel's derived state
  PanelViews.swift     Custom menu rows: header rings, banner, sessions, pills
  UsageClient.swift    Usage fetch + token refresh
  Keychain.swift       Read/write the shared Claude Code credentials
  LoginItem.swift      Launch-at-login via SMAppService
Resources/
  Info.plist           Bundle manifest (LSUIElement = menu-bar only)
  AppIcon.icns         App icon
assets/                README images (icon, styles strip)
tools/
  icongen/main.swift   Renders the icon
  make_icon.sh         Builds AppIcon.icns
  notarize_setup.sh    One-time: store Apple notary credentials (see Install)
build.sh               Compile, bundle, sign, optionally notarize and install
```

## License

[MIT](LICENSE). Free to use, modify, and distribute. Provided **as is**, with no
warranty and no liability; use at your own risk.
