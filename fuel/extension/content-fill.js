/* Runs on the fuel report page. Fills form fields from data the extension
   captured & the user confirmed, then lets the page's own <input> listeners
   (already wired for autosave + live recalculation) do the rest. */

(function () {
  function showToast(text) {
    let el = document.getElementById('fa-ext-toast');
    if (!el) {
      el = document.createElement('div');
      el.id = 'fa-ext-toast';
      el.style.cssText = 'position:fixed;left:50%;bottom:1.5rem;transform:translateX(-50%);' +
        'background:#0f0e0c;color:#f5f0e8;padding:0.85rem 1.25rem;font-family:"DM Mono",monospace;' +
        'font-size:0.78rem;letter-spacing:0.02em;z-index:99999;max-width:90vw;box-shadow:0 8px 30px rgba(0,0,0,0.35);' +
        'border-left:4px solid #c8401a;line-height:1.5;';
      document.body.appendChild(el);
    }
    el.textContent = text;
    el.style.display = 'block';
    clearTimeout(el._t);
    el._t = setTimeout(() => { el.style.display = 'none'; }, 6000);
  }

  function fillField(id, value) {
    const el = document.getElementById(id);
    if (!el) return false;
    const details = el.closest('details');
    if (details) details.open = true;
    if (el.tagName === 'SELECT') {
      el.value = value;
    } else {
      el.value = typeof value === 'number' ? value : value;
    }
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.classList.add('fa-ext-filled');
    return true;
  }

  // subtle highlight for freshly-filled fields
  const style = document.createElement('style');
  style.textContent = '.fa-ext-filled{outline:2px solid #c8401a;outline-offset:1px;transition:outline-color 2.5s ease;}';
  document.head.appendChild(style);
  setTimeout(() => {
    document.querySelectorAll('.fa-ext-filled').forEach(el => { el.style.outlineColor = 'transparent'; });
  }, 2600);

  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg.type !== 'FA_AUTOFILL') return;
    const payload = msg.payload || {};
    let filled = 0, missing = [];
    Object.entries(payload).forEach(([id, value]) => {
      if (fillField(id, value)) filled++; else missing.push(id);
    });
    const parts = [`Autofilled ${filled} field${filled === 1 ? '' : 's'} from captured data.`];
    if (missing.length) parts.push(`${missing.length} field id(s) not found on this page version.`);
    parts.push('Broad-move, catch-up, cycle-position, disruption/news, crack-spread and seasonal judgment calls still need your review.');
    if (msg.notes && msg.notes.length) parts.push(...msg.notes);
    showToast(parts.join(' '));
    sendResponse({ ok: true, filled, missing });
  });
})();
