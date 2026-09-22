/* Shared constants & helpers used by background.js, content-capture.js,
   content-fill.js and popup.js. Plain script (no import/export) so it can be
   loaded via <script> (popup), importScripts() (service worker), and as a
   content-script file listed before the others in manifest.json. */

const FUEL_AGENT_STORAGE_KEY = 'fuelAgentCaptureState_v1';
const FUEL_APP_URL_PREFIX = 'https://jonpederson.github.io/fuel/';

/* Every trackable data point. `unit` controls how deltas are computed/shown.
   `appField` is the <input>/<select> id on the fuel report page that the
   *current value* fills. `sane` is an [min,max] plausibility range used to
   reject obviously-wrong scrapes before ever showing them to the user. */
const FIELD_META = {
  rbob:               { label: 'RBOB gasoline futures',      unit: 'usd_per_gal', kind: 'level', appField: 'g_rbob_now',        sane: [0.5, 6] },
  ulsd:               { label: 'ULSD diesel futures',        unit: 'usd_per_gal', kind: 'level', appField: 'd_ulsd_now',        sane: [0.5, 6] },
  rbob_m2:            { label: 'RBOB 2nd-month contract',    unit: 'usd_per_gal', kind: 'level', appField: 'g_rbob_m2',         sane: [0.5, 6] },
  ulsd_m2:            { label: 'ULSD 2nd-month contract',    unit: 'usd_per_gal', kind: 'level', appField: 'd_ulsd_m2',         sane: [0.5, 6] },
  brent:               { label: 'Brent crude',                unit: 'usd_per_bbl', kind: 'level', appField: 'brent_now',         sane: [15, 200] },
  wti:                 { label: 'WTI crude',                  unit: 'usd_per_bbl', kind: 'level', appField: 'wti_now',           sane: [15, 200] },
  new_auburn_gas:      { label: 'New Auburn regular',         unit: 'usd_per_gal', kind: 'level', appField: 'g_price_newauburn', sane: [1, 8] },
  new_auburn_diesel:   { label: 'New Auburn diesel',          unit: 'usd_per_gal', kind: 'level', appField: 'd_price_newauburn', sane: [1, 8] },
  chippewa_gas:        { label: 'Chippewa Falls regular',     unit: 'usd_per_gal', kind: 'level', appField: 'g_price_chippewa',  sane: [1, 8] },
  chippewa_diesel:     { label: 'Chippewa Falls diesel',      unit: 'usd_per_gal', kind: 'level', appField: 'd_price_chippewa',  sane: [1, 8] },
  eau_claire_gas:      { label: 'Eau Claire regular',         unit: 'usd_per_gal', kind: 'level', appField: 'g_price_eauclaire', sane: [1, 8] },
  eau_claire_diesel:   { label: 'Eau Claire diesel',          unit: 'usd_per_gal', kind: 'level', appField: 'd_price_eauclaire', sane: [1, 8] },
  wi_avg_gas:          { label: 'Wisconsin avg regular',      unit: 'usd_per_gal', kind: 'level', appField: 'g_price_wiavg',     sane: [1, 8] },
  wi_avg_diesel:       { label: 'Wisconsin avg diesel',       unit: 'usd_per_gal', kind: 'level', appField: 'd_price_wiavg',     sane: [1, 8] },
  twin_cities_gas:     { label: 'Twin Cities regular',        unit: 'usd_per_gal', kind: 'level', appField: 'g_price_twincities', sane: [1, 8] },
  twin_cities_diesel:  { label: 'Twin Cities diesel',         unit: 'usd_per_gal', kind: 'level', appField: 'd_price_twincities', sane: [1, 8] },
  padd2_gas_stock:     { label: 'PADD 2 gasoline stocks',     unit: 'kbbl',        kind: 'level', appField: null,                sane: [50000, 400000] },
  padd2_distillate_stock: { label: 'PADD 2 distillate stocks', unit: 'kbbl',       kind: 'level', appField: null,                sane: [20000, 200000] },
  /* Direct pass-through: the source page already computes these as a change
     (not a level), e.g. MarketWatch's own 24h price-change figure. No
     history/delta math applies -- the captured value goes straight to its
     report field once confirmed. */
  rbob_chg24h:         { label: 'RBOB 24h change (quote page)', unit: 'cents', kind: 'change', appField: 'g_rbob_chg24h', sane: [-60, 60] },
  ulsd_chg24h:         { label: 'ULSD 24h change (quote page)', unit: 'cents', kind: 'change', appField: 'd_ulsd_chg24h', sane: [-60, 60] }
};

