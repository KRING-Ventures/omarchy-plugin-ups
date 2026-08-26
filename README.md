# UPS (`io.github.kring-ventures.ups`)

Omarchy shell bar widget for any UPS served by [NUT](https://networkupstools.org/)
(Network UPS Tools) — the same protocol WinNUT speaks on Windows. Works with a
locally attached USB UPS (via a local `upsd`) or a UPS with `upsd` built into the
hardware, such as the Ubiquiti UPS Tower.

## Install

```bash
omarchy plugin add https://github.com/KRING-Ventures/omarchy-plugin-ups
```

Then set `host` (and `ups`, if the server serves more than one) on the widget's
entry in `~/.config/omarchy/shell.json` — see Settings below.

## Requirements

None beyond bash. The poller (`ups-poll`) talks the NUT protocol directly over
`/dev/tcp`, so the `nut` client package does not need to be installed.

## What it shows

- **On mains power:** a plug glyph plus one metric (load % by default).
- **On battery:** a battery glyph that tracks charge, the remaining runtime, and
  the bar's accent colour.
- **Low battery / replace battery / shutdown pending:** a warning glyph.
- **upsd unreachable:** a broken-link glyph, dimmed.

Hover for the full readout: model, status, charge, runtime, load and watts, input
voltage, temperature, and the last self-test result.

Middle-click forces a poll. Any other click posts the readout as a notification.

## Notifications

One notification per state change — power lost, battery low, mains restored,
upsd unreachable — plus independently edge-detected alerts for "replace battery"
and "overloaded". Those two are tracked on their own flags rather than folded
into the power state, because a UPS can start asking for a new battery while it
is already running on battery, and that must not be swallowed.

Transitions are keyed on the underlying condition, not on the rendered label, so
a cosmetic change such as `OL` to `OL CHRG` is not reported as a power event.
"Mains power restored" is only sent when recovering from a state that was
actually announced.

Nothing fires on the first poll, so logging in during an outage does not
announce a transition that never happened.

## Failure handling

`ups-poll` always prints exactly one JSON object and always exits 0, so the
caller only ever parses one shape. Every run is bounded by a 6 second deadline:
bash cannot put a timeout on a `/dev/tcp` connect, and a host that drops SYNs
instead of refusing them would otherwise block for the kernel's SYN timeout —
over two minutes — during which the shell counts the poller as still running and
skips every later poll. Truncated replies (a list with no terminator) are
reported as errors rather than parsed as if complete.

## Auto-shutdown (opt-in)

Shut the machine down cleanly, or hibernate it, before the UPS battery runs out.
**Disabled by default** and it must be turned on explicitly.

> **Read this first.** This runs inside the Omarchy shell, which is a user
> session process. It is therefore *not* running when you most need it: machine
> asleep, logged out, session crashed, or this plugin itself erroring. For an
> unattended outage, use NUT's own `upsmon` — a system daemon that runs as root,
> survives logout, and executes `SHUTDOWNCMD` on `LB`/`FSD`. Treat this feature
> as the visible, cancellable convenience layer, not as your safety net.

```json
{
  "id": "omarchy-community.ups",
  "host": "192.168.1.50",
  "autoShutdown": {
    "enabled": true,
    "action": "shutdown",
    "runtimeBelow": 300,
    "confirmPolls": 2,
    "graceSeconds": 60
  }
}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `false` | Must be `true` for any of this to happen |
| `action` | `shutdown` | `shutdown` or `hibernate` |
| `command` | `""` | Run this instead of `systemctl`. Also how you test the feature without powering the machine off |
| `runtimeBelow` | `300` | Act at or below this many seconds of remaining runtime. `0` disables this trigger |
| `chargeBelow` | `0` | Act at or below this battery percentage. `0` disables this trigger |
| `onLowBattery` | `true` | Also act on the UPS's own `LB` flag, whatever the numbers say |
| `confirmPolls` | `2` | Consecutive agreeing polls required before arming |
| `graceSeconds` | `60` | Cancellable countdown. `0` acts immediately |

The UPS's `FSD` flag — upsd explicitly commanding a shutdown — always triggers,
regardless of the thresholds, and it also **bypasses `confirmPolls`**: waiting
`confirmPolls x interval` seconds to believe it could be most of the time the UPS
had left. The grace period still applies.

**Behaviour**

- Only ever arms while the UPS is reachable *and* running on battery.
- `confirmPolls` exists because a single spurious `battery.runtime` of 0 must
  never power the machine off. The count resets the moment a reading disagrees.
- While armed, the bar shows a warning glyph and a live countdown, and warnings
  are re-sent at 30s and 10s so a screen that was locked when it armed still
  shows something.
- Mains power returning cancels an in-progress countdown and re-arms for a
  future outage.
- Cancel by hand with
  `omarchy-shell omarchy-community.ups cancelShutdown`. That suppresses
  auto-shutdown until mains power returns — otherwise the trigger is still true
  on the next poll and the countdown just starts again. Undo with
  `resumeAutoShutdown`.
- Inspect the state machine any time with
  `omarchy-shell omarchy-community.ups shutdownStatus`.
- `action: "hibernate"` is resolved against what logind actually reports for
  `CanHibernate`. On a machine that cannot hibernate (no swap large enough, no
  `resume=`) it powers off instead and says so, rather than silently doing
  nothing.
- If upsd becomes unreachable *while a countdown is already running*, the
  countdown continues. A network blip and a dead UPS are indistinguishable from
  here, and shutting down cleanly is the safer of the two mistakes.

## Settings

Set these on the widget's entry in `~/.config/omarchy/shell.json`:

| Key             | Default       | Meaning                                              |
|-----------------|---------------|------------------------------------------------------|
| `host`          | `127.0.0.1`   | Address of the `upsd` server                         |
| `port`          | `3493`        | `upsd` port                                          |
| `ups`           | `""`          | UPS name; empty auto-detects the first one advertised |
| `interval`      | `10`          | Seconds between polls (minimum 2)                    |
| `display`       | `load`        | Mains-power metric: `load`, `charge`, `runtime`, `power`, `none` |
| `notifications` | `true`        | Notify on state changes                              |
| `hideWhenOnline`| `false`       | Only show the widget when something is wrong         |

```json
{
  "id": "io.github.kring-ventures.ups",
  "host": "192.168.1.50",
  "port": 3493,
  "ups": "myups",
  "interval": 10,
  "display": "load",
  "notifications": true
}
```

## Layout notes

`kinds` is `["service", "bar-widget"]`. A bar widget is instantiated once per
monitor, so all polling, state and notification lives in the service, which the
shell mounts exactly once — otherwise a multi-monitor setup polls `upsd` N times
and fires N notifications per power event.

The service reads its own settings out of `shell.json` rather than having the
widget push them in, because the service can mount before any widget does.

The service entry point deliberately sits in its own `service/` subdirectory.
Loading it from the plugin root failed with a Qt `File name case mismatch` error
in a shell process that had already loaded `Ups.qml` from that same directory.
