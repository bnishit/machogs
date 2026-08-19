# Driving machogs as an agent

Instructions for coding agents (Claude Code, Codex, Cursor, and friends) asked
to work out why a Mac is slow or its fan is loud.

## The tool

`machogs` inspects running processes and reports the ones worth closing. The
default process, disk, and port reports are read-only. Process and port actions
need an explicit `kill`; cache clearing needs `disk clear <path>` and is limited
to an engine allow-list of rebuildable caches and the Trash.

## Use this workflow

1. `machogs --json --sessions` — always start here. It closes nothing.
2. Read `findings`. **Each one carries a `story` — say that, close to verbatim.**
   It is already written for a person: it names the app to blame, what the thing
   is, and what it has cost. Do not translate a pid and a percentage yourself.
3. **Ask before closing anything.** Wait for the user to agree.
4. Then either:
   - hand control back with `machogs fix`, which asks the user about each item
     itself (best when the user is at the keyboard), or
   - `machogs kill --json` (add `--dupes` if duplicate servers are part of what
     the user agreed to) when you are acting for them.
5. Report what actually closed — re-read `findings` and check `action`. In
   plain (non-JSON) mode the tool prints a receipt: cores freed, CPU time
   already burned, what it would have cost by tomorrow. Pass that on. It is the
   part the user cares about, and the battery figure in it is an estimate —
   keep the hedge, do not promise a number.

Note: `machogs fix` needs a real terminal and will refuse to run without one.
Use `machogs kill` for unattended work.

## Never do these

- **Never run `kill` before the user has seen the findings and agreed.** A
  finding is a suggestion, not a verdict. Processes may hold unsaved work.
- **Never work around the protections.** If a process reads `protected`, the
  script is refusing on purpose — it belongs to a live Claude Code session.
  Do not kill it by hand with `kill -9` instead.
- **Never claim the machine is fixed because processes died.** If
  `host.swap_pct` is above 80, the machine is thrashing and only a reboot
  fixes it. Say so.
- **Never say idle findings were making the fan spin.** Check `cpu`. If
  everything found is near zero, they were wasting memory, not heating the
  machine. Say that instead — the user will notice if the fan does not change.
- **Never lower the thresholds to make findings appear.** `HOT_CPU` and
  `SPIN_CPU_SECONDS` exist for testing the detector. Lowering them in real use
  turns busy processes into false positives you will then kill.
- **Never clear a cache before showing the disk finding and asking.** Only pass
  back the exact path from a `safe` item. Never improvise a path, and never use
  `check` or `yours` items as deletion targets.
- **Never free a port before showing its owner, project, protections, and note.**
  A system or protected listener stays. If `note` explains a setting or service
  command, relay that instead of trying to kill the process.

## Exit codes

Enough to act on without parsing anything.

| Code | Meaning |
|---|---|
| `0` | clean, or a `kill` run that finished |
| `10` | report mode found something a human should look at |
| `2` | bad arguments |
| `3` | `disk clear` refused the path or found no target |

## JSON shape

`--json` prints exactly one object on stdout and nothing else.

```json
{
  "mode": "report",
  "host": {"load": 4.27, "cores": 10, "swap_used_mb": 13973.88,
           "swap_total_mb": 14336.00, "swap_pct": 97, "uptime_days": 20},
  "summary": {"reapable": 0, "killed": 0},
  "findings": [
    {"pid": 57377, "section": "2b", "action": "needs-dupes-flag",
     "cpu": 0.0, "cpu_seconds": 4, "age": "01:09:11",
     "owner": "ChatGPT", "what": "browser-control helper",
     "detail": "duplicate playwright-mcp under ChatGPT",
     "story": "ChatGPT quietly started 11 copies of the same browser-control helper. All idle, none cleaned up, oldest sitting there 1 hour."}
  ]
}
```

### `action`

| Value | What to do |
|---|---|
| `reapable` | `kill` would take this. Show it to the user first. |
| `needs-dupes-flag` | Only killed if you pass `--dupes`. Mention that. |
| `protected` | Refused on purpose. Leave it alone. |
| `never-killed` | A live Claude Code session. Report only. |
| `killed` | Actually reaped during this run. |

### `section`

| Id | Meaning |
|---|---|
| `1` | orphaned runaway — parent died, still burning CPU |
| `1b` | stuck spinner — parent alive, hours of CPU burned, still hot |
| `2` | leaked MCP server — owning app is gone |
| `2b` | duplicate MCP servers under one app |
| `3` | stranded headless browser |
| `4` | zombie app helper — app quit, helpers survived |
| `5` | Claude Code session — reported, never killed |

## Verifying the safety net

If a user doubts the tool, run `machogs --check`. It lists every automation
process and whether the script would refuse to kill it, and why. It kills
nothing. Anything owned by Claude Code must read `PROTECTED`.

## Reading the result honestly

`summary.reapable` counts what `kill` would take **in the mode you ran**.
Duplicate MCP servers are not counted unless `--dupes` was passed, so a run
reporting `reapable: 0` can still have findings worth showing the user. Read
`findings`, not just the summary.

## Other jobs worth surfacing

The report forms below are read-only. Their action forms are not.

- `machogs blame` — a scoreboard of which app leaves the most behind on this
  machine, built from the log over time. Useful when the user asks "why does
  this keep happening?"
- `machogs brag` — the same totals as a card the user can paste somewhere.
  Offer it only if they seem pleased; never push it.
- `machogs disk` (or `machogs disk --json`) — the read-only storage X-ray for
  "why is my disk full?". It measures the usual junk spots with a `verdict` per
  item: `safe`, `check`, or `yours`. Relay the `how` field. After explicit
  consent, `machogs disk clear <exact-safe-path>` clears one allow-listed cache
  or the Trash. The engine refuses all other paths. Takes about 15 seconds.
- `machogs ports` / `machogs port <n>` (both take `--json`) — who is squatting
  which port; the answer to "port 3000 already in use". `machogs port <n> kill`
  frees a port, with the usual refusals: `system: true` and noted launchd
  squatters (AirPlay's ControlCenter on 5000/7000 — relay the `note`, killing
  it does not stick) are never killed. `protected: true` means a live Claude
  Code session holds it; tell the user to quit it there. Ask before freeing a
  port, same as every other kill.

The log they read is `~/Library/Logs/machogs.log`, one tab-separated line per
close: time, pid, app to blame, what it was, CPU%, CPU seconds.
