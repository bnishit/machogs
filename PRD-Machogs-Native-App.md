# MacHogs Native App Product Definition

Status: Build-ready product contract
Scope: Consumer-grade macOS app, backed by the existing MacHogs engine
Decision: Keep Ports and Storage as first-class parts of the normal window. Keep the menu bar focused on current health and review.

## 1. Summary

MacHogs is the honest pig that finds work your Mac is doing behind your back. It explains the cause in plain words, asks before acting, checks safety again at the last moment, and gives a measured receipt for what actually changed.

The app is not a second engine. The bundled command-line tool remains the source of truth for detection, protection, action, and receipts. The native app is the calm, clear consumer surface over it.

### Exact consumer promise

> MacHogs finds stuck and abandoned work, tells you which app left it, and shows what it has cost. Looking changes nothing. Before anything closes, you see exactly what will stop and MacHogs checks that it is still safe. Live coding sessions and macOS stay protected. Every successful close leaves a receipt.

Short form for tight surfaces:

> Finds the hog. Names the app. Closes nothing without you.

Do not claim that MacHogs:

- speeds up every Mac;
- fixes low memory without a restart;
- saves an exact amount of battery;
- uses zero CPU at all times or has zero battery cost;
- can safely close a process based only on an old scan;
- needs Full Disk Access, Accessibility access, or an admin password;
- deletes personal files.

## 2. Contacts

| Owner | Role | Contract |
|---|---|---|
| Product owner | Final product and release call | Approves promise, scope, copy, and release readiness |
| Native build thread | App and engine integration | Owns revalidated action seam and native acceptance tests |
| Website/discovery thread | Website and install story | Uses this contract; owns website and discovery files |
| Apple Developer account holder | Signing and release | Account is approved; publishing and notarizing are outside this work |

## 3. Background

People feel a hot case, loud fan, short battery, slow Mac, full disk, or blocked development port. Activity Monitor shows names such as `node`, `bun`, and `Helper`, which do not explain who started them or whether they are safe to stop.

The existing engine already detects stuck spinners, abandoned helpers, duplicate automation servers, hidden browsers, memory pressure, disk junk spots, and occupied ports. It already carries plain-language stories and explicit protection states. The app already has a menu-bar popover, a normal window, a watchdog, Ports, Storage, Receipts, and Settings.

The Apple Developer account approval makes a trusted native distribution path possible. It does not change the safety bar. A signed app that acts on stale process IDs is still unsafe.

### Original risk and current implementation direction

The original native app had an incomplete trust arc: notification permission
arrived before explanation, some surfaces offered an immediate close, and
native process signals could bypass the engine's latest protection check. The
product contract in this document closes those paths.

The native build thread reports that the current implementation now uses a
first-launch trust arc, review-only alerts, stable-identity engine plans, and an
execution-time safety recheck. Those claims remain subject to integration into
the release candidate and the release gates in section 8. A passing feature
build is not evidence of notarization, clean-Mac behavior, or public-release
readiness.

## 4. Objective

Make MacHogs feel safe enough for a normal Mac owner and useful enough to leave running.

### Key results

For the first public app release:

- 100% of process and port actions are revalidated by the engine after the user asks to review and before an action runs.
- 0 native action paths call a process signal directly.
- 100% of system notifications and island alerts open review; none execute a close.
- 100% of first launches explain the promise before asking for notification or start-at-login access.
- 100% of successful actions report only measured results returned by the engine.
- All clean, finding, stale, error, restart, protected, partial-success, and already-gone states have explicit UI acceptance tests.

Success after release should be measured with privacy-safe, opt-in data or support evidence. Do not add analytics only to meet this document.

## 5. Market segments

### Primary: “My Mac is acting weird”

The person notices heat, noise, lag, or battery loss but does not know process names. They need one plain answer and a safe next step.

### Secondary: AI-tool power user

The person runs Codex, Claude Code, ChatGPT, Cursor, or browser automation. They understand that helpers exist but cannot tell which leftovers are safe.

### Secondary: local developer

The person needs to know why a port is busy and free it without killing a live session or a macOS service.

### Constraint

MacHogs is for the current signed-in user on macOS 13 or later. It is not remote device management, antivirus, a general uninstaller, or a personal-file cleaner.

