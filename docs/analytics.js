// Explicit events only: no SDK, autocapture, fingerprinting, or session replay.
(() => {
  'use strict';
  const config = window.machogsAnalyticsConfig;
  const test = new URLSearchParams(location.search).get('analytics_test') === '1';
  const production = location.hostname === 'bnishit.github.io' && location.pathname.startsWith('/machogs/');
  const available = config?.project === 'machogs' && config.host === 'https://native-analytics-production.up.railway.app' && (production || test);
  const key = test ? 'machogs.native.analytics.test.choice' : 'machogs.native.analytics.choice';
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
    pageID ||= crypto.randomUUID();
    const controller = new AbortController();
    pending.add(controller);
    const payload = {
      id: crypto.randomUUID(), install_id: pageID, consent: true,
      event, feature: 'web', outcome: 'success', version: config.version,
      ...(placement ? { placement } : {})
    };
    fetch(config.host + '/v1/relay/' + config.project, {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(payload), credentials: 'omit', referrerPolicy: 'no-referrer',
      keepalive: true, signal: controller.signal
    }).catch(() => {}).finally(() => pending.delete(controller));
  }

  function visit() {
    if (landing && choice === 'yes' && !visited && document.visibilityState === 'visible') {
      visited = true;
      capture('web.page_view');
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
    link.addEventListener('click', () => capture('web.download_clicked', link.dataset.downloadPlacement));
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
