# MacHogs design exploration

Recommendation: build on **C, Quiet Companion**, with the warmth of A's pig. This keeps a familiar Mac app while making the answer, next step, and safety boundary much clearer. No user decision is required to start the branch implementation; this is a design recommendation, not recorded user preference.

Open `~/.gstack/projects/machogs/designs/2026-09-20-polish/round-1.html` to switch between three proposed layouts. These are HTML concepts, not screenshots of the running app. All counters come from the saved 20 September 2026 safety report: **41 protected findings, 0 actionable findings, 0 closed**. Other surfaces are navigation context only. They do not run actions.

| Direction | Visual language | Layout | Main tradeoff |
|---|---|---|---|
| A · Field Notes | Warm paper, forest ink, Georgia serif status | Asymmetric editorial hero, pig alongside the answer | Most memorable; can feel less native in dense tool screens |
| B · Control Room | Graphite, lime, system monospace | Horizontal workspace, compact inspection ledger | Strong for developers; too austere as the default for everyone |
| C · Quiet Companion | Silver, plum, system sans | Familiar sidebar, centered mascot, quiet evidence strip | Most native; needs deliberate spacing to avoid feeling generic |

## Product story

- **User:** Mac owners checking slow or noisy machines. No measured audience count is available.
- **Entry point:** The app's Overview window.
- **Case:** A scan finds nothing actionable while running work remains protected.
- **What:** A clear result, read-only refresh, and visible protection count. No false promise that the whole machine is healthy.
- **How:** Open Overview, read the answer, optionally expand the protection explanation, check again when needed.
- **Why:** A zero-finding result should be useful and reassuring without hiding protected sessions or pushing needless cleanup.
- **Limits:** Proposed branch design. Counts are a saved sample, not a live scan. No new detector, memory claim, battery estimate, or history chart is proposed.

## Native implementation boundaries

Reuse the existing split navigation, `PigMascot`, scan/review flows, and disclosures. Improve visual hierarchy through typography, spacing, subdued borders, and a short evidence strip. Keep large character moments in clean/result states; give findings and safety reviews the space when action is needed. Use standard system materials and accessibility contrast, not opaque glass effects layered over content.

All themes must preserve stale/error states, the restart warning, the distinction between idle memory use and heat, and protected session refusal. Decorative motion should respect Reduce Motion. Successful cleanup can celebrate only after a confirmed receipt.

## Round 1 self-review

The directions differ in font family, temperature, layout, and rhythm. C is the implementation candidate. A's editorial treatment can inform brand/website work; B is a useful compactness reference. Do not ship three theme systems simply because three concepts exist.

The board uses real app vocabulary and saved counts, labels proposed UI clearly, supports keyboard direction switching and a disclosure, and never runs a scan or closes a process. The action preview explains its boundary. Navigation labels are intentionally static in this single-question comparison.


## Round 2 refinement

The fourth board tab develops C with A's light character. The centered hero gave the pig too much vertical space. Move it beside a compact rounded status heading, use a single quiet protection strip, and remove redundant zero counters from this clean state. The native implementation should use actual model state and preserve checks/error precedence; the HTML is only a composition reference.

Reviewer pass: distinct concepts pass; safety language remains explicit; zero findings does not claim a healthy Mac; no fabricated graphs or savings; action preview cannot close anything. Static navigation is labelled in the board documentation. Keyboard tabs now include the fourth option. Artifact location follows the design-shotgun durable-artifact rule; this repository note records only the recommendation.

## Verification boundary

JavaScript parses successfully. All four direction controls and no remote resource links are present. Render and interaction verification could not be completed: the browser tool blocked the local file URL under its URL policy. No alternate browser or local-server workaround was attempted. The HTML must not be described as visually verified.

## Implemented branch preview

Machogs Design is a separate running Mac app with its own bundle identity, URL scheme, and preferences. The Run action opens the real Overview with live read-only data. Preview launch bypasses onboarding only in memory, with notification requests and sounds disabled; it does not alter production settings or register a login item.

The native second pass uses adaptive Mac materials, restrained rose accents, a compact mascot, a clear status headline, an evidence strip, and an expandable protected-work list grouped by owning app. The existing Overview code was moved out of the large main-window file rather than layered over it. Menu-bar and full-window states now share one interpretation of scan evidence.

Process and port actions open the existing review screen. External close links and notification actions also request review. A failed check stays stale while retrying. Action counts use unique process identities, with protection taking priority over an overlapping actionable finding.

Validation on 20 September 2026: all 29 Swift tests and four engine regression tests pass; design app builds and launches, and both design and production processes remain running. Design bundle and URL identities were read back. No real process was closed or cache cleared in testing. Native screen inspection failed because the computer-use bridge closed its pipe, so actual layout, dark-mode contrast, and keyboard interaction still need visual inspection. This branch is a draft, not a public release.

Optional illustration: built-in imagegen produced a ceramic pig and shield study. The prompt and image are saved beside the durable design board in assets/. It remains concept artwork, not a UI screenshot and not a shipped app asset; the app retains the editable animated mascot.

## Next iteration

Inspect the running design app in both appearance modes, then refine density and type using actual screenshots before merging. The earlier memory and battery detector branches remain separate. A reviewer also noted an older receipt edge case: the engine can skip a newly protected target without updating its earlier actionable row; this preserves the process but can produce an imprecise failure receipt. Keep that as a separate engine change with a focused regression test.