## 6. Value propositions

| Job | Before MacHogs | With MacHogs |
|---|---|---|
| Explain heat or fan noise | Guess, scroll Activity Monitor, restart | See the named owner and the engine's story |
| Remove abandoned work | Fear losing work | Review a freshly checked set, then confirm |
| Know if restart is the real fix | Close random apps | Get an honest low-memory diagnosis |
| Find storage waste | Buy space or delete personal files | See safe, check-first, and yours categories |
| Free a port | Copy a process ID from a forum command | See the owner, protections, and a named action |
| Feel the result | Hope the Mac is better | Receive measured CPU-time and close receipts |

The main trap is “cleaner theatre”: dramatic warnings, inflated counts, and one-click fixes. MacHogs must stay weird in voice and conservative in action.

## 7. Solution

### 7.1 Product shape

```
first launch
  explain the pig
  explain the limits
  choose shoulder taps + start at login
  open the normal window

menu bar
  current health
  latest catch
  review doorway
  open full window

normal window
  Now       current CPU, memory, and closable findings
  Ports     local services and protected owners
  Storage   disk X-ray and engine-approved cache clearing
  Receipts  measured history and optional share card
  Settings  watchdog, login, sound, trust promises
```

The menu bar answers “do I need to care right now?” The normal window answers “show me the full story and let me act.”

### 7.2 First launch

**User** — every person opening this app build for the first time.
**Entry point** — first app launch, before the normal window.
**Case** — the onboarding completion key is absent.
**What** — a three-step, fixed-size welcome window.
**How** — promise → trust limits → optional watchdog choices → normal window.
**Why** — the app needs trust before it earns background presence.
**Limits** — no account, tour carousel, fake scan, admin prompt, or forced permission.

#### Step 1: purpose

Headline: **Your Mac grew a secret second shift.**

Body: **MacHogs finds stuck and abandoned background work, names the app that left it, and tells you what it has cost. Looking is always free. Closing is always your call.**

#### Step 2: trust

Headline: **Suspicion is healthy.**

- **It can look.** It reads running-process facts that macOS already exposes. It does not read documents or browser history.
- **It cannot act alone.** A finding is a suggestion. The person reviews and confirms every action.
- **The engine gets the last word.** It checks again before action. Live coding sessions and macOS stay protected.

Footer: **No Full Disk Access. No Accessibility access. No admin password.**

#### Step 3: optional background behavior

- **Shoulder taps**, default on: show the island and request macOS notification permission only after “Open MacHogs.” If denied, the island and manual app still work.
- **Start at login**, recommended and visibly on: register only after the person confirms the screen. Failure does not block app use and is explained inline.

Completion opens the normal window on Now. Onboarding never repeats after successful completion. Settings keeps both choices reversible.

#### First-launch acceptance criteria

- A fresh install shows onboarding once and brings it to the front.
- No system notification prompt appears on step 1 or step 2.
- Turning Shoulder taps off completes onboarding without a notification prompt.
- Turning Start at login off makes no login-item registration attempt.
- A login-item failure leaves the person in control and offers a plain explanation.
- Quitting before completion shows onboarding again next launch.
- Completing onboarding opens Now, not Receipts or a menu-only dead end.
- VoiceOver reads title, body, toggles, progress, Back, and Next in a useful order.

### 7.3 Permissions and trust

MacHogs uses contextual permission: ask at the moment the feature is chosen, with the benefit already explained.

| Capability | System access | Product behavior |
|---|---|---|
| Scan running work | No prompt expected | Read-only by default |
| Notifications | macOS notification prompt | Ask only after Shoulder taps is chosen |
| Start at login | Login-item registration | Explicit onboarding or Settings toggle |
| Close a process | No blanket permission | Engine revalidation plus named confirmation |
| Clear cache | File access to an engine allow-list path | Two-step UI plus engine path revalidation |
| Restart | macOS restart flow | Clear warning that every app closes |

If a future feature needs broader access, it requires a new product review. Do not quietly add a permission string.

### 7.4 Menu bar and alerts

