# Machogs measurement contract

Collection is optional on both the website and app, off until chosen. The owner
approved shared PostHog project 39922. Its global settings must not be changed for
Machogs. Capture tokens are public, write-only project identifiers; no personal
API keys belong in clients.

Dashboard: https://us.posthog.com/project/39922/dashboard/2116324

## Events and interpretation

| Event | Count | Boundaries |
|---|---|---|
| machogs_website_visit | Opted-in landing page views | New random ID per page load; not unique people |
| machogs_download_clicked | Opted-in download clicks | placement: nav, hero, install; not completed downloads |
| machogs_app_first_seen | First observed opted-in app use | Filter installation_kind=new_install for new setups; existing_install for upgrade users |
| machogs_app_active_week | Distinct opted-in installations with foreground use | Once per UTC ISO calendar week; background scans excluded |

All dashboard tiles must filter product=machogs and environment=production, so
other products in the shared project stay separate. QA uses environment=test.
App first_seen and active_week use the same random installation identifier; the
website uses an unrelated page identifier. Only visit-to-download-click can form
a same-ID funnel. Do not publish a website-to-install conversion rate or ad
attribution from these events. Resets and repeated opt-in can inflate install counts.
Homebrew CLI installs are not instrumented. GitHub release asset download counts
remain available separately and include release checks/repeated downloads.

Native delivery retries on the next foreground activity, with the same event UUID
until a successful HTTP acknowledgement. There is no background analytics timer.
Opt-out cancels in-flight work, discards unsent state and deletes the local ID;
already received events remain. The website never delays a download for analytics.
Blocked requests, opt-outs and failed delivery all cause undercounts.

## Payload boundary

Native: event, random installation ID, event UUID/time, app_version, platform,
environment, product, installation_kind; provider control properties disable person
profiles and GeoIP and set $ip to the fixed placeholder 0.0.0.0. Web: event, random per-page ID,
event UUID, app_version, platform, environment, product and allowlisted button
placement. No raw URLs, UTM values, referrers, hardware IDs, process names,
file paths, scan contents, screen recording, or arbitrary extra properties.
Both clients send the same IP placeholder. Live QA on 20 September 2026 confirmed
that PostHog stored 0.0.0.0, no country, and person processing disabled. Sending
$ip:null was insufficient: the service stored the source IP instead. Do not revert
to null or depend on global IP settings. PostHog still sees the connection's source
IP while handling the network request.

## Configuration and checks

- App: Info.plist MachogsAnalyticsToken and MachogsAnalyticsHost. Release builds
  with production bundle ID only. Default/dev/design builds never collect.
- Website: docs/analytics-config.js. Only bnishit.github.io/machogs/ sends normal
  events. Local QA requires explicit analytics_test=1 and is tagged test.
- Native QA: launch signed app with --analytics-test for separate analytics-only
  preferences and environment=test. This must not touch production consent.
- Verify zero requests before consent, exact allowlisted payloads after consent,
  deduplicated same-week use, opt-out cancellation, offline retry, and dev silence.
- Read ingested test events from PostHog and confirm $ip=0.0.0.0, no location
  enrichment or sensitive data, and person processing disabled. Confirm the
  production dashboard filters product=machogs and excludes environment=test.
- Sources: https://posthog.com/docs/api/capture and
  https://posthog.com/tutorials/web-redact-properties; Apple privacy manifest:
  https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests
