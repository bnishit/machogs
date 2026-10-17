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

## Website and previously released app

Website collection remains separately optional in docs/analytics.js and
analytics-config.js, using shared PostHog project 39922. Do not change its global
settings. Events machogs_website_visit and machogs_download_clicked use unrelated
random IDs per page load. Person processing and GeoIP enrichment are disabled;
the payload uses the fixed IP placeholder 0.0.0.0. The network provider still sees
the connection IP. Honor Do Not Track and Global Privacy Control.

Released app versions using the prior basic-usage implementation send
machogs_app_first_seen and machogs_app_active_week after consent, once per UTC ISO
week for foreground use. Those versions remain unchanged by this branch.
Dashboard: https://us.posthog.com/project/39922/dashboard/2116324.
Filter older data by product=machogs and environment=production; QA is test.
Download clicks and GitHub asset downloads do not prove installed active users.
