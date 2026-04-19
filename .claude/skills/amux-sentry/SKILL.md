---
name: amux-sentry
description: Use when investigating live iOS issues, crashes, hangs, or traces for the AMUX/TeamClaw iOS app via the sentry CLI. Complements asc-crash (App Store Connect diagnostics) with real-time Sentry event data.
---

# AMUX Sentry Reader

Reads issues, events, and traces from the AMUX iOS app's Sentry project. Real-time counterpart to `asc-crash`, which only sees App Store-sampled crashes.

## Project Coordinates

- **Organization:** `ucar-inc` (id `60909`)
- **Project:** `teamclaw-ios` (id `4511233545011200`)
- **Issue short IDs:** `TEAMCLAW-IOS-<n>`
- **DSN (ingest only, for reference):** `https://7551f3236520b84b27ec473a1d7c1480@o60909.ingest.us.sentry.io/4511233545011200` — defined in `ios/AMUXApp/AMUXApp.swift`.

The `sentry` CLI auto-detects this from the DSN in the source tree, so explicit `ucar-inc/teamclaw-ios` flags are usually unnecessary from inside the repo.

## Prerequisites

- `sentry --version` should be `0.26+`.
- `sentry org list` should include `ucar-inc`. If not, run `sentry login` with an account that has access to the org.

## Common reads

### Latest unresolved issues

```bash
sentry issue list ucar-inc/teamclaw-ios --query "is:unresolved" --limit 10 \
  --json --fields shortId,title,level,status,firstSeen,lastSeen,count,userCount
```

### Drill into one issue

```bash
sentry issue view TEAMCLAW-IOS-<n>
sentry issue explain TEAMCLAW-IOS-<n>    # AI root-cause summary
sentry issue plan TEAMCLAW-IOS-<n>       # AI fix plan
```

### Individual events for an issue (device, OS, stack, breadcrumbs)

```bash
sentry issue events TEAMCLAW-IOS-<n> --limit 5 --json
```

Each event carries `tags` (device model, OS version, app.version, `release`), `user` (anonymised), and `entries` with a stack trace.

### Filter by release

```bash
sentry issue list ucar-inc/teamclaw-ios \
  --query "release:ios-v1.0.4-rc21" --limit 20 --json \
  --fields shortId,title,level,count
```

Release tags follow the `ios-v*` pattern set by the Fastlane CI.

### Search by time window

```bash
sentry issue list ucar-inc/teamclaw-ios \
  --query "is:unresolved age:-24h" --limit 20 --json \
  --fields shortId,title,count,lastSeen
```

Age supports `m`/`h`/`d` (minutes/hours/days).

### Traces + logs (performance)

```bash
sentry trace list ucar-inc/teamclaw-ios --limit 5
sentry trace view <trace-id>
sentry trace logs <trace-id>
```

Useful when MQTT or HTTP calls look slow — the Sentry Swift SDK already records `enableAutoPerformanceTracing`.

## Known-issue catalog

Keep a short mental map so repeat symptoms are one lookup away:

| Short ID | Area | Hint |
| --- | --- | --- |
| `TEAMCLAW-IOS-1` | VoiceRecorder | `IsFormatSampleRateAndChannelCountValid(format)` — `AVAudioEngine` started with an invalid input format. Usually means no active `AVAudioSession.setCategory(.record, ...)` or the mic was unavailable (AirPods switching, etc.). See `ios/Packages/AMUXCore/Sources/AMUXCore/Voice/VoiceRecorder.swift:102`. |
| `TEAMCLAW-IOS-2` | Main thread | App Hanging ≥2000ms — check `AgentDetailViewModel.handleAcpEvent` hot path, SwiftData saves, markdown parse. |

Add rows here when investigating a new issue so future sessions skip the rediscovery.

## Cross-reference

For anything beyond these recipes — `sentry span`, `sentry release`, mutation commands like `sentry issue resolve`, or one-off API calls via `sentry api …` — consult the general `sentry-cli` skill (installed at `~/.claude/skills/sentry-cli/SKILL.md`).
