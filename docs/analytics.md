# Machogs measurement contract

## Updated native app and CLI

Sharing is optional and off by default. The app requires a new choice in Settings
→ Privacy even when the old PostHog basic-usage choice was enabled. Development,
design and --analytics-test app builds never send to the production relay.

| Event | Meaning |
|---|---|
| app.opened | Opted-in foreground activation, throttled to once a minute |
| onboarding.completed | Completion of setup while opted in |
| scan.completed | Process, memory, storage or port check; once per feature per minute |
| action.completed | Outcome and bounded closed count from a confirmed manual review |
| cli.* | Explicitly opted-in CLI command category and outcome |

Native app payload keys are id, install_id, consent, event, version, feature,
outcome, count and duration_ms. Counts are capped at 100000 and duration at one
hour. CLI payloads omit count and duration. No process names, paths, arguments,
scan contents, messages, credentials or receipt contents are allowed.

The fixed HTTPS endpoint is
https://native-analytics-production.up.railway.app/v1/relay/machogs.
No producer key is embedded. The receiver stores connection IPs and retains
events for 90 days. Opt-out cancels pending app requests and resets the ID;
already received events remain. Delivery is best-effort with no offline retry.
CLI users explicitly set MACHOGS_ANALYTICS=1 and unset it to stop collection.
The app forces this variable off for its bundled engine.

Background scan counts are not active-user counts. Do not combine this schema
with older first-use/weekly-use events. Random IDs can reset and do not prove
unique people, installs, security events or website-to-install conversion.

Run Python CLI tests, Swift core tests and a dev build. Tests use mock transports:
no live scan, cleanup or production analytics send is needed. Check default-off,
old-consent isolation, dev silence, payload limits, throttling, opt-out cancellation
and identity reset. A real launched-app check and signed/notarized release remain
separate gates before public distribution.

## Website and previously released apps

The website uses the same fixed-schema Native Analytics relay after a fresh, separate consent choice. It sends `web.page_view` and `web.download_clicked`, version, feature=web, optional nav/hero/install placement, and an unrelated UUID per page load. It stores no persistent visitor ID and never joins website activity with app IDs. The receiver retains the connection IP for 90 days. Global Privacy Control and Do Not Track disable collection; choosing no cancels pending sends. Only the exact GitHub Pages HTTPS origin is allowed by the relay's browser policy. No collector key is in browser code.

Older released app versions can still send their previous first-use/weekly-use PostHog events until updated. No historical provider data is copied or deleted. Download clicks and GitHub asset downloads do not prove installed active users.
