'use strict';
/* Cortex Desktop — local web UI. Search · open · edit · save + a link graph.
   Served same-origin by the cortex engine, so all fetches are relative. */

const $ = (s) => document.querySelector(s);
const els = {
  status: $('#status'), q: $('#q'), list: $('#list'), path: $('#path'),
  body: $('#body'), save: $('#save'), dirty: $('#dirty'), toast: $('#toast'),
  colorBy: $('#colorBy'), legend: $('#legend'), graphMeta: $('#graphMeta'),
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
const post = (p, body) => api(p, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const basename = (p) => (p.split('/').pop() || p).replace(/\.md$/, '');
const isExternal = (p) => p.startsWith('/');

// --- health ----------------------------------------------------------------
async function refreshHealth() {
  try {
    const h = await api('/health');
    els.status.textContent = `${h.notes} notes · ${h.chunks} chunks` + (h.external ? ` · ${h.external} ext` : '');
    els.status.className = 'status status--ok';
  } catch { els.status.textContent = 'engine offline'; els.status.className = 'status status--bad'; }
}

// --- sidebar list / search -------------------------------------------------
function renderItems(items) {
  els.list.innerHTML = '';
  if (!items.length) { els.list.innerHTML = '<div class="empty">No matches.</div>'; return; }
  for (const it of items) {
    const div = document.createElement('div');
    div.className = 'item' + (it.path === state.path ? ' item--active' : '') + (isExternal(it.path) ? ' item--external' : '');
    const score = it.score != null ? `<span class="item-score">${Number(it.score).toFixed(3)}</span>` : '';
    div.innerHTML = `${score}<div class="item-title">${esc(basename(it.path))}</div>` +
      `<div class="item-ctx">${esc(it.heading || it.path)}</div>` +
      (it.text ? `<div class="item-snip">${esc(it.text)}</div>` : '');
    div.onclick = () => openNote(it.path);
    els.list.appendChild(div);
  }
}
async function showNotes() {
  try { renderItems((await api('/list?limit=500')).map((p) => ({ path: p }))); }
  catch (e) { els.list.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
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
  } catch (e) { if (seq === searchSeq) els.list.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}

// --- editor ----------------------------------------------------------------
async function openNote(path) {
  try {
    const note = await api('/note?path=' + encodeURIComponent(path));
    state.path = path; state.original = note.content; state.external = isExternal(path);
    els.body.value = note.content; els.body.disabled = false; els.body.readOnly = state.external;
    els.path.textContent = (state.external ? '⧉ ' : '') + path + (state.external ? '  (read-only)' : '');
    setDirty(false);
    setView('editor');
    if (cy) cy.nodes().removeClass('pinned'), cy.$id(path).addClass('pinned');
  } catch (e) { toast(e.message, true); }
}
function setDirty(d) { els.dirty.hidden = !d; els.save.disabled = !d || state.external; }
async function saveNote() {
  if (!state.path || state.external) return;
  const content = els.body.value;
  try {
    const res = await post('/write', { path: state.path, content });
    state.original = content; setDirty(false);
    toast(res.action === 'unchanged' ? 'No changes' : 'Saved');
    setTimeout(refreshHealth, 2500);
  } catch (e) { toast(e.message, true); }
}
let toastTimer;
function toast(msg, bad) {
  els.toast.textContent = msg; els.toast.className = 'toast' + (bad ? ' toast--bad' : ''); els.toast.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => (els.toast.hidden = true), 2200);
}

// --- graph -----------------------------------------------------------------
const PALETTE = ['#5BD1FF', '#FF6B8B', '#FFD166', '#7CFFB2', '#C792EA', '#FF9F6B',
                 '#6BE0D6', '#F78FB3', '#A0E36B', '#8AB4FF', '#FF7AC6', '#E8E8EE'];
const OTHER = '#6a6a72';
let cy = null, graphNodes = [];

const gval = (d, dim) => { const v = d[dim]; return (v == null || v === '') ? null : String(v); };
function colorMap(dim) {
  const vals = [...new Set(graphNodes.map((n) => gval(n, dim)).filter(Boolean))].sort();
  const m = new Map(); vals.forEach((v, i) => m.set(v, PALETTE[i % PALETTE.length])); return m;
}
function cyStyle() {
  return [
    { selector: 'node', style: {
        'background-color': 'data(color)', 'label': 'data(label)',
        'width': 'mapData(deg, 0, 12, 13, 46)', 'height': 'mapData(deg, 0, 12, 13, 46)',
        'color': '#c7c7cf', 'font-size': 9, 'font-family': 'ui-monospace, monospace',
        'text-valign': 'bottom', 'text-margin-y': 3, 'min-zoomed-font-size': 7,
        'text-opacity': 0.8, 'border-width': 0, 'overlay-opacity': 0,
        'transition-property': 'opacity, border-width', 'transition-duration': '120ms' } },
    { selector: 'edge', style: { 'width': 1, 'line-color': '#2c2c33', 'curve-style': 'bezier', 'opacity': 0.55 } },
    { selector: '.faded', style: { 'opacity': 0.1, 'text-opacity': 0.04 } },
    { selector: 'node.hl', style: { 'border-width': 2, 'border-color': '#fff', 'font-size': 11, 'text-opacity': 1, 'color': '#fff', 'z-index': 99 } },
    { selector: 'edge.hl', style: { 'line-color': '#fff', 'opacity': 0.9, 'width': 1.5 } },
    { selector: 'node.pinned', style: { 'border-width': 2, 'border-color': '#fff' } },
  ];
}
const cyLayout = () => ({ name: 'cose', animate: true, animationDuration: 600, nodeRepulsion: 9000,
  idealEdgeLength: 95, edgeElasticity: 120, gravity: 0.25, numIter: 1200, fit: true, padding: 44 });

function recolor() {
  if (!cy) return;
  const dim = els.colorBy.value, cm = colorMap(dim);
  cy.nodes().forEach((n) => { const v = gval(n.data(), dim); n.data('color', v ? cm.get(v) : OTHER); });
  renderLegend(cm);
}
function renderLegend(cm) {
  els.legend.innerHTML = '';
  [...cm.entries()].slice(0, 12).forEach(([v, c]) => {
    const s = document.createElement('span'); s.className = 'legend-item';
    s.innerHTML = `<span class="legend-dot" style="background:${c};color:${c}"></span>${esc(v)}`;
    els.legend.appendChild(s);
  });
  if (cm.size > 12) { const m = document.createElement('span'); m.className = 'legend-item'; m.textContent = `+${cm.size - 12}`; els.legend.appendChild(m); }
}
async function loadGraph() {
  const g = await api('/graph');
  graphNodes = g.nodes;
  const deg = {};
  g.edges.forEach((e) => { deg[e.source] = (deg[e.source] || 0) + 1; deg[e.target] = (deg[e.target] || 0) + 1; });
  const elements = [];
  for (const n of g.nodes) elements.push({ data: {
    id: n.id, label: n.label, folder: n.folder, type: n.type, status: n.status, domain: n.domain,
    deg: Math.min(deg[n.id] || 0, 12), color: OTHER } });
  for (const e of g.edges) elements.push({ data: { id: e.source + '→' + e.target, source: e.source, target: e.target } });
  cy = cytoscape({ container: $('#cy'), elements, style: cyStyle(), layout: cyLayout(), minZoom: 0.2, maxZoom: 3, wheelSensitivity: 0.25 });
  cy.on('tap', 'node', (evt) => openNote(evt.target.id()));
  cy.on('mouseover', 'node', (evt) => {
    const n = evt.target, hood = n.closedNeighborhood();
    cy.elements().addClass('faded'); hood.removeClass('faded'); hood.addClass('hl'); n.addClass('hl');
  });
  cy.on('mouseout', 'node', () => cy.elements().removeClass('faded hl'));
  recolor();
  els.graphMeta.textContent = `${g.nodes.length} notes · ${g.edges.length} links`;
  if (state.path) cy.$id(state.path).addClass('pinned');
}

// --- views -----------------------------------------------------------------
function setView(v) {
  document.querySelectorAll('.seg-btn').forEach((b) => b.classList.toggle('seg-btn--on', b.dataset.view === v));
  $('#editorPanel').hidden = v !== 'editor';
  $('#graphPanel').hidden = v !== 'graph';
  if (v === 'graph') { if (!cy) loadGraph().catch((e) => toast(e.message, true)); else cy.resize(); }
}

// --- glue ------------------------------------------------------------------
let searchTimer;
els.q.addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(() => runSearch(els.q.value), 220); });
els.q.addEventListener('keydown', (e) => { if (e.key === 'Enter') { clearTimeout(searchTimer); runSearch(els.q.value); } });
els.body.addEventListener('input', () => setDirty(els.body.value !== state.original));
els.save.onclick = saveNote;
els.colorBy.onchange = recolor;
$('#relayout').onclick = () => { if (cy) cy.layout(cyLayout()).run(); };
document.querySelectorAll('.seg-btn').forEach((b) => (b.onclick = () => setView(b.dataset.view)));
document.querySelectorAll('.chip').forEach((c) => (c.onclick = () => {
  document.querySelectorAll('.chip').forEach((x) => x.classList.remove('chip--on'));
  c.classList.add('chip--on'); state.mode = c.dataset.mode; runSearch(els.q.value);
}));
window.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 's') { e.preventDefault(); saveNote(); }
  if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); els.q.focus(); }
});

// --- boot ------------------------------------------------------------------
refreshHealth(); setInterval(refreshHealth, 15000); showNotes();
