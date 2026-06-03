'use strict';
/* Cortex Desktop — local web UI. Search · ask · open · edit · save + a force
   graph. Served same-origin by the cortex engine, so all fetches are relative. */

const $ = (s) => document.querySelector(s);
const els = {
  status: $('#status'), q: $('#q'), list: $('#list'), path: $('#path'),
  editor: $('#editor'), hint: $('#editorHint'), viewer: $('#viewer'),
  save: $('#save'), dirty: $('#dirty'), toast: $('#toast'),
  colorBy: $('#colorBy'), legend: $('#legend'), graphMeta: $('#graphMeta'), cy: $('#cy'),
  labelMode: $('#labelMode'),
};
const state = { path: null, original: '', mode: 'semantic', external: false };
const VIEW_EXT = /\.(pdf|png|jpe?g|gif|webp|svg|bmp|tiff?|avif)$/i;
let editor = null;
function ensureEditor() {
  if (!editor) {
    editor = window.createCortexEditor(els.editor, {
      onChange: () => setDirty(editor.getValue() !== state.original),
      onOpenLink: openByName,
      onImagePaste: onImagePaste,
    });
  }
  return editor;
}
async function onImagePaste(file, insert) {
  try {
    const ext = ((file.type || '').split('/')[1] || 'png').replace('jpeg', 'jpg').split('+')[0];
    const r = await fetch('/attach?name=' + encodeURIComponent(`pasted-${Date.now()}.${ext}`), {
      method: 'POST', headers: { 'Content-Type': file.type || 'application/octet-stream' },
      body: await file.arrayBuffer(),
    });
    const j = await r.json();
    if (j && j.path) { insert(`![[${j.path}]]`); toast('Image saved'); setTimeout(refreshHealth, 2500); }
    else toast((j && j.error) || 'Attach failed', true);
  } catch (e) { toast(e.message, true); }
}
function openViewer(path) {
  state.path = path; state.external = isExternal(path);
  setView('editor');
  const url = '/raw?path=' + encodeURIComponent(path);
  els.viewer.innerHTML = /\.pdf$/i.test(path)
    ? `<iframe src="${url}"></iframe>`
    : `<img src="${url}" alt="${esc(basename(path))}">`;
  els.hint.hidden = true; els.editor.style.display = 'none'; els.viewer.hidden = false;
  els.path.textContent = (state.external ? '⧉ ' : '') + path + '  (view)';
  setDirty(false); els.save.disabled = true;
  pinnedId = path; refreshGraph();
}
async function openByName(name) {
  name = String(name).trim();
  if (VIEW_EXT.test(name)) return openNote(name);
  try {
    const list = await api('/list?limit=2000');
    const hit = list.find((p) => basename(p).toLowerCase() === name.toLowerCase());
    if (hit) openNote(hit); else toast(`No note named "${name}"`, true);
  } catch (e) { toast(e.message, true); }
}