**User** — a person working in any app.
**Entry point** — pig, fire, or camera icon in the menu bar.
**Case** — manual glance or watchdog catch.
**What** — a fast health summary and a route to review.
**How** — click icon → read one verdict → Review or Open MacHogs.
**Why** — awareness without taking focus or asking for housekeeping.
**Limits** — no process close, port kill, cache clear, or restart runs from a notification or island.

Menu-bar icon contract:

- 🐷 means no hot closable finding in the latest fresh scan.
- 🔥 means a hot closable finding exists.
- 📸 means the watchdog caught a change the person has not reviewed.
- An error must not masquerade as 🐷. Show an error badge/state and “Last checked” time.

The popover contains:

- one current verdict;
- a short list of active findings;
- a Review button per finding;
- restart warning when memory pressure is above the engine threshold;
- doorways to the normal window;
- Settings and Quit.

The island is a non-activating tap on the shoulder. It may say “Caught the hog,” “Session over, mess left,” or “Clone army forming.” Its primary action is **Review**, never **Close it**. Dismiss snoozes only according to the watchdog contract; it does not mark a finding safe or resolved.

System notifications use one foreground action: **Review it**. Clicking the body or action opens the same review state. No notification action carries consent to stop a process.

Watchdog alerts remain limited to facts the engine supports:

- normal background scans run every two minutes; manual scans and the targeted
  post-session follow-up are separate;
- hot for two polls, not one busy moment;
- a new leftover after a tracked coding session ends;
- a duplicate group crossing the clone threshold;
- first poll is a baseline and never alerts;
- cooldowns prevent repeat nagging;
- idle findings are described as memory waste, never the cause of fan noise.

#### Menu-bar acceptance criteria

- Every alert route lands on the exact live group that caused it, or says “Already gone.”
- Review never falls back to closing every current finding when its original target is stale.
- The island can be dismissed without action.
- The island does not steal keyboard focus.
- Notification denial leaves manual scans and the island usable.
- The normal watchdog cadence is two minutes and does not silently become a
  one-minute poll.
- Reduced Motion replaces sliding and camera-flash motion with a short fade.

### 7.5 Normal window

**User** — anyone who wants the full state, history, or a deliberate action.
**Entry point** — onboarding completion, Open MacHogs, menu-bar doorway, Dock/open event, or alert review.
**Case** — routine check, finding, blocked port, full disk, or receipt review.
**What** — one sidebar window with five first-class pages.
**How** — choose page → see plain verdict → review a specific action.
**Why** — the app needs a stable home, not a stack of novelty windows.
**Limits** — Caught in 4K is a focused review presentation, not a second app shell.

Keep these pages:

| Page | Role | Primary action |
|---|---|---|
| Now | CPU, memory, uptime, fresh closable findings | Review close or review restart |
| Ports | All listeners grouped as yours, protected, or system | Review freeing one port |
| Storage | Disk use and engine verdict per location | Clear safe cache or Show in Finder |
| Receipts | Measured result history and share loop | Copy share card |
| Settings | Watchdog, login, sound, trust facts | Change reversible preferences |

Ports and Storage remain first-class. They answer different user jobs, use real engine modes, and prevent MacHogs from being a one-warning novelty. They must not crowd the menu bar.

The default window opens on Now. A deep link may open a specific page. Window close hides the window while the menu-bar app continues if enabled; Quit ends the app.

### 7.6 Safe consent and action contract

**User** — a person considering a process, port, cache, or restart action.
**Entry point** — Review from the app, island, notification, or alert window.
**Case** — the latest scan says something may be acted on.
**What** — a named confirmation based on a fresh engine plan.
**How** — request review → engine revalidates → sheet shows current targets → confirm → engine acts → app renders result.
**Why** — a scan result is evidence, not permission, and process IDs can be reused.
**Limits** — if the engine cannot revalidate a target, the app cannot act on it.

#### Required process-close flow

1. The finding card action says **Review close**.
2. The app sends the finding's stable identity to the engine. A stale process ID alone is not an identity.
3. The engine returns a fresh plan with current identity, current protection result, and human story.
4. The app shows only items that are still closable.
5. Confirmation copy:
   - title: **Close 3 helpers from ChatGPT?**
   - body: **MacHogs checked these again just now. It will stop only the 3 items shown below. Unsaved work inside them can be lost. Live coding sessions and macOS stay protected.**
   - buttons: **Cancel** and **Close 3 items**.
