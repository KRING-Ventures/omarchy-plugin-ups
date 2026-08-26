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

## Disabling loses your settings

`omarchy plugin disable <id>` removes the widget's entry from `shell.json`, and
for a third-party plugin that entry *is* the record that it is enabled — so the
inline settings go with it. Re-enabling gives you a bare entry and the widget
falls back to looking for a `upsd` on `127.0.0.1`, which for a network UPS means
it reports unreachable.

This is how Omarchy tracks third-party plugins, not something this plugin can
avoid. Note your `host` and `ups` before disabling, or keep a copy of the entry.

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
