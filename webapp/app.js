'use strict';
/* Cortex Desktop — local web UI (Phase A: search · open · edit · save).
   Served same-origin by the cortex engine, so all fetches are relative. */

const $ = (sel) => document.querySelector(sel);
const els = {
  status: $('#status'), q: $('#q'), list: $('#list'), path: $('#path'),
  body: $('#body'), save: $('#save'), dirty: $('#dirty'), toast: $('#toast'),
};

const state = { path: null, original: '', mode: 'semantic', external: false };

// --- api -------------------------------------------------------------------
async function api(path, opts) {
  const r = await fetch(path, opts);
  const ct = r.headers.get('content-type') || '';
  const data = ct.includes('json') ? await r.json() : await r.text();
  if (!r.ok || (data && data.error)) throw new Error((data && data.error) || ('HTTP ' + r.status));
  return data;
}
const post = (path, body) =>
  api(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

// --- health ----------------------------------------------------------------
async function refreshHealth() {
  try {
    const h = await api('/health');
    const ext = h.external ? ` · ${h.external} external` : '';
    els.status.textContent = `${h.notes} notes · ${h.chunks} chunks${ext}`;
    els.status.className = 'status status--ok';
  } catch {
    els.status.textContent = 'engine offline';
    els.status.className = 'status status--bad';
  }
}

// --- list / search ---------------------------------------------------------
function basename(p) { return (p.split('/').pop() || p).replace(/\.md$/, ''); }
function isExternal(p) { return p.startsWith('/'); }

function renderItems(items) {
  els.list.innerHTML = '';
  if (!items.length) { els.list.innerHTML = '<div class="empty">No matches.</div>'; return; }
  for (const it of items) {
    const div = document.createElement('div');
    div.className = 'item' + (it.path === state.path ? ' item--active' : '') +
                    (isExternal(it.path) ? ' item--external' : '');
    const score = it.score != null ? `<span class="item-score">${Number(it.score).toFixed(3)}</span>` : '';
    div.innerHTML =
      `${score}<div class="item-title">${esc(basename(it.path))}</div>` +
      `<div class="item-ctx">${esc(it.heading || it.path)}</div>` +
      (it.text ? `<div class="item-snip">${esc(it.text)}</div>` : '');
    div.onclick = () => openNote(it.path);
    els.list.appendChild(div);
  }
}

async function showNotes() {
  try {
    const paths = await api('/list?limit=500');
    renderItems(paths.map((p) => ({ path: p })));
  } catch (e) { els.list.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}

let searchSeq = 0;
async function runSearch(query) {
  query = query.trim();
  if (!query) return showNotes();
  const seq = ++searchSeq;
  els.list.innerHTML = '<div class="loading">Searching…</div>';
  try {
    const hits = await post(state.mode === 'hybrid' ? '/hybrid' : '/search', { query, k: 20 });
    if (seq === searchSeq) renderItems(hits);
  } catch (e) {
    if (seq === searchSeq) els.list.innerHTML = `<div class="empty">${esc(e.message)}</div>`;
  }
}

// --- editor ----------------------------------------------------------------
async function openNote(path) {
  try {
    const note = await api('/note?path=' + encodeURIComponent(path));
    state.path = path; state.original = note.content; state.external = isExternal(path);
    els.body.value = note.content;
    els.body.disabled = false;
    els.path.textContent = (state.external ? '⧉ ' : '') + path + (state.external ? '  (read-only)' : '');
    setDirty(false);
    // external files are read-only
    els.body.readOnly = state.external;
    document.querySelectorAll('.item').forEach((n) =>
      n.classList.toggle('item--active', false));
    refreshHealth();
  } catch (e) { toast(e.message, true); }
}

function setDirty(d) {
  els.dirty.hidden = !d;
  els.save.disabled = !d || state.external;
}

async function saveNote() {
  if (!state.path || state.external) return;
  const content = els.body.value;
  try {
    const res = await post('/write', { path: state.path, content });
    state.original = content; setDirty(false);
    toast(res.action === 'unchanged' ? 'No changes' : 'Saved');
    setTimeout(refreshHealth, 2500); // watcher re-embeds within ~2s
  } catch (e) { toast(e.message, true); }
}

// --- ui glue ---------------------------------------------------------------
function esc(s) { return String(s).replace(/[&<>"]/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

let toastTimer;
function toast(msg, bad) {
  els.toast.textContent = msg;
  els.toast.className = 'toast' + (bad ? ' toast--bad' : '');
  els.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (els.toast.hidden = true), 2200);
}

let searchTimer;
els.q.addEventListener('input', () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => runSearch(els.q.value), 220);
});
els.q.addEventListener('keydown', (e) => { if (e.key === 'Enter') { clearTimeout(searchTimer); runSearch(els.q.value); } });

els.body.addEventListener('input', () => setDirty(els.body.value !== state.original));
els.save.onclick = saveNote;

document.querySelectorAll('.chip').forEach((c) => c.onclick = () => {
  document.querySelectorAll('.chip').forEach((x) => x.classList.remove('chip--on'));
  c.classList.add('chip--on');
  state.mode = c.dataset.mode;
  runSearch(els.q.value);
});

window.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 's') { e.preventDefault(); saveNote(); }
});

// --- boot ------------------------------------------------------------------
refreshHealth();
setInterval(refreshHealth, 15000);
showNotes();