// --- api -------------------------------------------------------------------
async function api(path, opts) {
  const r = await fetch(path, opts);
  const ct = r.headers.get('content-type') || '';
  const data = ct.includes('json') ? await r.json() : await r.text();
  if (!r.ok || (data && data.error && !('answer' in data))) throw new Error((data && data.error) || ('HTTP ' + r.status));
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
function itemEl(it) {
  const div = document.createElement('div');
  div.className = 'item' + (it.path === state.path ? ' item--active' : '') + (isExternal(it.path) ? ' item--external' : '');
  const score = it.score != null ? `<span class="item-score">${Number(it.score).toFixed(3)}</span>` : '';
  div.innerHTML = `${score}<div class="item-title">${esc(basename(it.path))}</div>` +
    `<div class="item-ctx">${esc(it.heading || it.path)}</div>` +
    (it.text ? `<div class="item-snip">${esc(it.text)}</div>` : '');
  div.onclick = () => openNote(it.path);
  return div;
}
function renderItems(items) {
  els.list.innerHTML = '';
  if (!items.length) { els.list.innerHTML = '<div class="empty">No matches.</div>'; return; }
  items.forEach((it) => els.list.appendChild(itemEl(it)));
}
async function showNotes() {
  try { renderItems((await api('/list?limit=500')).map((p) => ({ path: p }))); }
  catch (e) { els.list.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}
let searchSeq = 0;
async function runSearch(query) {
  query = query.trim();
  if (!query) return showNotes();
  if (state.mode === 'ask') return runAsk(query);
  const seq = ++searchSeq;
  els.list.innerHTML = '<div class="loading">Searching…</div>';
  try {
    const hits = await post(state.mode === 'hybrid' ? '/hybrid' : '/search', { query, k: 20 });
    if (seq === searchSeq) renderItems(hits);
  } catch (e) { if (seq === searchSeq) els.list.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}

// --- ask (local RAG answer) ------------------------------------------------
async function runAsk(query) {
  const seq = ++searchSeq;
  els.list.innerHTML = '<div class="answer"><div class="answer-head"><span class="spark">✦</span> answer</div>' +
    '<div class="answer-thinking">thinking over your notes…</div></div>';
  try {
    const r = await post('/ask', { query, k: 6 });
    if (seq === searchSeq) renderAnswer(r);
  } catch (e) {
    if (seq === searchSeq) els.list.innerHTML = `<div class="answer"><div class="answer-err">${esc(e.message)}</div></div>`;
  }
}
function renderAnswer(r) {
  els.list.innerHTML = '';
  const card = document.createElement('div'); card.className = 'answer';
  if (!r.answer) {
    card.innerHTML = `<div class="answer-head"><span class="spark">✦</span> ask</div><div class="answer-err">${esc(r.error || 'No answer.')}</div>`;
    els.list.appendChild(card); return;
  }
  card.innerHTML = `<div class="answer-head"><span class="spark">✦</span> answer${r.model ? ' · ' + esc(r.model) : ''}</div>` +
    `<div class="answer-body">${esc(r.answer)}</div>`;
  els.list.appendChild(card);
  if (r.sources && r.sources.length) {
    const lbl = document.createElement('div'); lbl.className = 'sources-label'; lbl.textContent = 'sources';
    els.list.appendChild(lbl);
    r.sources.forEach((it) => els.list.appendChild(itemEl(it)));
  }
}

// --- editor ----------------------------------------------------------------
async function openNote(path) {
  if (VIEW_EXT.test(path)) return openViewer(path);
  try {
    const note = await api('/note?path=' + encodeURIComponent(path));
    state.path = path; state.original = note.content; state.external = isExternal(path);
    ensureEditor(); editor.setValue(note.content); editor.setReadOnly(state.external);
    els.viewer.hidden = true; els.editor.style.display = ''; els.hint.hidden = true;
    els.path.textContent = (state.external ? '⧉ ' : '') + path + (state.external ? '  (read-only)' : '');
    setDirty(false); setView('editor');
    pinnedId = path; refreshGraph();
  } catch (e) { toast(e.message, true); }
}
function setDirty(d) { els.dirty.hidden = !d; els.save.disabled = !d || state.external; }
async function saveNote() {
  if (!state.path || state.external || !editor) return;
  const content = editor.getValue();
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
  clearTimeout(toastTimer); toastTimer = setTimeout(() => (els.toast.hidden = true), 2400);
}

// --- graph (force-graph, supermemory-style glow constellation) -------------
const PALETTE = ['#67E8F9', '#A78BFA', '#FDA4AF', '#FCD34D', '#86EFAC', '#F0ABFC',
                 '#93C5FD', '#FDBA74', '#5EEAD4', '#C4B5FD', '#F9A8D4', '#BEF264'];
const OTHER = '#5b626c';
let fg = null, graphData = null, graphNodes = [], adjacency = {};
let hoverId = null, hoverSet = new Set(), pinnedId = null;
let labelMode = 'hubs', lastScale = 1;
const HUB_DEG = 5;
const isHot = (l) => { const s = l.source.id || l.source, t = l.target.id || l.target, ff = hoverId || pinnedId; return ff && (s === ff || t === ff); };

// Level-of-detail label policy — opacity (0 = don't draw) for a node at this zoom.
function labelAlpha(n, scale) {
  if (n.id === hoverId || n.id === pinnedId) return 1;
  if (hoverId && hoverSet.has(n.id)) return 0.85;
  if (labelMode === 'off') return 0;
  if (labelMode === 'all') return scale > 1.4 ? 0.85 : scale > 0.75 ? 0.5 : 0;
  if ((n.deg || 0) >= HUB_DEG && scale > 0.55) return 0.7;   // hubs labelled early
  if (scale > 2.0) return 0.5;                                // reveal everything when zoomed deep
  return 0;
}

// Per-frame eased state so focus dim / glow / labels glide instead of snapping.
// force-graph calls this every render frame (continuous loop), even after the
// physics cools — that's what makes hover/selection feel alive, not static.
function animateFrame(ctx, globalScale) {
  lastScale = globalScale;
  if (!graphData) return;
  const k = 0.18;
  for (const n of graphData.nodes) {
    const fT = !hoverId || n.id === hoverId || hoverSet.has(n.id) ? 1 : 0.18;
    const gT = (n.id === hoverId || n.id === pinnedId) ? 1 : 0;
    n.__f = n.__f == null ? fT : n.__f + (fT - n.__f) * k;
    n.__g = n.__g == null ? gT : n.__g + (gT - n.__g) * k;
  }
}

const gval = (d, dim) => { const v = d[dim]; return (v == null || v === '') ? null : String(v); };
function colorMap(dim) {
  const vals = [...new Set(graphNodes.map((n) => gval(n, dim)).filter(Boolean))].sort();
  const m = new Map(); vals.forEach((v, i) => m.set(v, PALETTE[i % PALETTE.length])); return m;
}

function hexA(hex, a) {
  const m = /^#?([0-9a-fA-F]{6})$/.exec(hex || '');
  if (!m) return `rgba(255,255,255,${a})`;
  const n = parseInt(m[1], 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

const nodeR = (n) => 2.5 + Math.min(n.deg || 0, 18) * 0.32;   // ~2.5–8 px, clean dots
function refreshGraph() { if (fg) fg.nodeRelSize(fg.nodeRelSize()); } // nudge a repaint

function paintNode(n, ctx, scale) {
  if (n.x == null) return;
  const color = n.__color || OTHER;
  const r = nodeR(n);
  const isHover = n.id === hoverId, isPin = n.id === pinnedId;
  const f = n.__f == null ? 1 : n.__f;   // eased focus (1 focused .. 0.18 dimmed)
  const g = n.__g == null ? 0 : n.__g;   // eased glow (0 .. 1)
  ctx.shadowColor = color; ctx.shadowBlur = 2.5 + 10 * g;   // subtle glow, brighter on focus
  ctx.globalAlpha = f;
  ctx.beginPath(); ctx.arc(n.x, n.y, r, 0, 2 * Math.PI); ctx.fillStyle = color; ctx.fill();
  ctx.shadowBlur = 0;
  if (g > 0.01) {   // focus ring fades in with the glow
    ctx.globalAlpha = g; ctx.lineWidth = 1.4 / scale; ctx.strokeStyle = '#ffffff';
    ctx.beginPath(); ctx.arc(n.x, n.y, r + 2.5 / scale, 0, 2 * Math.PI); ctx.stroke();
  }
  const la = labelAlpha(n, scale);
  if (la > 0) {
    const fs = 9 / scale;                 // constant ~9 screen-px (stays tiny at any zoom)
    ctx.globalAlpha = la * f;
    ctx.font = `${fs}px "Spline Sans Mono", ui-monospace, monospace`;
    ctx.textAlign = 'center'; ctx.textBaseline = 'top';
    ctx.lineWidth = 3 / scale; ctx.strokeStyle = 'rgba(0,0,0,0.9)';
    ctx.strokeText(n.label || '', n.x, n.y + r + 3 / scale);
    ctx.fillStyle = (isHover || isPin) ? '#fff' : '#cdd2da';
    ctx.fillText(n.label || '', n.x, n.y + r + 3 / scale);
  }
  ctx.globalAlpha = 1;
}

function recolor() {
  if (!graphData) return;
  const dim = els.colorBy.value, cm = colorMap(dim);
  graphData.nodes.forEach((n) => { const v = gval(n, dim); n.__color = v ? cm.get(v) : OTHER; });
  renderLegend(cm); refreshGraph();
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
function sizeGraph() { if (fg) { fg.width(els.cy.clientWidth); fg.height(els.cy.clientHeight); } }

async function loadGraph() {
  const g = await api('/graph');
  graphNodes = g.nodes;
  const deg = {}; adjacency = {};
  g.edges.forEach((e) => {
    deg[e.source] = (deg[e.source] || 0) + 1; deg[e.target] = (deg[e.target] || 0) + 1;
    (adjacency[e.source] = adjacency[e.source] || new Set()).add(e.target);
    (adjacency[e.target] = adjacency[e.target] || new Set()).add(e.source);
  });
  const nodes = g.nodes.map((n) => ({ id: n.id, label: n.label, folder: n.folder, type: n.type, status: n.status, domain: n.domain, deg: deg[n.id] || 0 }));
  const links = g.edges.map((e) => ({ source: e.source, target: e.target }));
  graphData = { nodes, links };

  fg = ForceGraph()(els.cy);
  fg.graphData(graphData)
    .backgroundColor('rgba(0,0,0,0)')
    .nodeId('id')
    .nodeLabel(() => '')
    .nodeCanvasObjectMode(() => 'replace')
    .nodeCanvasObject(paintNode)
    .onRenderFramePre(animateFrame)
    .nodePointerAreaPaint((n, color, ctx) => {
      ctx.fillStyle = color; ctx.beginPath();
      ctx.arc(n.x, n.y, nodeR(n) + 4, 0, 2 * Math.PI); ctx.fill();
    })
    .linkColor((l) => (isHot(l) ? 'rgba(255,255,255,0.7)' : hexA((l.source && l.source.__color) || '#7a7f88', 0.18)))
    .linkWidth((l) => {
      const s = l.source.id || l.source, t = l.target.id || l.target;
      return (hoverId && (s === hoverId || t === hoverId)) ? 1.3 : 0.5;
    })
    .linkDirectionalParticles((l) => (isHot(l) ? 4 : 0))
    .linkDirectionalParticleWidth(1.8)
    .linkDirectionalParticleSpeed(0.006)
    .onNodeHover((n) => {
      hoverId = n ? n.id : null;
      hoverSet = n ? (adjacency[n.id] || new Set()) : new Set();
      els.cy.style.cursor = n ? 'pointer' : 'default';
    })
    .onNodeClick((n) => { try { fg.centerAt(n.x, n.y, 600); fg.zoom(Math.max(fg.zoom(), 2.2), 600); } catch (e) {} openNote(n.id); })
    .onBackgroundClick(() => { hoverId = null; hoverSet = new Set(); })
    .onNodeDragEnd((n) => { n.fx = undefined; n.fy = undefined; })   // released node springs back into the sim
    .onEngineStop(() => { try { fg.zoomToFit(600, 140); } catch (e) {} });

  // Physics: local repulsion + COLLISION (nodes never overlap) + a gentle pull
  // to centre — keeps the graph bounded and filling the canvas instead of
  // flinging stragglers into the void (which made "fit" zoom to a tiny clump).
  const D = window.d3 || {};
  if (D.forceManyBody) fg.d3Force('charge', D.forceManyBody().strength(-210).distanceMax(500));
  if (D.forceCollide) fg.d3Force('collide', D.forceCollide((n) => nodeR(n) + 7).strength(1).iterations(2));
  if (D.forceX) fg.d3Force('x', D.forceX(0).strength(0.08));
  if (D.forceY) fg.d3Force('y', D.forceY(0).strength(0.08));
  try { fg.d3Force('link').distance(72).strength(0.5); } catch (e) {}
  fg.d3VelocityDecay(0.28).d3AlphaDecay(0.015).warmupTicks(40).cooldownTime(9000);

  recolor(); sizeGraph();
  els.graphMeta.textContent = `${g.nodes.length} notes · ${g.edges.length} links`;
  // fit once the layout has had time to spread (belt-and-suspenders with onEngineStop)
  setTimeout(() => { try { fg.zoomToFit(800, 140); } catch (e) {} }, 5200);
}

// --- views -----------------------------------------------------------------
function setView(v) {
  document.querySelectorAll('.seg-btn').forEach((b) => b.classList.toggle('seg-btn--on', b.dataset.view === v));
  $('#editorPanel').hidden = v !== 'editor';
  $('#graphPanel').hidden = v !== 'graph';
  if (v === 'graph') {
    if (!fg) loadGraph().catch((e) => toast(e.message, true));
    else { sizeGraph(); fg.zoomToFit(500, 60); }
  }
}

// --- glue ------------------------------------------------------------------
let searchTimer;
els.q.addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(() => runSearch(els.q.value), state.mode === 'ask' ? 600 : 220); });
els.q.addEventListener('keydown', (e) => { if (e.key === 'Enter') { clearTimeout(searchTimer); runSearch(els.q.value); } });
els.save.onclick = saveNote;
els.colorBy.onchange = recolor;
els.labelMode.onchange = () => { labelMode = els.labelMode.value; };
$('#relayout').onclick = () => { if (fg) { fg.d3ReheatSimulation(); fg.zoomToFit(700, 60); } };
document.querySelectorAll('.seg-btn').forEach((b) => (b.onclick = () => setView(b.dataset.view)));
document.querySelectorAll('.chip').forEach((c) => (c.onclick = () => {
  document.querySelectorAll('.chip').forEach((x) => x.classList.remove('chip--on'));
  c.classList.add('chip--on'); state.mode = c.dataset.mode;
  els.q.placeholder = c.dataset.mode === 'ask' ? 'Ask your notes a question…' : 'Search your mind…';
  if (els.q.value.trim()) runSearch(els.q.value);
}));
window.addEventListener('resize', () => { if (fg && !$('#graphPanel').hidden) sizeGraph(); });
window.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 's') { e.preventDefault(); saveNote(); }
  if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); els.q.focus(); }
});

// --- boot ------------------------------------------------------------------
refreshHealth(); setInterval(refreshHealth, 15000); showNotes();
