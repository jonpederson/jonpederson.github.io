importScripts('shared.js');

const EMPTY_STATE = { history: {}, pending: [], failures: [] };

async function loadState() {
  const got = await chrome.storage.local.get(FUEL_AGENT_STORAGE_KEY);
  const state = got[FUEL_AGENT_STORAGE_KEY];
  if (!state) return structuredClone(EMPTY_STATE);
  state.history = state.history || {};
  state.pending = state.pending || [];
  state.failures = state.failures || [];
  return state;
}
async function saveState(state) {
  await chrome.storage.local.set({ [FUEL_AGENT_STORAGE_KEY]: state });
  updateBadge(state);
}
function updateBadge(state) {
  const n = state.pending.length;
  chrome.action.setBadgeText({ text: n ? String(n) : '' });
  chrome.action.setBadgeBackgroundColor({ color: '#c8401a' });
}

function inRange(field, value) {
  const meta = FIELD_META[field];
  if (!meta || typeof value !== 'number' || Number.isNaN(value)) return false;
  return value >= meta.sane[0] && value <= meta.sane[1];
}

/* Per-field computed summary: latest value + deltas derived from stored
   day-bucketed history, per the field's unit semantics. */
function computeSummary(state) {
  const out = {};
  for (const field of Object.keys(FIELD_META)) {
    const arrDesc = faHistoryDaysDesc(state.history[field] || []);
    if (arrDesc.length === 0) { out[field] = { latest: null, arrDesc }; continue; }
    const d1 = faDeltaVsStepsBack(arrDesc, 1);
    const d3 = faDeltaVsStepsBack(arrDesc, 3);
    const d5 = faDeltaVsStepsBack(arrDesc, 5);
    out[field] = { latest: arrDesc[0], arrDesc, chg1: d1, chg3: d3, chg5: d5 };
  }
  return out;
}

function momentumFromHistory(arrDesc) {
  if (arrDesc.length < 4) return 'none';
  const d1 = arrDesc[0].value - arrDesc[1].value;
  const d2 = arrDesc[1].value - arrDesc[2].value;
  const d3 = arrDesc[2].value - arrDesc[3].value;
  const sameSign = (a, b) => (a > 0 && b > 0) || (a < 0 && b < 0);
  if (sameSign(d1, d2) && sameSign(d2, d3) && Math.abs(d1) > Math.abs(d2) && Math.abs(d2) >= Math.abs(d3)) {
    return d1 > 0 ? 'up' : 'down';
  }
  return 'none';
}

function buildAutofillPayload(state) {
  const s = computeSummary(state);
  const payload = {}; // appFieldId -> value (string/number) ; only set when we have real data
  const notes = [];

  const setCurrent = (field) => {
    const meta = FIELD_META[field];
    if (meta.appField && s[field].latest) payload[meta.appField] = s[field].latest.value;
  };
  ['rbob', 'ulsd', 'brent', 'wti', 'new_auburn_gas', 'new_auburn_diesel', 'chippewa_gas', 'chippewa_diesel',
   'eau_claire_gas', 'eau_claire_diesel', 'wi_avg_gas', 'wi_avg_diesel', 'twin_cities_gas', 'twin_cities_diesel']
    .forEach(setCurrent);

  // Prefer the quote page's own official 24h change (captured today) over
  // our day-over-day history delta -- it's exchange-computed and doesn't
  // need two days of capture history to exist yet. Fall back to the delta
  // otherwise (e.g. the source page's change figure wasn't found).
  const today = faChicagoDateKey();
  const setChg24h = (directField, appId, levelSummary) => {
    const direct = s[directField].latest;
    if (direct && direct.date === today) payload[appId] = round2(direct.value);
    else if (levelSummary.chg1) payload[appId] = round2(levelSummary.chg1.diff * 100);
  };
  setChg24h('rbob_chg24h', 'g_rbob_chg24h', s.rbob);
  setChg24h('ulsd_chg24h', 'd_ulsd_chg24h', s.ulsd);

  if (s.rbob.chg3) payload.g_rbob_chg3s = round2(s.rbob.chg3.diff * 100);
  if (s.rbob.chg5) payload.g_rbob_chg5s = round2(s.rbob.chg5.diff * 100);
  if (s.ulsd.chg3) payload.d_ulsd_chg3s = round2(s.ulsd.chg3.diff * 100);
  if (s.ulsd.chg5) payload.d_ulsd_chg5s = round2(s.ulsd.chg5.diff * 100);
  if (s.brent.chg3) payload.brent_chg3s = round2(s.brent.chg3.diff);
  if (s.wti.chg3) payload.wti_chg3s = round2(s.wti.chg3.diff);

  const rMom = momentumFromHistory(s.rbob.arrDesc);
  if (rMom !== 'none') { payload.g_rbob_momentum = rMom; notes.push('RBOB momentum auto-suggested from your capture history — verify.'); }
  const uMom = momentumFromHistory(s.ulsd.arrDesc);
  if (uMom !== 'none') { payload.d_ulsd_trend = uMom === 'up' ? 'up3' : 'down3'; notes.push('ULSD momentum auto-suggested from your capture history — verify.'); }

  if (s.eau_claire_gas.chg1) {
    const diff = s.eau_claire_gas.chg1.diff;
    payload.g_ec_dir = diff > 0.001 ? 'increase' : (diff < -0.001 ? 'decrease' : 'flat');
    payload.g_ec_mag = round1(Math.abs(diff) * 100);
  }
  if (s.eau_claire_diesel.chg1) {
    const diff = s.eau_claire_diesel.chg1.diff;
    payload.d_ec_dir = diff > 0.001 ? 'increase' : (diff < -0.001 ? 'decrease' : 'flat');
    payload.d_ec_mag = round1(Math.abs(diff) * 100);
  }
  if (s.twin_cities_gas.chg1 && s.twin_cities_gas.chg1.diff > 0) {
    payload.g_tc_restoration = round1(s.twin_cities_gas.chg1.diff * 100);
    notes.push('Twin Cities restoration figure is auto-computed — confirm it reflects several stations/a chain before checking "broad move."');
  }
  const tc3to5 = faDeltaVsStepsBack(s.twin_cities_gas.arrDesc, Math.min(4, Math.max(s.twin_cities_gas.arrDesc.length - 1, 0)));
  if (tc3to5 && tc3to5.diff < 0) payload.g_tc_decline35 = round1(tc3to5.diff * 100);

  if (s.padd2_gas_stock.chg1) payload.g_padd2_wow = round2((s.padd2_gas_stock.chg1.diff / s.padd2_gas_stock.chg1.priorValue) * 100);
  if (s.padd2_distillate_stock.chg1) payload.d_padd2_wow = round2((s.padd2_distillate_stock.chg1.diff / s.padd2_distillate_stock.chg1.priorValue) * 100);

  return { payload, notes, filledCount: Object.keys(payload).length };
}
function round2(x) { return Math.round(x * 100) / 100; }
function round1(x) { return Math.round(x * 10) / 10; }

