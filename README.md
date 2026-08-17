# mac-cleanup

Your Mac's fan is loud. Activity Monitor shows a wall of processes and nothing
obviously wrong. Something is spinning and you have no idea what.

`mac-cleanup` finds it, tells you what it is, and only kills it if you say so.

It was written after a plugin server sat at 90% of a CPU core for **four days**
without anyone noticing — 91 hours of CPU burned by a process nobody was
talking to anymore.

```
$ mac-cleanup

=== mac-cleanup ===  mode: report

System
  load 10.74 on 10 cores
  swap 16080M / 17408M (92%)  <- thrashing, reboot to clear
  uptime 20 days, 19:08

1. Orphaned runaways  (parent died, still burning CPU)
  none

1b. Stuck spinners  (parent alive, but burning CPU for hours)
    69342   cpu=98.7% age=04-01:37     spinning 91h23m of CPU — bun [~/.claude/plugins/telegram]
    69340   cpu=0.0%  age=04-01:37       idle wrapper of 69342 (bun)

2b. Duplicate MCP servers  (same app spawned many, keeps newest)
    57377   cpu=0.0%  age=01:00:03     duplicate playwright-mcp under ChatGPT (--dupes to kill)
    75904   cpu=0.0%  age=16:05        duplicate playwright-mcp under ChatGPT (--dupes to kill)

Found 4 reapable process(es). run mac-cleanup kill to clean up.
```

## This will not eat your homework

It sends `kill -9`. That deserves your suspicion, so here is exactly what stops
it hurting you:

- **Report mode is the default.** Plain `mac-cleanup` never kills anything.
  `kill` is always typed out by you.
- **It will never kill a coding session.** Claude Code sessions are listed and
  explicitly skipped, along with every MCP server belonging to a live one. You
  do not lose unsaved work.
- **It will never kill its own ancestry.** The script cannot shoot the shell
  it is running in.
- **It touches only your own processes.** Root-owned system daemons
  (`WindowServer`, `kernel_task`, Spotlight, Time Machine) are out of scope.
- **Things that pin a core for a living are exempt** — `ffmpeg`, HandBrake,
  Compressor and friends are on a never-touch list.
- **Every kill is logged** to `~/Library/Logs/mac-cleanup.log`.

You can audit the safety net yourself, without killing anything:

```sh
mac-cleanup --check
```

That lists every automation process on the machine and whether the script would
refuse to kill it, and why. Anything owned by Claude Code must read `PROTECTED`.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/bnishit/mac-cleanup/main/mac-cleanup -o /usr/local/bin/mac-cleanup
chmod +x /usr/local/bin/mac-cleanup
```

Or just clone and copy it anywhere on your `PATH`. It is a single bash file with
no dependencies — everything it uses (`ps`, `lsof`, `pgrep`, `sysctl`) ships
with macOS. Works on bash 3.2, the version Apple still bundles.

To uninstall: delete the file.

## Usage

```sh
mac-cleanup                 # report only — the default, kills nothing
mac-cleanup kill            # kill the safe categories
mac-cleanup kill --dupes    # also kill duplicate MCP servers
mac-cleanup --sessions      # also list idle Claude Code sessions
mac-cleanup --check         # audit the safety net, kill nothing
```

## What it looks for

| | Category | What it means |
|---|---|---|
| 1 | Orphaned runaways | Parent died, process still burning CPU |
| 1b | Stuck spinners | Parent alive, but hours of CPU burned and still hot |
| 2 | Leaked automation servers | MCP servers whose owning app is gone |
| 2b | Duplicate MCP servers | One app spawned the same server over and over |
| 3 | Stranded headless browsers | Headless Chrome with no live owner |
| 4 | Zombie app helpers | Cursor/VS Code/Electron helpers left after quitting |
| 5 | Claude Code sessions | Reported only, never killed |

## Why it knows about MCP servers

Most "clean your Mac" scripts delete caches. This one does not touch a single
file — it looks at what is *running*.

That matters more than it used to. AI coding tools spawn background servers
constantly, and they leak. On the machine this was written on, ChatGPT had
piled up **28 duplicate MCP servers** in an afternoon, and had three more
within the hour of being cleaned. Nothing else looks for that.

## How it decides something is stuck

The interesting case is category 1b, and it is worth explaining because it is
where the naive check fails.

The obvious way to spot a runaway is to ask *"did its parent die?"* — an
orphaned process pegging the CPU is clearly abandoned. That check is real, and
it is category 1.

But it misses the worst case. A process can spin forever under a perfectly
healthy parent. Nothing is orphaned, so parentage tells you nothing, and the
naive check walks straight past a core burning at 100%. That is exactly what
hid for four days.

So 1b asks a different question: **has this burned hours of CPU, and is it
still hot right now?** Both must be true. A compile burns minutes of CPU and
finishes. A spin loop burns hours and never stops. The default line is 4 hours
of accumulated CPU while still above 50% — generous enough that ordinary hard
work never trips it.

When it finds a spinner, it also takes the parent, but only when the parent is
plainly a leftover wrapper: orphaned itself, and doing nothing. Otherwise a
supervisor would just restart the thing you killed.

Both thresholds are environment variables, so you can test the detector without
waiting four hours for a real spinner:

```sh
HOT_CPU=95 SPIN_CPU_SECONDS=5 mac-cleanup
```

## What it will not fix

If it tells you swap is 90% full, believe it. Killing processes barely helps at
that point — the memory is already paged out to disk. A reboot is the only real
fix, and the script says so rather than pretending otherwise.

## License

MIT
