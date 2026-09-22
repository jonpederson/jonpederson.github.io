let currentState = null;
let currentSummary = null;

function send(msg) {
  return new Promise(resolve => chrome.runtime.sendMessage(msg, resolve));
}

async function refresh() {
  const resp = await send({ type: 'FA_GET_STATE' });
  currentState = resp.state;
  currentSummary = resp.summary;
  renderPending();
  renderFailures();
  renderCaptured();
}

function renderPending() {
  const list = document.getElementById('pendingList');
  const countEl = document.getElementById('pendingCount');
  const pending = currentState.pending || [];
  countEl.textContent = String(pending.length);
  countEl.style.display = pending.length ? 'inline-block' : 'none';

  if (!pending.length) {
    list.innerHTML = '<p class="empty">Nothing waiting. Visit a source site to capture data.</p>';
    return;
  }
  list.innerHTML = '';
  pending.forEach(item => {
    const meta = FIELD_META[item.field] || { label: item.field };
    const div = document.createElement('div');
    div.className = 'pending-item' + (item.suspect ? ' suspect' : '');
    div.innerHTML = `
      <div class="top"><span class="field-label">${meta.label}</span><span class="src">${new URL(item.url).hostname}</span></div>
      <div class="src">${escapeHtml(item.url)}</div>
      ${item.rawText ? `<div class="raw">"${escapeHtml(item.rawText)}"</div>` : ''}
      ${item.suspect ? `<div class="warn">Value looks out of the normal range for this field — double-check before accepting.</div>` : ''}
      <div class="row2">
        <input type="number" step="0.0001" value="${item.value}" data-id="${item.id}" class="edit-value" />
        <button class="mini accept" data-id="${item.id}">Accept</button>
        <button class="mini reject" data-id="${item.id}">Reject</button>
      </div>
    `;
    list.appendChild(div);
  });

  list.querySelectorAll('.accept').forEach(btn => btn.addEventListener('click', async () => {
    const id = btn.dataset.id;
    const input = list.querySelector(`.edit-value[data-id="${id}"]`);
    const value = parseFloat(input.value);
    const resp = await send({ type: 'FA_CONFIRM_PENDING', id, value });
    currentState = resp.state; currentSummary = resp.summary;
    renderPending(); renderCaptured();
    toast('Saved to history.');
  }));
  list.querySelectorAll('.reject').forEach(btn => btn.addEventListener('click', async () => {
    const resp = await send({ type: 'FA_REJECT_PENDING', id: btn.dataset.id });
    currentState = resp.state;
    renderPending();
  }));
}

function renderFailures() {
  const el = document.getElementById('failuresList');
  const fails = (currentState.failures || []).slice(0, 4);
  if (!fails.length) { el.innerHTML = ''; return; }
  el.innerHTML = '<div class="fail-item" style="border-top:none;color:var(--muted);">Couldn’t auto-read (enter manually on the report):</div>' +
    fails.map(f => `<div class="fail-item">${escapeHtml(new URL(f.url).hostname + f.url.replace(new URL(f.url).origin, ''))}</div>`).join('');
}

function fmtVal(field, v) {
  const meta = FIELD_META[field];
  if (meta.unit === 'usd_per_gal') return '$' + v.toFixed(4);
  if (meta.unit === 'usd_per_bbl') return '$' + v.toFixed(2);
  if (meta.unit === 'cents') return (v >= 0 ? '+' : '') + v.toFixed(2) + '¢';
  return v.toLocaleString();
}
function fmtDelta(d, field) {
  if (!d) return '<span style="color:var(--muted)">need more days</span>';
  const meta = FIELD_META[field];
  const cents = meta.unit === 'usd_per_gal' ? d.diff * 100 : d.diff;
  const cls = cents > 0 ? 'delta-pos' : (cents < 0 ? 'delta-neg' : '');
  const unit = meta.unit === 'usd_per_bbl' ? '$' : '¢';
  return `<span class="${cls}">${cents >= 0 ? '+' : ''}${cents.toFixed(unit === '$' ? 2 : 1)}${unit}</span>`;
}

function renderCaptured() {
  const el = document.getElementById('capturedList');
  const fields = Object.keys(FIELD_META).filter(f => currentSummary[f] && currentSummary[f].latest);
  if (!fields.length) {
    el.innerHTML = '<p class="empty">No confirmed data yet.</p>';
    return;
  }
  let html = '<table class="captable"><thead><tr><th>Field</th><th class="num">Latest</th><th class="num">24h</th><th class="num">3-sess</th><th class="num">5-sess</th></tr></thead><tbody>';
  fields.forEach(f => {
    const s = currentSummary[f];
    const age = faFmtAge(s.latest.ts);
    const stale = (Date.now() - s.latest.ts) > 48 * 3600 * 1000;
    const isChange = FIELD_META[f].kind === 'change';
    html += `<tr>
      <td>${FIELD_META[f].label}<br><span class="${stale ? 'age-stale' : ''}" style="color:var(--muted);font-size:0.58rem;">${age}</span></td>
      <td class="num">${fmtVal(f, s.latest.value)}</td>
      <td class="num">${isChange ? '<span style="color:var(--muted)">n/a</span>' : fmtDelta(s.chg1, f)}</td>
      <td class="num">${isChange ? '<span style="color:var(--muted)">n/a</span>' : fmtDelta(s.chg3, f)}</td>
      <td class="num">${isChange ? '<span style="color:var(--muted)">n/a</span>' : fmtDelta(s.chg5, f)}</td>
    </tr>`;
  });
  html += '</tbody></table>';
  el.innerHTML = html;
}

function renderQuickLinks() {
  const el = document.getElementById('quickLinks');
  el.innerHTML = '';
  QUICK_LINKS.forEach(l => {
    const btn = document.createElement('button');
    btn.textContent = l.label;
    btn.addEventListener('click', () => chrome.tabs.create({ url: l.url, active: true }));
    el.appendChild(btn);
  });
}

function toast(text) {
  const el = document.getElementById('toast');
  el.textContent = text;
  el.style.display = 'block';
  clearTimeout(el._t);
  el._t = setTimeout(() => { el.style.display = 'none'; }, 3500);
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

document.getElementById('autofillBtn').addEventListener('click', async () => {
  const btn = document.getElementById('autofillBtn');
  btn.disabled = true; btn.textContent = 'Filling…';
  const resp = await send({ type: 'FA_REQUEST_AUTOFILL' });
  btn.disabled = false; btn.textContent = 'Autofill Wisconsin Fuel Report';
  if (resp.ok) toast(`Filled ${resp.filledCount} field(s) on the report tab.`);
  else toast(resp.error || 'Autofill failed.');
});

document.getElementById('openAppBtn').addEventListener('click', () => {
  chrome.tabs.create({ url: FUEL_APP_URL_PREFIX, active: true });
});

document.getElementById('clearBtn').addEventListener('click', async () => {
  if (!confirm('Delete all captured & pending data from this extension? This cannot be undone.')) return;
  await send({ type: 'FA_CLEAR_ALL' });
  await refresh();
  toast('Cleared.');
});

renderQuickLinks();
refresh();
