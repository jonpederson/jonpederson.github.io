/* Runs on the source sites (MarketWatch, EIA, AAA, GasBuddy, OilPrice).
   Best-effort extraction only -- every candidate is sent to background as
   'pending' and must be confirmed (or edited) by the user in the popup
   before it ever reaches the report form. Never trust a single scrape. */

(function () {
  const PRICE_RE = /(-?)\$?\s?(\d{1,4}\.\d{2,4})/g;

  function numbersNear(text) {
    const out = [];
    let m;
    PRICE_RE.lastIndex = 0;
    while ((m = PRICE_RE.exec(text)) !== null) out.push(parseFloat(m[1] + m[2]));
    return out;
  }

  function round2(x) { return Math.round(x * 100) / 100; }

  function median(nums) {
    if (!nums.length) return null;
    const s = [...nums].sort((a, b) => a - b);
    const mid = Math.floor(s.length / 2);
    return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }

  function tryText(selector) {
    const el = document.querySelector(selector);
    return el ? el.textContent : null;
  }

  function firstNumberFrom(selectors) {
    for (const sel of selectors) {
      const txt = tryText(sel);
      if (txt) {
        const nums = numbersNear(txt);
        if (nums.length) return { value: nums[0], rawText: txt.trim().slice(0, 60) };
      }
    }
    return null;
  }

  /* ---------------- MarketWatch futures quote page ----------------
     Confirmed against the live RB.1/HO.1 templates: the head carries
     server-rendered <meta name="price"|"priceChange"|"priceChangePercent">
     tags that don't depend on the live-update websocket, so they're the
     primary source. DOM fallback is h2.intraday__price .value for price
     and .intraday__change .change--point--q for the change -- NOT a bare
     bg-quote[field="Last"], which also matches unrelated ticker/sidebar
     quotes elsewhere on the page. */
  function metaNumber(name) {
    const el = document.querySelector(`meta[name="${name}"]`);
    if (!el) return null;
    const n = parseFloat((el.content || '').replace(/[^0-9.\-]/g, ''));
    return Number.isNaN(n) ? null : n;
  }

  function captureMarketWatch() {
    if (!/\/investing\/future\//.test(location.pathname)) return [];
    const titleText = (document.querySelector('h1') || {}).textContent || document.title || '';
    let field = null;
    if (/RBOB/i.test(titleText)) field = 'rbob';
    else if (/Heating Oil|ULSD|NY Harbor/i.test(titleText)) field = 'ulsd';
    else if (/Brent/i.test(titleText)) field = 'brent';
    else if (/WTI|Light Sweet|Crude Oil/i.test(titleText)) field = 'wti';
    if (!field) return [];

    const out = [];

    let price = metaNumber('price');
    let priceRaw = price !== null ? 'meta[name=price]' : '';
    if (price === null) {
      const found = firstNumberFrom(['h2.intraday__price .value']);
      if (found) { price = found.value; priceRaw = found.rawText; }
    }
    if (price !== null) out.push({ field, value: price, rawText: priceRaw });

    // The quote page already computes the official 24h change -- use it
    // directly for the fields the report form has a same-day change input
    // for, instead of waiting on multi-day capture history to derive it.
    const DIRECT_CHANGE_FIELD = { rbob: 'rbob_chg24h', ulsd: 'ulsd_chg24h' };
    if (DIRECT_CHANGE_FIELD[field]) {
      let change = metaNumber('priceChange');
      let changeRaw = change !== null ? 'meta[name=priceChange]' : '';
      if (change === null) {
        const found = firstNumberFrom(['.intraday__change .change--point--q']);
        if (found) { change = found.value; changeRaw = found.rawText; }
      }
      if (change !== null) out.push({ field: DIRECT_CHANGE_FIELD[field], value: round2(change * 100), rawText: changeRaw });
    }

    if (out.length) return out;
    // fallback: scan the top of the page's visible text
    const bodyText = document.body.innerText.slice(0, 1200);
    const nums = numbersNear(bodyText);
    if (nums.length) return [{ field, value: nums[0], rawText: 'page-text fallback: ' + bodyText.slice(0, 80) }];
    return null; // null = not found yet (may still be rendering)
  }

  /* ---------------- EIA weekly PADD 2 stocks page ---------------- */
  function captureEIA() {
    if (!/eia\.gov$/.test(location.hostname)) return [];
    if (!/\/dnav\/pet\//.test(location.pathname)) return [];
    const titleText = document.title + ' ' + ((document.querySelector('h1, h2') || {}).textContent || '');
    let field = null;
    if (/Distillate|Diesel|Fuel Oil/i.test(titleText)) field = 'padd2_distillate_stock';
    else if (/Gasoline/i.test(titleText)) field = 'padd2_gas_stock';
    if (!field) return [];

    const rows = [...document.querySelectorAll('table tr')];
    for (const row of rows) {
      const cells = [...row.querySelectorAll('td,th')];
      if (!cells.length) continue;
      const labelText = cells[0].textContent || '';
      if (!/PADD\s*2|Midwest/i.test(labelText)) continue;
      for (let i = 1; i < cells.length; i++) {
        const numMatch = (cells[i].textContent || '').match(/-?[\d,]+(?:\.\d+)?/);
        if (numMatch) {
          const value = parseFloat(numMatch[0].replace(/,/g, ''));
          const rawText = cells.map(c => c.textContent.trim()).join(' | ').slice(0, 90);
          return [{ field, value, rawText }];
        }
      }
    }
    return null;
  }

  /* ---------------- AAA state gas prices page ---------------- */
  function captureAAA() {
    if (location.hostname !== 'gasprices.aaa.com') return [];
    const params = new URLSearchParams(location.search);
    const state = (params.get('state') || '').toUpperCase();
    if (!state) return null;
    const gasField = state === 'WI' ? 'wi_avg_gas' : (state === 'MN' ? 'twin_cities_gas' : null);
    const dieselField = state === 'WI' ? 'wi_avg_diesel' : (state === 'MN' ? 'twin_cities_diesel' : null);
    if (!gasField) return [];

    const text = document.body.innerText;
    const out = [];
    const regMatch = text.match(/Regular[\s\S]{0,50}?\$?\s?(\d\.\d{2,3})/i);
    if (regMatch) out.push({ field: gasField, value: parseFloat(regMatch[1]), rawText: regMatch[0].slice(0, 80) });
    const dieselMatch = text.match(/Diesel[\s\S]{0,50}?\$?\s?(\d\.\d{2,3})/i);
    if (dieselMatch && dieselField) out.push({ field: dieselField, value: parseFloat(dieselMatch[1]), rawText: dieselMatch[0].slice(0, 80) });
    return out.length ? out : null;
  }

  /* ---------------- GasBuddy city price list ---------------- */
  function captureGasBuddy() {
    if (location.hostname !== 'www.gasbuddy.com') return [];
    if (!/\/gasprices\//.test(location.pathname) && !/\/diesel/.test(location.pathname)) return [];
    const path = location.pathname.toLowerCase();
    let baseField = null;
    if (path.includes('new-auburn')) baseField = 'new_auburn';
    else if (path.includes('chippewa-falls')) baseField = 'chippewa';
    else if (path.includes('eau-claire')) baseField = 'eau_claire';
    else if (path.includes('minneapolis') || path.includes('st-paul')) baseField = 'twin_cities';
    if (!baseField) return [];

    const isDiesel = /diesel/i.test(document.title) || /diesel/i.test(location.pathname) ||
      !!document.querySelector('[aria-selected="true"]')?.textContent?.match(/diesel/i);
    const field = baseField + (isDiesel ? '_diesel' : '_gas');

    const text = document.body.innerText;
    const nums = numbersNear(text).filter(n => n >= 1.5 && n <= 7.5);
    if (nums.length < 2) return null; // page probably hasn't finished rendering the station list
    const med = median(nums);
    return [{ field, value: med, rawText: `median of ${nums.length} visible station prices` }];
  }

  /* ---------------- OilPrice.com charts page (Brent/WTI backup) ---------------- */
  function captureOilPrice() {
    if (location.hostname !== 'oilprice.com') return [];
    const text = document.body.innerText;
    const out = [];
    const brent = text.match(/Brent\s*Crude[\s\S]{0,40}?(\d{2,3}\.\d{2})/i);
    if (brent) out.push({ field: 'brent', value: parseFloat(brent[1]), rawText: brent[0].slice(0, 60) });
    const wti = text.match(/WTI\s*Crude[\s\S]{0,40}?(\d{2,3}\.\d{2})/i);
    if (wti) out.push({ field: 'wti', value: parseFloat(wti[1]), rawText: wti[0].slice(0, 60) });
    return out.length ? out : null;
  }

  const CAPTURERS = [captureMarketWatch, captureEIA, captureAAA, captureGasBuddy, captureOilPrice];

  function attemptCapture() {
    for (const fn of CAPTURERS) {
      const result = fn();
      if (result === null) return 'pending'; // recognized page, not ready yet
      if (Array.isArray(result) && result.length) return result;
    }
    return 'unmatched';
  }

  function sendCandidates(results) {
    results.forEach(r => {
      chrome.runtime.sendMessage({
        type: 'FA_CAPTURE_CANDIDATE',
        field: r.field, value: r.value, rawText: r.rawText,
        url: location.href, title: document.title
      });
    });
  }

  function run() {
    const result = attemptCapture();
    if (Array.isArray(result)) { sendCandidates(result); return; }
    if (result === 'unmatched') return; // no capturer recognizes this URL at all

    // 'pending': page matched a known source but data isn't rendered yet.
    // Watch for it for up to ~12s (covers client-rendered AAA/GasBuddy pages).
    let settled = false;
    const observer = new MutationObserver(debounce(() => {
      if (settled) return;
      const r = attemptCapture();
      if (Array.isArray(r) && r.length) { settled = true; observer.disconnect(); sendCandidates(r); }
    }, 600));
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    setTimeout(() => {
      if (settled) return;
      observer.disconnect();
      chrome.runtime.sendMessage({ type: 'FA_CAPTURE_FAILED', url: location.href, title: document.title, reason: 'page matched a known source but no value rendered in time' });
    }, 12000);
  }

  function debounce(fn, ms) {
    let t;
    return (...args) => { clearTimeout(t); t = setTimeout(() => fn(...args), ms); };
  }

  run();
})();
