# machogs 🐷

**Your Mac is slow, hot, and loud. This tells you what is doing it, in plain English.**

**[Website](https://bnishit.github.io/machogs/)** · free · one bash file · zero dependencies · MIT

```
$ machogs

  🐷 Found the hog. Caught in 4K. Receipts below.

  🔥 bun — left by a Claude Code plugin
  Eating 98% of a CPU core. Running for 4 days.
  It is stuck in a loop. Nothing is waiting for it.

  This is why your Mac feels slow, runs hot, spins its fan,
  and loses battery faster than it should.

  To go through them one at a time:  machogs fix
  Nothing is closed unless you say yes.
```

That one is real, no cap. It ran for four days at ninety percent of a CPU
core. It burned 91 hours of processor time. Nobody opened it, nobody used it,
and nothing on the machine said a word about it. Caught in 4K.

What it catches: 🔥 stuck spinners cooking your CPU · 👯 clone armies (one app,
28 copies of the same helper) · 👻 ghost browsers nobody is looking at ·
🧟 zombie helpers that survived their app · 🧠 memory squatters · 🌡️ and the
honest diagnosis when only a restart will fix it.

---

## Why is my Mac fan so loud?

Almost always: one program is stuck using a whole CPU core. The fan is not
broken. It is doing its job, cooling a chip that something is cooking.

The hard part is that the program is usually one you never opened and cannot
name. In Activity Monitor it shows up as `bun`, or `node`, or `Helper (Renderer)`.
Those names tell you nothing, so most people scroll past and reboot instead.

`machogs` finds it and tells you what it actually is and which app left it there.

## Why is my MacBook so hot?

Same cause, different symptom. A chip running flat out gets hot, and the metal
case passes that heat to your hands. If your Mac is hot while you are only
writing an email, something is running that you did not ask for.

## Why is my battery draining so fast?

A stuck program does not sleep. It keeps a CPU core awake, which stops your Mac
from entering its low-power states. The battery estimate drops from nine hours
to three, and nothing on screen explains it.

Battery drain is often the first thing people notice. It is the same problem as
the loud fan, arriving through a different door.

## Why is my Mac suddenly slow?

Two different causes, and it is worth knowing which one you have:

1. **Something is eating the CPU.** `machogs` finds this and can fix it.
2. **You have run out of fast memory.** Your Mac starts shuffling memory to
   disk. Everything gets slow and stays slow. Closing programs barely helps.

`machogs` checks both and tells you which one you are looking at. If it is the
second one, it says so plainly: restart, because nothing else fixes it.

---

## The part that is new

Your Mac used to run the programs you opened. That is no longer true.

Today it runs the programs you opened, the helpers those programs started, the
AI assistants you gave access to, and the background servers those assistants
start so they can search the web and read your files. You did not open any of
them. You cannot name them. Most of them you will never see.

They also leak. On the machine this was written on, ChatGPT left **28 duplicate
background servers** running in a single afternoon. They were cleaned up, and
eleven more appeared within the hour. A plugin from an old version of Claude
Code kept running for four days after the thing that started it had gone.

None of this is anyone's fault exactly. Every AI tool spawns helpers, most clean
up correctly most of the time, and the failures are quiet. But the result is a
new kind of slow computer: not old, not full, not broken — just quietly busy
with work nobody asked for.

Every "clean your Mac" tool ever written deletes caches to free disk space. That
solves a problem from 2010. `machogs` deletes nothing. It looks at what is
*running*, and it knows the names of the AI tools that leave things behind.

---

## Why is my Mac storage full?

The CPU has hogs; the disk has dead weight. `machogs disk` is the storage
X-ray — same promise as everything else here: find it, explain it in plain
English, and **delete nothing**. You decide; it points.

```
$ machogs disk

💾 Your disk: 338 GB used of 460 GB (73% full).

  📦 App caches — 21 GB. Safe to clear: Apps rebuild these.
  📦 npm cache — 13 GB. Safe to clear: npm rebuilds it.
  🛠️ Old iPhone debug files — 6.5 GB. Check first: dead weight per old iPhone.
  ⬇️ Downloads — 4.8 GB. Your call: You know what is in there.

machogs deletes nothing. It shows you where the weight is; you decide.
```

It checks the usual junk spots — Trash, app caches, Xcode build junk, old
iPhone backups, Docker's disk image, simulators, npm cache, Downloads — and
only mentions what is actually chunky (0.5 GB+). If the junk spots are clean,
it says the honest thing: the space is going to your real files.

---

## Port 3000 is already in use — by what?

The error every dev knows, and it never says WHO. Now it does:

```
$ machogs port 3000

  :3000  node in ~/dev/my-app — running 3 hours

Free it:  machogs port 3000 kill
```

`machogs ports` lists everything listening, in plain words — including the
two famous squatters people google for hours: macOS's own AirPlay Receiver
sitting on ports 5000 and 7000 (machogs names it and points at the setting
that turns it off, because killing it does not stick), and `rapportd`, which
is harmless and should be left alone. The same safety rules apply: it will
name a system process rather than kill it, and it will never kill a server
belonging to a live Claude Code session — it tells you to quit it there.

---

## Install

```sh
brew install bnishit/tap/machogs
```

Or without Homebrew — it is one bash file:

```sh
curl -fsSL https://raw.githubusercontent.com/bnishit/machogs/main/machogs -o /usr/local/bin/machogs
chmod +x /usr/local/bin/machogs
```

No dependencies. Everything it uses ships with macOS. To uninstall, delete the
file (or `brew uninstall machogs`).

Or skip all of this and paste one line to any AI that has a terminal —
Claude Code, Codex, Cursor:

> Install machogs from github.com/bnishit/machogs, read its AGENTS.md, then
> tell me what is hogging my Mac. Don't close anything without asking.

## Use

```sh
machogs              # plain answer. Closes nothing.
machogs fix          # go through them one at a time, asking before each
machogs blame        # scoreboard: which app leaves the most junk behind
machogs brag         # a shareable card of what your Mac has been wasting
machogs disk         # where your storage went. Deletes nothing.
machogs ports        # every port in use and who is squatting it
machogs port 3000    # who holds port 3000; add `kill` to free it
machogs --details    # the technical report, by category
machogs --json       # machine-readable, for agents
machogs --check      # audit the safety rules, close nothing
```

## Closing something should feel like a win

Killing a process is an event. Getting a CPU core back is a result. Same
action, and only one of them is worth telling anyone about:

```
🎉 Closed 1 program.
You just got back 1.0 of a CPU core that nothing was using.
They had already burned 91 hours of processor time.
⚡ The electricity they wasted could have charged your phone about 36 times.
Left alone, they would have burned 23 hours more by this time tomorrow.
Roughly an hour or two of battery back, depending on your Mac.
```

The battery and phone-charge lines are estimates and say so. The rest is
measured.

## Who is the worst offender on your machine

Every close is logged, so over weeks the log becomes a scoreboard — a fact
only your own machine can tell you:

```
$ machogs blame

Who leaves the most junk on your Mac
since 2026-08-17

  APP                          CLOSED   CPU TIME WASTED
  ChatGPT                          39   2 hours 👑
  a Claude Code plugin              1   91 hours
```

And `machogs brag` prints the same thing as something you can paste:

```
  ---------------------------------------------
   🐷 my mac was doing 93 hours of work
   for programs i never opened.

   40 background programs closed
   worst offender: ChatGPT (39 of them)
   single worst: 91 hours burned by one process
   wasted power ≈ 37 phone charges ⚡

   caught in 4k by machogs
   github.com/bnishit/machogs
  ---------------------------------------------
```

`machogs fix` shows you one thing at a time and waits:

```
1 of 1
  👯 browser-control helper × 11 — left by ChatGPT
  Idle, but holding memory. Oldest has sat there 31 minutes.
  A duplicate. One app started the same helper many times over.

  Close all 11? [y/N]
```

## This will not eat your homework

It closes programs. That deserves your suspicion, so here is what stops it
hurting you:

- **It never closes anything on its own.** Running `machogs` only looks. `fix`
  asks you about every single item.
- **It will never close a coding session.** Claude Code sessions, and the
  helpers belonging to a live one, are listed and skipped. You do not lose
  unsaved work.
- **It only touches your own programs.** macOS system processes are out of
  scope entirely.
- **Programs that are meant to work hard are left alone** — video encoders,
  backups, Spotlight indexing.
- **It will not claim credit it has not earned.** If the things it found are
  idle, it says they are not what is spinning your fan.
- **Everything it closes is logged** to `~/Library/Logs/machogs.log`.

Check the safety rules yourself, without closing anything:

```sh
machogs --check
```

## Let your agent drive it

Most people with a hot laptop will not read a shell script. They will ask Claude
Code, Codex, Cursor or a bot. So this is built to be driven.

`--json` prints one object and nothing else. The exit code carries the verdict,
so a wrapper does not have to parse anything: `0` clean, `10` findings worth a
look, `2` bad arguments.

```json
{
  "mode": "report",
  "host": {"load": 4.27, "cores": 10, "swap_pct": 97, "uptime_days": 20},
  "summary": {"reapable": 0, "killed": 0},
  "findings": [
    {"pid": 57377, "section": "2b", "action": "needs-dupes-flag",
     "cpu": 0.0, "age": "01:09:11",
     "detail": "duplicate playwright-mcp under ChatGPT",
     "story": "ChatGPT quietly started 11 copies of the same browser-control helper. All idle, none cleaned up, oldest sitting there 31 minutes."}
  ]
}
```

Every finding carries an `action`, so an agent knows what it may touch:
`reapable`, `needs-dupes-flag`, `protected`, `never-killed`, `killed`.

It also carries a **`story`** — the sentence meant to be said out loud, to a
person, word for word:

> "A Claude Code plugin left a bun running at 98.7% of a CPU core for 4 days.
> It has burned 91 hours of processor time."

The tool knows the good version of that sentence. If it did not hand it over,
every agent would invent its own and most of them would be flat.

**[AGENTS.md](AGENTS.md) is the instruction sheet.** It has the workflow, the
JSON shape, and the rules — chiefly: never close anything before showing the
person, and never work around a `protected` verdict by reaching for `kill`
directly.

## How it knows something is stuck

The obvious test is to ask whether a program's parent has died. An abandoned
program pegging the CPU is clearly finished. That test is real, and it is the
first thing `machogs` checks.

It also misses the worst case. A program can spin forever underneath a perfectly
healthy parent. Nothing looks abandoned, so that test walks straight past a CPU
core burning at full tilt. This is exactly what hid for four days.

So there is a second test, and it asks something different: **has this burned
hours of CPU time, and is it still going right now?** Both have to be true. Real
work burns minutes and finishes. A stuck loop burns hours and never stops.

## What it cannot fix

If it tells you your Mac has run out of fast memory, believe it. Closing
programs barely helps once memory is being shuffled to disk. Restarting is the
only real fix, and the tool says so instead of pretending otherwise.

## License

MIT
