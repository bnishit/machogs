// Explicit events only: no SDK, autocapture, fingerprinting, or session replay.
(() => {
  'use strict';
  const config = window.machogsAnalyticsConfig;
  const test = new URLSearchParams(location.search).get('analytics_test') === '1';
  const production = location.hostname === 'bnishit.github.io' && location.pathname.startsWith('/machogs/');
  const available = config?.token && ['https://us.i.posthog.com', 'https://eu.i.posthog.com'].includes(config.host) && (production || test);
  const key = test ? 'machogs.analytics.test.choice' : 'machogs.analytics.choice';
  const blocked = navigator.globalPrivacyControl === true || navigator.doNotTrack === '1';
  let choice;
  try { choice = localStorage.getItem(key); } catch { /* Choice lasts for this page only. */ }
  let pageID, visited = false;
  const pending = new Set();
  const landing = !location.pathname.endsWith('privacy.html');

  function capture(event, placement) {
    if (!available || blocked || choice !== 'yes' || (!test && navigator.webdriver)) return;
    if (placement !== undefined && !['nav', 'hero', 'install'].includes(placement)) return;
    if (!crypto.randomUUID) return;
    pageID ||= 'web_' + crypto.randomUUID();
    const controller = new AbortController();
    pending.add(controller);
    const payload = {
      api_key: config.token, event, distinct_id: pageID, uuid: crypto.randomUUID(),
      properties: {
        product: 'machogs', platform: 'web', environment: test ? 'test' : 'production',
        app_version: config.version, ...(placement ? {placement} : {}),
        $process_person_profile: false, $geoip_disable: true, $ip: '0.0.0.0'
      }
    };
    fetch(config.host + '/i/v0/e/', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(payload), credentials: 'omit', referrerPolicy: 'no-referrer',
      keepalive: true, signal: controller.signal
    }).catch(() => {}).finally(() => pending.delete(controller));
  }

  function visit() {
    if (landing && choice === 'yes' && !visited && document.visibilityState === 'visible') {
      visited = true;
      capture('machogs_website_visit');
    }
  }

  function render() {
    document.querySelectorAll('[data-analytics-choice]').forEach(el => {
      el.hidden = !available || (landing && (blocked || choice === 'yes' || choice === 'no'));
    });
    document.querySelectorAll('[data-analytics-status]').forEach(el => {
      el.textContent = !available ? 'Analytics are not enabled on this build.' : blocked
        ? 'Your browser privacy signal has turned analytics off.'
        : choice === 'yes' ? 'Website analytics are on. You can turn them off below.' : 'Website analytics are off.';
    });
    document.querySelectorAll('[data-analytics-consent="yes"]').forEach(el => { el.disabled = blocked || !available; });
  }

  document.querySelectorAll('[data-analytics-consent]').forEach(button => {
    button.addEventListener('click', () => {
      choice = button.dataset.analyticsConsent;
      try { localStorage.setItem(key, choice); } catch { /* No persistent storage required. */ }
      if (choice !== 'yes') {
        pending.forEach(controller => controller.abort());
        pending.clear();
        pageID = undefined;
        // Do not count another visit on this same page if consent changes again.
      }
      render();
      visit();
    });
  });
  document.querySelectorAll('a[data-download-placement]').forEach(link => {
    link.addEventListener('click', () => capture('machogs_download_clicked', link.dataset.downloadPlacement));
  });
  // Consent withdrawn in another tab applies here too.
  window.addEventListener('storage', event => {
    if (event.key === key) {
      choice = event.newValue;
      if (choice !== 'yes') { pending.forEach(controller => controller.abort()); pending.clear(); pageID = undefined; }
      render(); visit();
    }
  });
  document.addEventListener('visibilitychange', visit);
  render(); visit();
})();