6. On confirm, the engine rechecks at execution or consumes a short-lived plan that cannot target a reused process.
7. The app renders the engine's actual result, including partial success, protection, or already-gone items.

Bulk close is the same flow with all groups listed. It is not a shortcut around review.

Port copy:

- title: **Free port 3000?**
- body: **MacHogs checked the listener again. This will stop node in my-app. Unsaved work inside it can be lost. macOS services and live coding sessions stay protected.**
- buttons: **Cancel** and **Stop node and free port**.

Storage keeps its two-step button because the engine already rechecks the exact path against a fixed safe list. Check-first and yours items never get a delete button.

Restart copy:

- title: **Restart this Mac now?**
- body: **Every open app will close. Save your work first. A restart clears the memory pressure MacHogs found; closing background leftovers will not.**
- buttons: **Cancel** and **Restart Mac**.

#### Action acceptance criteria

- No app source path calls `kill`, `SIGTERM`, or `SIGKILL` for a product action.
- No process action accepts only a PID captured by a prior scan.
- A protected or reused target is refused even if it was closable seconds earlier.
- Cancel changes nothing and creates no receipt.
- When every target is already gone, show “Already gone. Nothing to close.”
- Partial success names counts: “Closed 2. One had already gone. One is now protected and was left alone.”
- Bulk review lists each owner/story and total count before confirmation.
- Buttons use literal verbs and counts; no ambiguous “Fix,” “Do it,” or unlabeled icon performs a destructive action.

### 7.7 Receipts and share loop

**User** — a person who acted and wants proof or a small win.
**Entry point** — successful action banner or Receipts page.
**Case** — the engine confirms at least one close or cache clear.
**What** — a measured receipt, then an optional cumulative share card.
**How** — action completes → receipt appears → Receipts log updates → Copy card on request.
**Why** — the value is recovered work, not the violence of killing a process.
**Limits** — battery and phone-charge numbers are estimates and stay hedged.

Immediate receipt order:

1. actual number closed or amount cleared;
2. CPU core capacity recovered when material;
3. CPU time already burned;
4. projected next-day waste when supported;
5. estimated battery or phone-charge comparison, clearly marked as rough.

Receipts are written only for successful action results. The app and CLI share one log format and one scoreboard. A failed, cancelled, protected, or already-gone action is not a win and does not increment totals.

Sharing is pull, not push. The app offers **Copy my receipt card** on Receipts after there is history. It never opens a social site, posts, or adds referral tracking. The card comes from the engine's brag output so CLI and app agree.

#### Receipt acceptance criteria

- Immediate receipt matches the engine result, not the pre-action scan.
- “Got back a CPU core” appears only when measured current CPU supports it.
- Idle cleanup never claims it cooled the fan.
- Estimate words remain in every battery and electricity comparison.
- Empty Receipts says what will appear after the first close and links to Now.
- Copy gives visible “Copied” feedback and does not trigger confetti every time.

### 7.8 State contracts

| State | What the person sees | Allowed action |
|---|---|---|
| Checking, no prior data | “Sniffing around…” with progress | Wait or Quit |
| Fresh clean | “Nothing is hogging your Mac” plus check time | Check again |
| Fresh hot finding | Engine story and current heat | Review close |
| Fresh idle finding | Memory-waste wording, not fan claim | Review close |
| High swap | “Out of fast memory” and why restart is different | Review restart |
| Already gone | “It cleaned itself up. Nothing to close.” | Done |
| Protected | “Left alone — it belongs to a live session” | Open/quit owner if useful |
| Stale after scan error | Last known data labeled with time and dimmed | Retry; no action from stale data |
| First scan error | Plain cause, retry, and install/support route | Retry |
| Partial action | Exact closed, gone, refused, and failed counts | Review remaining live items |
| No receipt history | Friendly empty state and route to Now | Open Now |
| No disk junk | Real files are using the space | Show storage guidance only |
| No freeable ports | System/protected listeners may still be listed | No kill action |

Error copy must say what the user can do. Do not show shell commands in the main sentence. Technical detail may be disclosed behind a button and copied for support.

The app stores the time of the last successful scan. A failed refresh does not turn the icon green or erase the last-known state. It disables action until fresh engine review succeeds.

