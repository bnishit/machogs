# Driving machogs as an agent

Instructions for coding agents (Claude Code, Codex, Cursor, and friends) asked
to work out why a Mac is slow or its fan is loud.

## The tool

`machogs` inspects running processes and reports the ones worth killing. It
deletes no files. Report mode is the default; killing always requires an
explicit `kill` argument.

## Use this workflow

1. `machogs --json --sessions` — always start here. It closes nothing.
2. Read `findings`. Tell the user what you found in plain language: what the
   program is, how much CPU it is burning, how long it has been doing it.
   `detail` already names the app that left it behind — use that, not the pid.
3. **Ask before closing anything.** Wait for the user to agree.
4. Then either:
   - hand control back with `machogs fix`, which asks the user about each item
     itself (best when the user is at the keyboard), or
   - `machogs kill --json` (add `--dupes` if duplicate servers are part of what
     the user agreed to) when you are acting for them.
5. Report what actually closed — re-read `findings` and check `action`.

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

## Exit codes

Enough to act on without parsing anything.

| Code | Meaning |
|---|---|
| `0` | clean, or a `kill` run that finished |
| `10` | report mode found something a human should look at |
| `2` | bad arguments |

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
     "cpu": 0.0, "age": "01:09:11",
     "detail": "duplicate playwright-mcp under ChatGPT"}
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