async function findOrOpenFuelTab() {
  const tabs = await chrome.tabs.query({ url: FUEL_APP_URL_PREFIX + '*' });
  if (tabs.length > 0) {
    await chrome.tabs.update(tabs[0].id, { active: true });
    return tabs[0];
  }
  const tab = await chrome.tabs.create({ url: FUEL_APP_URL_PREFIX, active: true });
  await new Promise(resolve => {
    function listener(tabId, info) {
      if (tabId === tab.id && info.status === 'complete') {
        chrome.tabs.onUpdated.removeListener(listener);
        resolve();
      }
    }
    chrome.tabs.onUpdated.addListener(listener);
    setTimeout(resolve, 8000); // fallback if 'complete' never fires
  });
  return tab;
}

/* Serialize all storage-touching work: chrome.storage.local.get/set is not
   atomic, and two messages arriving close together (e.g. an AAA page
   reporting both its gas and diesel candidates back-to-back) can otherwise
   race a read-modify-write and silently drop one of them. */
let writeQueue = Promise.resolve();
function enqueue(fn) {
  const result = writeQueue.then(fn, fn);
  writeQueue = result.catch(() => {});
  return result;
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  enqueue(async () => {
    const state = await loadState();

    if (msg.type === 'FA_CAPTURE_CANDIDATE') {
      const suspect = !inRange(msg.field, msg.value);
      const dupIdx = state.pending.findIndex(p => p.field === msg.field && p.url === msg.url);
      const item = {
        id: dupIdx >= 0 ? state.pending[dupIdx].id : 'p' + Date.now() + Math.random().toString(36).slice(2, 7),
        field: msg.field, value: msg.value, rawText: msg.rawText || '', url: msg.url, title: msg.title || '',
        capturedAt: Date.now(), suspect
      };
      if (dupIdx >= 0) state.pending[dupIdx] = item; else state.pending.unshift(item);
      state.pending = state.pending.slice(0, 40);
      await saveState(state);
      return { ok: true };
    }

    if (msg.type === 'FA_CAPTURE_FAILED') {
      state.failures.unshift({ url: msg.url, title: msg.title || '', reason: msg.reason || 'no value found', ts: Date.now() });
      state.failures = state.failures.slice(0, 20);
      await saveState(state);
      return { ok: true };
    }

    if (msg.type === 'FA_GET_STATE') {
      return { state, summary: computeSummary(state) };
    }

    if (msg.type === 'FA_CONFIRM_PENDING') {
      const idx = state.pending.findIndex(p => p.id === msg.id);
      if (idx >= 0) {
        const item = state.pending[idx];
        const value = typeof msg.value === 'number' ? msg.value : item.value;
        const date = faChicagoDateKey();
        const arr = state.history[item.field] || [];
        const dayIdx = arr.findIndex(e => e.date === date);
        const entry = { date, value, ts: Date.now(), url: item.url };
        if (dayIdx >= 0) arr[dayIdx] = entry; else arr.push(entry);
        state.history[item.field] = arr.slice(-40);
        state.pending.splice(idx, 1);
        await saveState(state);
      }
      return { ok: true, state, summary: computeSummary(state) };
    }

    if (msg.type === 'FA_REJECT_PENDING') {
      state.pending = state.pending.filter(p => p.id !== msg.id);
      await saveState(state);
      return { ok: true, state };
    }

    if (msg.type === 'FA_CLEAR_ALL') {
      await saveState(structuredClone(EMPTY_STATE));
      return { ok: true };
    }

    if (msg.type === 'FA_REQUEST_AUTOFILL') {
      const { payload, notes, filledCount } = buildAutofillPayload(state);
      if (filledCount === 0) return { ok: false, error: 'No confirmed data yet — capture and confirm at least one source first.' };
      try {
        const tab = await findOrOpenFuelTab();
        const resp = await chrome.tabs.sendMessage(tab.id, { type: 'FA_AUTOFILL', payload, notes });
        return { ok: true, filledCount, notes, fillResult: resp };
      } catch (e) {
        return { ok: false, error: 'Could not reach the fuel report tab: ' + e.message };
      }
    }
  }).then(sendResponse);
  return true; // keep the message channel open for the async response
});

chrome.runtime.onInstalled.addListener(async () => {
  const state = await loadState();
  await saveState(state);
});