### 7.9 Motion, sound, and accessibility

The desired emotion is calm confidence with one odd little pig, not a casino cleaner.

- The original pig character is one continuous guide across onboarding,
  scanning, clean and finding results, receipts, the menu icon, and the menu
  panel. State may change its pose or heat; the product must not swap in an
  unrelated mascot.
- Use system type, standard traffic lights, real sidebars, keyboard focus, and macOS sheets.
- Buttons respond on press. Routine motion is critically damped and short.
- Bounce belongs only to the physical island arrival or mascot, never a warning sheet.
- Confetti and sound follow a real success, not scan findings, copy, cancel, or retry.
- Respect Reduce Motion, Reduce Transparency, Increase Contrast, and VoiceOver.
- Emoji supports the voice but never carries the only meaning.
- The camera flash effect is removed under Reduce Motion and should be reduced in brightness for everyone.

#### Character and motion acceptance criteria

- Onboarding, scan/result, receipt, menu icon, and menu panel use the same
  original pig character language.
- Consent sheets stay visually calm: no mascot celebration, alarm animation,
  or coercive countdown appears before a close.
- Character motion uses one-shot spring reactions. No mascot animation starts
  an indefinitely repeating transaction after the app settles.
- Reduce Motion removes continuous mascot movement and replaces spatial alert
  motion with a short fade while keeping state changes understandable.
- A static screenshot can prove the normal window states. Menu-popover coverage
  requires its own capture and must not be inferred from a successful build.

### 7.10 Native app and CLI relationship

```
native app ─┐
            ├─ MacHogs engine ─ detection, protection, action, receipts
CLI ────────┘
```

The CLI remains a first-class product:

- report mode is read-only;
- `fix` is best for a person at a real terminal;
- machine JSON is the app and agent contract;
- unattended kill modes remain for explicit automation, not native UI shortcuts;
- disk and port actions keep engine protections;
- app and CLI write the same receipt log.

The native app bundles a known engine version and prefers it. It may use an installed CLI only as a documented recovery path, not silently change behavior by version. The app must surface engine/app version mismatch in Technical detail.

The app uses the engine's targeted, revalidated action contract. If that
contract is unavailable, mismatched, or cannot refresh a target, affected
buttons stay in review-only mode. Native Swift must not duplicate process
ancestry, protection, allow-list, or ownership rules.

## 8. Release

### Release 1: trustworthy app arc

- first-launch promise and optional permissions;
- normal window as the stable home;
- menu-bar glance and review routes;
- revalidated process and port action seam;
- exact consent sheets;
- honest receipts and share copy;
- clean, stale, error, already-gone, protected, partial, and restart states;
- accessibility and Reduced Motion pass;
- visible version and signing status;
- a user-clicked Check for Updates that opens GitHub Releases, with no silent check;
- plain uninstall steps;
- signed local build and release checklist.

### Verified implementation and release status — 19 August 2026

The native build thread reports that the original pig character now spans
onboarding, scan/result, receipt, menu icon, and menu panel. Consent remains
calm. The normal background cadence is two minutes, and Reduce Motion is
honored. Notifications and menu surfaces only open Review. Every close path
uses a stable-identity engine plan plus an execution-time recheck. A full Xcode
build and 11 safety, state, and watchdog tests pass in that build thread.

The same thread found and corrected a performance regression before release: an
indefinitely repeating SwiftUI mascot transaction kept the first test app near
11% CPU after it had settled. Character motion now uses one-shot spring
reactions. In the rebuilt menu-only test app, measured CPU was 0.0% after scan
settlement while the normal background interval remained two minutes. Final
verification remained 11/11, and the plist, shell syntax, and diff whitespace
checks passed.

Approved evidence wording for product or website work is narrow:
**“In the rebuilt menu-only test app, CPU measured 0.0% after scan settlement.”**
Do not shorten this to “uses no CPU,” turn it into a battery promise, or apply
it to every Mac and every state.

This evidence proves the reported native implementation and its automated
checks. It does **not** prove that its menu popover has been captured, that the
changes have passed the final integration build in this worktree, or that a
public release exists.