const QUICK_LINKS = [
  { field: 'rbob', label: 'RBOB futures (MarketWatch)', url: 'https://www.marketwatch.com/investing/future/rb.1' },
  { field: 'ulsd', label: 'ULSD futures (MarketWatch)', url: 'https://www.marketwatch.com/investing/future/ho.1' },
  { field: 'rbob_m2', label: 'RBOB 2nd-month contract (term structure)', url: 'https://www.marketwatch.com/investing/future/rb.2' },
  { field: 'ulsd_m2', label: 'ULSD 2nd-month contract (term structure)', url: 'https://www.marketwatch.com/investing/future/ho.2' },
  { field: 'brent', label: 'Brent crude (MarketWatch)', url: 'https://www.marketwatch.com/investing/future/bz.1' },
  { field: 'wti', label: 'WTI crude (MarketWatch)', url: 'https://www.marketwatch.com/investing/future/cl.1' },
  { field: 'padd2_gas_stock', label: 'EIA PADD 2 gasoline stocks', url: 'https://www.eia.gov/dnav/pet/pet_stoc_wstk_dcu_r20_w.htm' },
  { field: 'padd2_distillate_stock', label: 'EIA PADD 2 distillate stocks', url: 'https://www.eia.gov/dnav/pet/pet_stoc_wstk_dcu_r20_w.htm' },
  { field: 'wi_avg_gas', label: 'EIA weekly regional gas/diesel prices', url: 'https://www.eia.gov/petroleum/gasdiesel/' },
  { field: 'wi_avg_gas', label: 'AAA Wisconsin gas prices', url: 'https://gasprices.aaa.com/?state=WI' },
  { field: 'twin_cities_gas', label: 'AAA Minnesota gas prices', url: 'https://gasprices.aaa.com/?state=MN' },
  { field: 'wi_avg_gas', label: 'GasBuddy — USA state prices (WI/MN)', url: 'https://www.gasbuddy.com/usa' },
  { field: 'new_auburn_gas', label: 'GasBuddy — New Auburn, WI', url: 'https://www.gasbuddy.com/gasprices/wisconsin/new-auburn' },
  { field: 'chippewa_gas', label: 'GasBuddy — Chippewa Falls, WI', url: 'https://www.gasbuddy.com/gasprices/wisconsin/chippewa-falls' },
  { field: 'eau_claire_gas', label: 'GasBuddy — Eau Claire, WI', url: 'https://www.gasbuddy.com/gasprices/wisconsin/eau-claire' },
  { field: 'twin_cities_gas', label: 'GasBuddy — Minneapolis, MN', url: 'https://www.gasbuddy.com/gasprices/minnesota/minneapolis' },
  { field: 'twin_cities_gas', label: 'GasBuddy — St. Paul, MN', url: 'https://www.gasbuddy.com/gasprices/minnesota/st-paul' },
  { field: 'new_auburn_diesel', label: 'GasBuddy — Diesel map', url: 'https://www.gasbuddy.com/diesel' }
];

function faChicagoDateKey(d) {
  d = d || new Date();
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Chicago', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(d);
  const get = t => parts.find(p => p.type === t).value;
  return `${get('year')}-${get('month')}-${get('day')}`;
}

/* Dedupe a history array to one entry per Chicago calendar day (latest
   capture that day wins), sorted most-recent-day first. */
function faHistoryDaysDesc(arr) {
  const byDay = new Map();
  (arr || []).forEach(entry => {
    const existing = byDay.get(entry.date);
    if (!existing || entry.ts > existing.ts) byDay.set(entry.date, entry);
  });
  return [...byDay.values()].sort((a, b) => b.date.localeCompare(a.date));
}

/* value at `stepsBack` distinct trading/calendar days before the most recent
   capture, or null if not enough history yet. */
function faDeltaVsStepsBack(arrDesc, stepsBack) {
  if (arrDesc.length <= stepsBack) return null;
  const cur = arrDesc[0];
  const prior = arrDesc[stepsBack];
  return { curValue: cur.value, priorValue: prior.value, curDate: cur.date, priorDate: prior.date, diff: cur.value - prior.value };
}

function faFmtAge(ts) {
  const mins = Math.round((Date.now() - ts) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return mins + 'm ago';
  const hrs = Math.round(mins / 60);
  if (hrs < 48) return hrs + 'h ago';
  return Math.round(hrs / 24) + 'd ago';
}

if (typeof module !== 'undefined') {
  module.exports = { FIELD_META, QUICK_LINKS, faChicagoDateKey, faHistoryDaysDesc, faDeltaVsStepsBack, faFmtAge, FUEL_AGENT_STORAGE_KEY, FUEL_APP_URL_PREFIX };
}
