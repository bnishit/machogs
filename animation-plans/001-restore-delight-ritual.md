# 001 — Restore the MacHogs delight ritual

- **Status**: DONE — verified in this change
- **Commit**: this integration commit
- **Severity**: HIGH
- **Category**: Purpose & frequency; missed opportunities
- **Estimated scope**: 4 files, about 120 lines

## Problem

The latest consumer rewrite improved comprehension but stripped the rare moments
where motion, sound, and the receipt prove the product has a personality.

`app/Sources/App/MainWindow.swift:139` renders a successful action as the same
small inline banner used for any result:

```swift
if let receipt = model.receipt { ReceiptBanner(receipt: receipt, dismiss: model.dismissReceipt) }
```

`app/Sources/App/MainWindow.swift:596` makes the win a 38-point mascot and a
single line of copy. It has no receipt heading, evidence action, or rare success
ceremony. `app/Sources/App/MachogsApp.swift:29` plays sound only for watchdog
notifications, so the visible “Play sounds” setting does nothing during the
most important in-app moment. `app/Sources/App/MainWindow.swift:15` renamed the
known Receipts destination to Catches even though receipt language remains in
the app and product contract. `app/Sources/App/OnboardingView.swift:16` removed
the three-step progress indicator and the mascot's small speech treatment,
making the scenes feel less authored.

The mascot's one-shot spring implementation in
`app/Sources/App/PigMascot.swift:55-67` is correct and must be preserved.

## Target

Restore a clear, playful **Sniff → Catch → Receipt** ceremony without adding any
looping motion:

1. Restore the sidebar label **Receipts** and receipt-first copy.
2. A real successful close (`receipt.closedCount > 0`) renders a large receipt
   panel headed **Caught in 4K.** with a one-shot pleased pig, the measured engine
   message, **View receipt**, and **Copy the evidence** actions.
3. Non-success results remain calm and use no confetti.
4. Restore Fable's macOS **Pop** sound plus generic haptic when onboarding, the
   normal window, or the menu popover opens, and when a new successful receipt
   appears. Respect Settings → Play sounds. Never sound on a background scan,
   protected result, already-gone result, cancellation, or evidence copy.
5. Restore a three-scene capsule progress indicator to onboarding. The scene
   swap remains a one-shot spring with response `0.4` and damping fraction `1`.
6. Restore a small `sniff…` bubble beside the pig on the welcome scene. It is
   static; the one-shot mascot supplies the motion.
7. Reduced Motion keeps a short opacity crossfade and removes positional/scale
   movement. No repeating timers, keyframes, breathing, pulsing, or idle loops.

## Repo conventions to follow

- Reuse `PigMascot`; its current `.onAppear` and mood-change springs already
  settle and respect `accessibilityReduceMotion`.
- Reuse `model.makeShareCard()` for copied evidence; do not invent app-only
  totals or battery claims.
- Reuse `AppSettings.soundOn`; do not add a second preference.
- Keep all successful-action facts sourced from `CleanupReceipt` or the shared
  engine log.

## Steps

1. In `app/Sources/App/MainWindow.swift`, restore `AppPage.receipts` to
   **Receipts**. Keep the full-row clickable custom sidebar.
2. Pass a closure from `MainWindow`/`NowPage` that routes to `.receipts`, and
   upgrade `ReceiptBanner` into a large `SuccessReceipt` only when
   `closedCount > 0`. Keep a compact calm result for zero-close outcomes.
3. Add **View receipt** and an explicit engine-backed **Copy the evidence**.
   Copying makes no network request and shows `Copied — paste it anywhere`.
4. Keep one app-lifetime receipt observer for success sound. Play Fable's Pop
   sound from each user-opened app surface and expose **Test pig pop** in
   Settings. Never tie sound lifetime to a normal window.
5. In `OnboardingView.swift`, overlay a three-capsule scene indicator and add
   the static welcome `sniff…` bubble. Preserve real read-only scanning.
6. Do not change engine action code, safety checks, process targeting, release
   scripts, privacy manifest, CLI, website, or documentation outside the PRD.

## Boundaries

- Do NOT add dependencies or media assets.
- Do NOT add looping animation or artificial scan delay.
- Do NOT play sound from background scans, warnings, protected/already-gone
  results, cancellation, or evidence copy.
- Do NOT rename or weaken the final close confirmation.
- Do NOT edit website/discovery files.

## Verification

- **Mechanical**: run
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` in
  `app/`; all 18 tests pass. Run `git diff --check` and confirm no direct
  process signals exist in `app/Sources`.
- **Feel check**:
  - Fresh launch shows one authored welcome, visible progress, and a static
    speech bubble; mascot motion runs once and settles.
  - Successful receipt appears as the emotional focus, sparkles once, sounds
    once when enabled, and remains silent when disabled.
  - Zero-close/protected/already-gone results stay calm and silent.
  - Reduced Motion crossfades scene changes and preserves all text feedback.
- **Done when**: the app visibly retains the clearer consumer language and
  full-row navigation while Receipts, sound, mascot character, and the share
  loop are unmistakably present.