Separately, the Apple Developer Program membership is approved and this Mac
now has one valid Developer ID Application identity. The identity has an
encrypted backup outside the repository. A clean universal Apple silicon +
Intel app was signed locally and passed the pre-notarization verifier. This is
not a signed release artifact: no final DMG has been approved, notarized,
stapled, validated on clean Macs, uploaded, or published.

#### Native acceptance evidence

| Contract | Evidence recorded | Remaining release proof |
|---|---|---|
| Character continuity | Original pig reported across onboarding, scan/result, receipt, menu icon, and panel | Capture and review the final menu popover |
| Calm consent | Review and confirmation flow implemented without an alert-first close | Exercise every named close and cancel path in the integrated app |
| Alert safety | Notification and menu actions open Review only | Verify notification denial, stale target, and already-gone behavior on a clean Mac |
| Close safety | Stable-identity plan and execution-time recheck implemented | Confirm protected and PID-reuse refusals in the final release candidate |
| Background behavior | Two-minute normal cadence and watchdog coverage reported | Observe cadence across sleep, wake, logout, and login |
| Settled CPU | Rebuilt menu-only test app measured 0.0% after scan settlement; the earlier repeating mascot transaction measured near 11% | Repeat on the integrated candidate and both supported CPU architectures |
| Character motion | Repeating mascot transaction replaced by one-shot spring reactions | Preserve one-shot behavior through integration and accessibility review |
| Accessibility | Reduce Motion behavior implemented | Complete VoiceOver, contrast, and transparency passes |
| Automated verification | Full Xcode build plus 11/11 safety/state/watchdog tests; plist, shell syntax, and diff whitespace checks pass | Run the same suite after integration and on the exact packaged candidate |

The app must expose its current version and signing state in Settings. An ad-hoc build says **Development build — not ready to share**. A Developer ID signature may say **Developer ID signed**, but must not imply notarization by signature alone.

Current package contract:

| Item | Contract |
|---|---|
| Identity | `com.bnishit.machogs` |
| Version | 1.2.0, build 3 |
| System | macOS 13 or later; Apple silicon and Intel |
| Shape | MenuBarExtra app with `machogs` URL scheme |
| Sandbox | Off for v1 |
| Entitlements | None unless a tested feature proves it is needed; never `get-task-allow` |
| Engine | Executable at `Contents/Resources/machogs` |
| Privacy | Include `PrivacyInfo.xcprivacy`; no tracking or collected data claims |
| Updates | Manual; a user click opens GitHub Releases; no silent network check |
| Artifact | One Developer ID-signed DMG with Machogs.app and an Applications shortcut |

The distribution ceremony is sequential and evidence-based: sign with Developer ID and a secure timestamp, notarize the DMG, wait for Accepted, staple, validate the staple, then pass Gatekeeper assessment. Publishing still needs separate user approval after the exact artifact is shown.

Uninstall copy is fixed: **Turn off Start at Login, quit MacHogs, then drag MacHogs.app to the Trash. Receipts and preferences remain unless you remove them separately.**

Pre-release testing covers a clean Intel Mac and a clean Apple silicon Mac, notification permission, Start at Login across logout/login, a report-only first scan, explicit process-close and cache-clear consent, and protected-process refusal.

### Later, only after evidence

- richer per-app history;
- configurable alert thresholds;
- an in-app updater, only if manual updates prove too painful;
- App Store or direct-download channel choice;
- privacy-safe product analytics;
- multi-user or remote support.

### Not in this work

- publishing, notarizing, uploading, or changing external accounts;
- deleting personal files;
- automatic process closure;
- a background privileged helper;
- antivirus or malware claims;
- redesigning the website or discovery assets.

### Release gate

Do not ship the consumer app while any native direct-kill path remains. A valid
Developer ID identity is now available, but identity setup alone does not make
the app releasable. The release gate needs all of the following:

- revalidated engine action seam and consent tests pass;
- universal Apple silicon + Intel build passes;
- privacy manifest is present in the app bundle;
- no App Sandbox, surprise entitlement, or `get-task-allow` appears;
- Developer ID certificate and private key are installed and valid;
- notary credentials are stored with user approval;
- the exact DMG passes signature, staple, and Gatekeeper checks on clean Macs;
- the user approves the upload and the later GitHub release separately.
