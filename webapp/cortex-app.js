'use strict';
/* ============================================================================
   CORTEX — app logic, wired to the live Cortex loopback API (cortex/http_api.py).
   Graph from /graph + /semantic_graph, notes from /note, search/hybrid/ask
   server-side. Color lives in exactly one place: the graph nodes.
   ========================================================================== */
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

/* ---- API helpers --------------------------------------------------------- */
async function api(path, opts) {
  const r = await fetch(path, opts);
  if (!r.ok) throw new Error((await r.text().catch(() => '')) || r.statusText);
  return r.json();
}
const post = (path, body) =>
  api(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

/* ---- palettes (the only color in the app) -------------------------------- */
const PALETTES = {
  calm:  ['#67E8F9', '#A78BFA', '#FCD34D', '#86EFAC', '#FDA4AF', '#93C5FD', '#F0ABFC', '#FDBA74', '#5EEAD4', '#C4B5FD'],
  vivid: ['#22D3EE', '#8B5CF6', '#FBBF24', '#34D399', '#FB7185', '#60A5FA', '#E879F9', '#FB923C', '#2DD4BF', '#A78BFA'],
  mono:  ['#f4f5f7', '#c8ccd2', '#aeb3ba', '#dfe2e6', '#9aa0a9', '#eceef1', '#d2d6dc', '#bcc1c8', '#e6e8ec', '#a6acb5'],
};
const FALLBACK = '#9aa0a9';
const STATUS_GLYPH = { seed: '○', sprout: '◐', idea: '○', wip: '◐', active: '◐', draft: '◐', growing: '◐',
  evergreen: '●', done: '●', stable: '●', complete: '●', mature: '●', shipped: '●', archived: '●' };
const statusGlyph = (s) => (s ? (STATUS_GLYPH[String(s).toLowerCase()] || '•') : '');

const state = {
  view: 'graph', noteId: null, mode: 'semantic', query: '',
  colorBy: 'domain', linkMode: 'wiki', labels: 'hubs',
  palette: 'calm', glow: 1, theme: 'dark',  // dark monochrome — the one true theme
  mutedDomains: new Set(),
};

/* ---- vault model (filled at boot from the API) --------------------------- */
let NODES = [];                 // {id(path), label, folder, type, status, domain, tags}
let byId = new Map();           // path -> node
let byLabel = new Map();        // stem.toLowerCase() -> node (first wins, Obsidian-style)
let WIKI = [];                  // undirected unique {source,target}
let WIKI_DIR = [];              // directed {from,to} for backlinks
let SEM = [];                   // {source,target,score,kind:'sem'}
let DEG = new Map();
let DOMAIN_LIST = [];           // sorted distinct non-null domains
let DOMAINS = {};               // domain -> {label}
const deg = (id) => DEG.get(id) || 0;

function buildModel(graph) {
  NODES = (graph.nodes || []).map((n) => ({
    id: n.id, label: n.label, folder: n.folder || '',
    type: n.type || null, status: n.status || null, domain: n.domain || null,
    tags: n.tags || [],
  }));
  byId = new Map(NODES.map((n) => [n.id, n]));
  byLabel = new Map();
  for (const n of NODES) {
    const k = n.label.toLowerCase();
    if (!byLabel.has(k)) byLabel.set(k, n);
  }
  WIKI = []; WIKI_DIR = []; DEG = new Map();
  const seen = new Set();
  for (const e of graph.edges || []) {
    if (!byId.has(e.source) || !byId.has(e.target) || e.source === e.target) continue;
    WIKI_DIR.push({ from: e.source, to: e.target });
    const key = e.source < e.target ? e.source + '|' + e.target : e.target + '|' + e.source;
    if (seen.has(key)) continue;
    seen.add(key);
    WIKI.push({ source: e.source, target: e.target });
    DEG.set(e.source, (DEG.get(e.source) || 0) + 1);
    DEG.set(e.target, (DEG.get(e.target) || 0) + 1);
  }
  DOMAIN_LIST = [...new Set(NODES.map((n) => n.domain).filter(Boolean))].sort();
  DOMAINS = Object.fromEntries(DOMAIN_LIST.map((d) => [d, { label: d }]));
}

function applySemantic(edges) {
  SEM = (edges || [])
    .filter((e) => byId.has(e.source) && byId.has(e.target) && e.source !== e.target)
    .map((e) => ({ source: e.source, target: e.target, score: e.score ?? 0, kind: 'sem' }));
}

/* ---- color resolution ---------------------------------------------------- */
function colorForDomain(domain) {
  const i = DOMAIN_LIST.indexOf(domain);
  if (i < 0) return FALLBACK;
  const cols = PALETTES[state.palette];
  return cols[i % cols.length];
}
function dimValue(note, dim) { return dim === 'domain' ? note.domain : note[dim]; }
function colorMapFor(dim) {
  if (dim === 'domain') return new Map(DOMAIN_LIST.map((d) => [d, colorForDomain(d)]));
  const vals = [...new Set(NODES.map((n) => dimValue(n, dim)).filter(Boolean))].sort();
  const cols = PALETTES[state.palette];
  return new Map(vals.map((v, i) => [v, cols[i % cols.length]]));
}
function colorOf(note) {
  if (state.colorBy === 'domain') return colorForDomain(note.domain);
  return colorMapFor(state.colorBy).get(dimValue(note, state.colorBy)) || FALLBACK;
}
const domainColor = (note) => colorForDomain(note && note.domain);
const domainLabel = (d) => (DOMAINS[d] ? DOMAINS[d].label : (d || '—'));
const topFolder = (f) => (f || '').split('/')[0] || '—';

/* ---- graph nodes / links builders ---------------------------------------- */
function graphNodes() {
  return NODES.map((n) => ({
    id: n.id, label: n.label, domain: n.domain, folder: topFolder(n.folder),
    type: n.type, status: n.status, deg: deg(n.id), color: colorOf(n),
  }));
}
function graphLinks() {
  let out = [];
  if (state.linkMode !== 'semantic') out = out.concat(WIKI.map((e) => ({ ...e, kind: 'wiki' })));
  if (state.linkMode !== 'wiki') out = out.concat(SEM);
  return out;
}

/* ===========================================================================
   MAIN GRAPH
   ========================================================================= */
let graph = null;
const hovercard = $('#hovercard');
function initGraph() {
  graph = new CortexGraph($('#cy'), {
    onNodeClick: (n) => openNote(n.id),
    onBackground: () => { state.noteId && setActiveList(); },
    onNodeHover: (n, px, py) => showHovercard(n, px, py),
    labels: state.labels,
  });
  graph.opts.light = state.theme === 'light';
  graph.glow = state.glow;
  graph.setData(graphNodes(), graphLinks());
  refreshGraphChrome();
}
function refreshGraph() {
  if (!graph) return;
  graph.opts.light = state.theme === 'light';
  graph.glow = state.glow;
  graph.opts.labels = state.labels;
  graph.setMutedDomains(state.colorBy === 'domain' ? state.mutedDomains : new Set());
  graph.setData(graphNodes(), graphLinks());
  refreshGraphChrome();
}
function showHovercard(n, px, py) {
  if (!n) { hovercard.dataset.show = 'false'; return; }
  const note = byId.get(n.id);
  const links = WIKI.filter((e) => e.source === n.id || e.target === n.id).length;
  const sem = SEM.filter((e) => e.source === n.id || e.target === n.id).length;
  hovercard.innerHTML =
    `<div class="hc-title"><span class="legend-dot" style="background:${n.color};color:${n.color}"></span>${esc(n.label)}</div>` +
    `<div class="hc-meta"><span class="hc-tag">${esc(note.type || '—')}</span><span class="hc-tag">${statusGlyph(note.status)} ${esc(note.status || '—')}</span><span class="hc-tag">${esc(topFolder(note.folder))}</span></div>` +
    `<div class="hc-links">${links} link${links !== 1 ? 's' : ''} · ${sem} semantic</div>`;
  hovercard.dataset.show = 'true';
  const host = $('#cy').getBoundingClientRect();
  let x = px + 16, y = py + 16;
  if (x + 270 > host.width) x = px - 270;
  if (y + 110 > host.height) y = py - 110;
  hovercard.style.left = Math.max(8, x) + 'px';
  hovercard.style.top = Math.max(8, y) + 'px';
}

/* graph chrome: controls, legend, meta */
function segGroup(label, key, opts) {
  return `<div class="gc-group"><div class="gc-label">${label}</div><div class="gc-seg" data-key="${key}">` +
    opts.map(([v, t]) => `<button class="gc-opt" data-v="${v}" data-on="${state[key] === v}">${t}</button>`).join('') +
    `</div></div>`;
}
function refreshGraphChrome() {
  $('#graphControls').innerHTML =
    `<div class="gc-row">` +
      segGroup('Color by', 'colorBy', [['domain', 'domain'], ['folder', 'folder'], ['type', 'type'], ['status', 'status']]) +
    `</div>` +
    `<div class="gc-row">` +
      segGroup('Links', 'linkMode', [['wiki', 'wiki'], ['both', 'both'], ['semantic', 'semantic']]) +
      segGroup('Labels', 'labels', [['all', 'all'], ['hubs', 'hubs'], ['off', 'off']]) +
    `</div>` +
    `<div class="gc-row"><button class="gc-opt" id="relayout" style="padding:5px 12px">↻ re-layout</button>` +
    `<button class="gc-opt" id="fitBtn" style="padding:5px 12px">⊡ fit</button></div>`;
  $$('#graphControls .gc-seg').forEach((seg) => {
    const key = seg.dataset.key;
    $$('.gc-opt', seg).forEach((b) => b.onclick = () => {
      state[key] = b.dataset.v;
      if (key === 'colorBy') state.mutedDomains = new Set();
      refreshGraph();
    });
  });
  $('#relayout').onclick = () => graph.reheat();
  $('#fitBtn').onclick = () => graph.fit(80);

  // legend
  const cm = colorMapFor(state.colorBy);
  const counts = new Map();
  for (const n of NODES) { const v = dimValue(n, state.colorBy); if (v) counts.set(v, (counts.get(v) || 0) + 1); }
  const title = state.colorBy === 'domain' ? 'Domains' : state.colorBy;
  const entries = [...cm.entries()];
  $('#legend').innerHTML = `<div class="legend-title">${title}</div><div class="legend-grid">` +
    entries.slice(0, 8).map(([v, c]) => {
      const name = state.colorBy === 'domain' ? domainLabel(v) : v;
      const muted = state.colorBy === 'domain' && state.mutedDomains.has(v);
      return `<div class="legend-item" data-v="${esc(v)}" data-muted="${muted}"><span class="legend-dot" style="background:${c};color:${c}"></span><span class="legend-name">${esc(name)}</span><span class="legend-count">${counts.get(v) || 0}</span></div>`;
    }).join('') + `</div>`;
  if (state.colorBy === 'domain') {
    $$('#legend .legend-item').forEach((it) => it.onclick = () => {
      const v = it.dataset.v;
      state.mutedDomains.has(v) ? state.mutedDomains.delete(v) : state.mutedDomains.add(v);
      graph.setMutedDomains(state.mutedDomains); refreshGraphChrome();
    });
  }
  const links = graphLinks();
  $('#graphMeta').textContent = `${NODES.length} notes · ${links.length} links` + (state.linkMode === 'both' ? ' · wiki + semantic' : state.linkMode === 'semantic' ? ' · semantic' : '');
}

/* ===========================================================================
   MARKDOWN
   ========================================================================= */
function stripFrontmatter(md) { return md.replace(/^﻿?---\r?\n[\s\S]*?\r?\n---\r?\n?/, ''); }
function renderInline(s) {
  s = esc(s);
  s = s.replace(/\[\[([^\]]+)\]\]/g, (_, inner) => {
    const [tgt, disp] = inner.split('|');
    const label = tgt.trim();
    return `<a class="wikilink" data-link="${esc(label)}">${esc((disp || tgt).trim())}</a>`;
  });
  s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
  return s;
}
function renderMarkdown(md) {
  const lines = md.split('\n');
  let html = '', i = 0, listType = null;
  const closeList = () => { if (listType) { html += `</${listType}>`; listType = null; } };
  while (i < lines.length) {
    let line = lines[i];
    if (/^```/.test(line)) {
      closeList(); i++; let code = '';
      while (i < lines.length && !/^```/.test(lines[i])) { code += lines[i] + '\n'; i++; }
      i++; html += `<pre><code>${esc(code.replace(/\n$/, ''))}</code></pre>`; continue;
    }
    if (/^#{1,3}\s/.test(line)) { closeList(); const lvl = Math.min(line.match(/^#+/)[0].length, 3); const t = line.replace(/^#+\s/, ''); html += `<h${lvl}>${renderInline(t)}</h${lvl}>`; i++; continue; }
    if (/^>\s?/.test(line)) {
      closeList(); let quote = '';
      while (i < lines.length && /^>\s?/.test(lines[i])) { quote += lines[i].replace(/^>\s?/, '') + ' '; i++; }
      html += `<blockquote>${renderInline(quote.trim())}</blockquote>`; continue;
    }
    if (/^(-{3,}|\*{3,})\s*$/.test(line)) { closeList(); html += '<hr>'; i++; continue; }
    const task = line.match(/^[-*]\s+\[([ xX])\]\s+(.*)$/);
    if (task) { if (listType !== 'ul') { closeList(); html += '<ul>'; listType = 'ul'; } const done = task[1].toLowerCase() === 'x'; html += `<li class="task"><span class="task-box" data-done="${done}">${done ? '✓' : ''}</span>${renderInline(task[2])}</li>`; i++; continue; }
    if (/^[-*]\s+/.test(line)) { if (listType !== 'ul') { closeList(); html += '<ul>'; listType = 'ul'; } html += `<li>${renderInline(line.replace(/^[-*]\s+/, ''))}</li>`; i++; continue; }
    if (/^\d+\.\s+/.test(line)) { if (listType !== 'ol') { closeList(); html += '<ol>'; listType = 'ol'; } html += `<li>${renderInline(line.replace(/^\d+\.\s+/, ''))}</li>`; i++; continue; }
    if (/^\s*$/.test(line)) { closeList(); i++; continue; }
    closeList(); html += `<p>${renderInline(line)}</p>`; i++;
  }
  closeList();
  return html;
}

/* ===========================================================================
   SEARCH + ASK  (live: /search /hybrid /ask)
   ========================================================================= */
let searchSeq = 0;
async function runSearch() {
  const q = state.query.trim();
  const list = $('#list');
  if (!q) return renderDefaultList();
  if (state.mode === 'ask') return runAsk(q);
  const seq = ++searchSeq;
  list.innerHTML = '<div class="loading">searching</div>';
  try {
    const endpoint = state.mode === 'hybrid' ? '/hybrid' : '/search';
    const hits = await post(endpoint, { query: q, k: 20 });
    if (seq !== searchSeq) return;                    // stale response
    if (!hits.length) { list.innerHTML = '<div class="empty">No matches in your vault.</div>'; return; }
    list.innerHTML = `<div class="list-label">${state.mode} · ${hits.length} results</div>`;
    hits.forEach((h) => list.appendChild(itemEl({ id: h.path, score: h.score, heading: hitHeading(h), text: h.text })));
  } catch (e) {
    if (seq === searchSeq) list.innerHTML = `<div class="empty">Search failed: ${esc(String(e.message || e))}</div>`;
  }
}
function hitHeading(h) {
  const base = (h.path || '').replace(/\.md$/, '');
  return h.heading ? base.split('/').slice(0, -1).concat('').join('/') + ' › ' + h.heading : base;
}
async function runAsk(q) {
  const list = $('#list');
  const seq = ++searchSeq;
  list.innerHTML = '<div class="answer"><div class="answer-head"><span class="spark">✦</span> answer</div><div class="answer-thinking">thinking over your notes…</div></div>';
  try {
    const r = await post('/ask', { query: q, k: 6 });
    if (seq !== searchSeq) return;
    renderAnswer(r);
  } catch (e) {
    if (seq === searchSeq) list.innerHTML = `<div class="empty">Ask failed: ${esc(String(e.message || e))}</div>`;
  }
}
function renderAnswer(r) {
  const list = $('#list'); list.innerHTML = '';
  const sources = r.sources || [];
  const card = document.createElement('div'); card.className = 'answer';
  if (r.answer) {
    let body = renderInline(r.answer).replace(/\[(\d+)\]/g, (_, n) => `<span class="cite" data-cite="${n}">${n}</span>`);
    card.innerHTML = `<div class="answer-head"><span class="spark">✦</span> answer · ${esc(r.model || 'claude')}</div><div class="answer-body">${body}</div>`;
  } else {
    card.innerHTML = `<div class="answer-head"><span class="spark">✦</span> answer</div><div class="answer-body">${esc(r.error || 'No answer.')}</div>`;
  }
  list.appendChild(card);
  $$('.cite', card).forEach((c) => c.onclick = () => { const s = sources[+c.dataset.cite - 1]; s && openNote(s.path); });
  $$('.wikilink', card).forEach((a) => a.onclick = () => openByLabel(a.dataset.link));
  if (sources.length) {
    const lbl = document.createElement('div'); lbl.className = 'list-label'; lbl.textContent = 'sources'; list.appendChild(lbl);
    sources.forEach((h) => list.appendChild(itemEl({ id: h.path, score: h.score, heading: hitHeading(h), text: h.text })));
  }
}

/* sidebar item + lists */
function itemEl(it) {
  const note = byId.get(it.id);
  const div = document.createElement('div');
  div.className = 'item'; div.dataset.id = it.id;
  div.dataset.active = String(it.id === state.noteId);
  const label = note ? note.label : (it.id || '').split('/').pop().replace(/\.md$/, '');
  const dc = note ? domainColor(note) : FALLBACK;
  const score = it.score != null ? `<span class="item-score">${(+it.score).toFixed(3)}</span>` : '';
  div.innerHTML =
    `<div class="item-row"><span class="item-dot" style="background:${dc};color:${dc}"></span>` +
    `<span class="item-title">${esc(label)}</span>${score}</div>` +
    `<div class="item-ctx">${esc(it.heading || (it.id || '').replace(/\.md$/, ''))}</div>` +
    (it.text ? `<div class="item-snip">${esc(it.text)}</div>` : '');
  div.onclick = () => openNote(it.id);
  return div;
}
function renderDefaultList() {
  const list = $('#list');
  const sorted = [...NODES].sort((a, b) => deg(b.id) - deg(a.id));
  const hubs = sorted.filter((n) => n.type === 'moc' || deg(n.id) >= 5);
  const rest = sorted.filter((n) => !hubs.includes(n));
  list.innerHTML = '';
  const section = (label, arr) => {
    if (!arr.length) return;
    const l = document.createElement('div'); l.className = 'list-label'; l.textContent = label; list.appendChild(l);
    arr.forEach((n) => list.appendChild(itemEl({ id: n.id, heading: n.id.replace(/\.md$/, '') })));
  };
  section('hubs · most linked', hubs);
  section('all notes', rest.slice(0, 400));
}
function setActiveList() { $$('#list .item').forEach((el) => el.dataset.active = String(el.dataset.id === state.noteId)); }

/* ===========================================================================
   NOTE READER
   ========================================================================= */
let miniGraph = null;
function openByLabel(label) { const n = byLabel.get(String(label).toLowerCase()); if (n) openNote(n.id); }
async function openNote(id) {
  const note = byId.get(id); if (!note) return;
  state.noteId = id;
  setView('note');
  setCrumbs(['Vault', note.folder || 'Vault', note.label]);
  const dc = domainColor(note);
  const reader = $('#reader');
  reader.scrollTop = 0;
  const head =
    `<div class="note-kicker"><span>${statusGlyph(note.status)}</span><span class="path">${esc(note.id)}</span></div>` +
    `<h1 class="note-h1">${esc(note.label)}</h1>` +
    `<div class="note-tags">` +
      (note.domain ? `<span class="tagpill"><span class="swatch" style="background:${dc};color:${dc}"></span><b>${esc(domainLabel(note.domain))}</b></span>` : '') +
      `<span class="tagpill">type <b>${esc(note.type || '—')}</b></span>` +
      `<span class="tagpill">status <b>${esc(note.status || '—')}</b></span>` +
      `<span class="tagpill">folder <b>${esc(note.folder || '—')}</b></span>` +
    `</div>`;
  reader.innerHTML = `<div class="reader-inner">${head}<div class="md"><div class="loading">loading note…</div></div></div>`;
  renderAside(note);
  setActiveList();
  try {
    const data = await api('/note?path=' + encodeURIComponent(id));
    if (state.noteId !== id) return;                  // navigated away
    const body = stripFrontmatter(data.content || '');
    const md = $('#reader .md');
    if (md) {
      md.innerHTML = renderMarkdown(body);
      $$('#reader .wikilink').forEach((a) => a.onclick = () => openByLabel(a.dataset.link));
    }
  } catch (e) {
    const md = $('#reader .md');
    if (md) md.innerHTML = `<div class="empty">Couldn't load this note: ${esc(String(e.message || e))}</div>`;
  }
}
function renderAside(note) {
  const aside = $('#noteAside');
  const backIds = [...new Set(WIKI_DIR.filter((e) => e.to === note.id).map((e) => e.from))];
  const back = backIds.map((id) => byId.get(id)).filter(Boolean);
  const rel = SEM.filter((e) => e.source === note.id || e.target === note.id)
    .map((e) => ({ id: e.source === note.id ? e.target : e.source, score: e.score }))
    .sort((a, b) => b.score - a.score);

  aside.innerHTML =
    `<div class="aside-sec"><div class="aside-h">Local graph</div><div class="mini-graph" id="miniGraph"></div></div>` +
    `<div class="aside-sec"><div class="aside-h">Backlinks <span class="n">${back.length}</span></div>${back.map(backlinkEl).join('') || '<div class="empty" style="padding:6px 2px;text-align:left">No backlinks yet.</div>'}</div>` +
    `<div class="aside-sec"><div class="aside-h">Semantic neighbours <span class="n">${rel.length}</span></div>${rel.map(relEl).join('') || '<div class="empty" style="padding:6px 2px;text-align:left">None yet.</div>'}</div>`;

  $$('#noteAside .backlink').forEach((el) => el.onclick = () => openNote(el.dataset.id));
  $$('#noteAside .related-row').forEach((el) => el.onclick = () => openNote(el.dataset.id));
  buildMiniGraph(note);
}
function backlinkEl(src) {
  return `<div class="backlink" data-id="${esc(src.id)}"><div class="backlink-t"><span class="item-dot" style="background:${domainColor(src)};color:${domainColor(src)}"></span>${esc(src.label)}</div></div>`;
}
function relEl({ id, score }) {
  const n = byId.get(id); if (!n) return '';
  return `<div class="related-row" data-id="${esc(id)}"><span class="item-dot" style="background:${domainColor(n)};color:${domainColor(n)}"></span><span class="rt">${esc(n.label)}</span><span class="rs">~${(+score).toFixed(2)}</span></div>`;
}
function buildMiniGraph(note) {
  const neigh = new Set([note.id]);
  WIKI.forEach((e) => { if (e.source === note.id) neigh.add(e.target); if (e.target === note.id) neigh.add(e.source); });
  SEM.forEach((e) => { if (e.source === note.id) neigh.add(e.target); if (e.target === note.id) neigh.add(e.source); });
  const nodes = [...neigh].map((id) => { const x = byId.get(id); return { id, label: x.label, domain: x.domain, color: domainColor(x), deg: deg(id) }; });
  const ids = neigh;
  const links = []
    .concat(WIKI.filter((e) => ids.has(e.source) && ids.has(e.target)).map((e) => ({ ...e, kind: 'wiki' })))
    .concat(SEM.filter((e) => ids.has(e.source) && ids.has(e.target)));
  if (miniGraph) miniGraph.destroy();
  miniGraph = new CortexGraph($('#miniGraph'), { interactive: true, mini: true, onNodeClick: (n) => openNote(n.id) });
  miniGraph.opts.light = state.theme === 'light';
  miniGraph.setData(nodes, links);
  miniGraph.setPin(note.id);
}

/* ===========================================================================
   LIBRARY
   ========================================================================= */
function renderLibrary(filterDomain) {
  const lib = $('#library');
  const chips = `<div class="lib-filters"><button class="chip" data-d="all" data-on="${!filterDomain}">all</button>` +
    DOMAIN_LIST.map((d) => `<button class="chip" data-d="${esc(d)}" data-on="${filterDomain === d}">${esc(domainLabel(d))}</button>`).join('') + `</div>`;
  const notes = NODES.filter((n) => !filterDomain || n.domain === filterDomain);
  const cards = notes.map((note) => {
    const c = domainColor(note), links = deg(note.id);
    return `<div class="card" data-id="${esc(note.id)}"><div class="card-glow" style="background:${c}"></div>` +
      `<div class="card-top"><span class="card-dot" style="background:${c};color:${c}"></span><span class="card-type">${esc(note.type || '—')}</span></div>` +
      `<div class="card-title">${esc(note.label)}</div>` +
      `<div class="card-snip">${esc(note.folder || '')}</div>` +
      `<div class="card-foot"><span>${statusGlyph(note.status)} ${esc(note.status || '—')}</span><span class="sep">·</span><span>${links} links</span></div>` +
    `</div>`;
  }).join('');
  lib.innerHTML = `<div class="lib-head"><div class="lib-title">Library</div><div class="side-sub">${notes.length} notes</div></div>${chips}<div class="lib-grid">${cards}</div>`;
  $$('#library .card').forEach((el) => el.onclick = () => openNote(el.dataset.id));
  $$('#library .lib-filters .chip').forEach((el) => el.onclick = () => renderLibrary(el.dataset.d === 'all' ? null : el.dataset.d));
}

/* ===========================================================================
   ROUTING / VIEWS
   ========================================================================= */
function setView(v) {
  state.view = v;
  $('#view-graph').hidden = v !== 'graph';
  $('#view-note').hidden = v !== 'note';
  $('#view-library').hidden = v !== 'library';
  $$('#seg .seg-btn').forEach((b) => b.dataset.on = String(b.dataset.view === (v === 'note' ? '' : v)));
  $$('.rail-btn[data-view]').forEach((b) => b.dataset.on = String(b.dataset.view === v || (v === 'note' && b.dataset.view === 'graph')));
  if (v === 'graph') { if (!graph) initGraph(); else { graph.resize(); setCrumbs(['Vault', 'Constellation']); } }
  if (v === 'library') { renderLibrary(); setCrumbs(['Vault', 'Library']); }
}
function setCrumbs(arr) {
  $('#crumbs').innerHTML = arr.map((c, i) =>
    (i === arr.length - 1 ? `<span class="crumb crumb--here">${esc(c)}</span>` : `<span class="crumb">${esc(c)}</span><span class="crumb-sep">/</span>`)
  ).join('');
}

/* ===========================================================================
   COMMAND PALETTE
   ========================================================================= */
const cmdkScrim = $('#cmdkScrim'), cmdkInput = $('#cmdkInput'), cmdkList = $('#cmdkList');
let cmdkItems = [], cmdkActive = 0;
const COMMANDS = [
  { kind: 'cmd', icon: 'graph', name: 'Open Constellation', run: () => setView('graph') },
  { kind: 'cmd', icon: 'grid', name: 'Open Library', run: () => setView('library') },
  { kind: 'cmd', icon: 'ask', name: 'Ask your notes a question…', run: () => { closeCmdk(); setMode('ask'); $('#q').focus(); } },
  { kind: 'cmd', icon: 'graph', name: 'Re-layout the constellation', run: () => { setView('graph'); graph && graph.reheat(); } },
];
function openCmdk() { cmdkScrim.dataset.open = 'true'; cmdkInput.value = ''; renderCmdk(''); setTimeout(() => cmdkInput.focus(), 30); }
function closeCmdk() { cmdkScrim.dataset.open = 'false'; }
function renderCmdk(q) {
  const ql = q.toLowerCase().trim();
  const noteHits = NODES
    .map((n) => ({ n, s: !ql ? deg(n.id) : (n.label.toLowerCase().includes(ql) ? 100 + deg(n.id) : ((n.folder || '').toLowerCase().includes(ql) ? 10 : -1)) }))
    .filter((x) => x.s >= 0).sort((a, b) => b.s - a.s).slice(0, 8)
    .map(({ n }) => ({ kind: 'note', note: n, name: n.label }));
  const cmdHits = COMMANDS.filter((c) => !ql || c.name.toLowerCase().includes(ql));
  cmdkItems = [];
  let html = '';
  if (cmdHits.length) { html += `<div class="cmdk-group">Actions</div>`; cmdHits.forEach((c) => { cmdkItems.push(c); html += cmdkRow(c, cmdkItems.length - 1); }); }
  if (noteHits.length) { html += `<div class="cmdk-group">Notes</div>`; noteHits.forEach((c) => { cmdkItems.push(c); html += cmdkRow(c, cmdkItems.length - 1); }); }
  if (!cmdkItems.length) html = `<div class="empty" style="padding:24px">No matches.</div>`;
  cmdkList.innerHTML = html;
  cmdkActive = 0; highlightCmdk();
  $$('.cmdk-item', cmdkList).forEach((el) => { el.onclick = () => runCmdk(+el.dataset.i); el.onmousemove = () => { cmdkActive = +el.dataset.i; highlightCmdk(); }; });
}
const CMDK_ICONS = {
  graph: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="6" cy="7" r="1.8"/><circle cx="18" cy="6" r="1.8"/><circle cx="12" cy="13" r="2.2" fill="currentColor" stroke="none"/></svg>',
  grid: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="4" y="4" width="7" height="7" rx="1.4"/><rect x="13" y="4" width="7" height="7" rx="1.4"/><rect x="4" y="13" width="7" height="7" rx="1.4"/><rect x="13" y="13" width="7" height="7" rx="1.4"/></svg>',
  ask: '<span style="color:#fff">✦</span>',
};
function cmdkRow(c, i) {
  if (c.kind === 'note') {
    return `<div class="cmdk-item" data-i="${i}"><span class="cmdk-dot" style="background:${domainColor(c.note)};color:${domainColor(c.note)}"></span><span class="ct">${esc(c.name)}</span><span class="cmeta">${esc(topFolder(c.note.folder))}</span><span class="cmdk-go">open ↵</span></div>`;
  }
  return `<div class="cmdk-item" data-i="${i}"><span class="cmdk-ico">${CMDK_ICONS[c.icon] || ''}</span><span class="ct">${esc(c.name)}</span><span class="cmdk-go">run ↵</span></div>`;
}
function highlightCmdk() { $$('.cmdk-item', cmdkList).forEach((el) => el.dataset.active = String(+el.dataset.i === cmdkActive)); }
function runCmdk(i) { const c = cmdkItems[i]; if (!c) return; closeCmdk(); if (c.kind === 'note') openNote(c.note.id); else c.run(); }

/* ===========================================================================
   TWEAKS
   ========================================================================= */
const twPanel = $('#twPanel');
function renderTweaks() {
  twPanel.innerHTML =
    `<div class="tw-head"><span class="tw-title">Tweaks</span><button class="tw-x" id="twClose">×</button></div>` +
    `<div class="tw-body">` +
      twSwatch('Node palette', 'palette') +
      twSeg('Color nodes by', 'colorBy', [['domain', 'Domain'], ['folder', 'Folder'], ['type', 'Type']]) +
      twSeg('Links', 'linkMode', [['wiki', 'Wiki'], ['both', 'Both'], ['semantic', 'Sem']]) +
      twSeg('Labels', 'labels', [['all', 'All'], ['hubs', 'Hubs'], ['off', 'Off']]) +
      `<div class="tw-ctl"><div class="tw-l">Node glow <span class="v" id="glowV">${state.glow.toFixed(1)}×</span></div><input type="range" id="glowR" min="0" max="2" step="0.1" value="${state.glow}"></div>` +
    `</div>`;
  $('#twClose').onclick = () => toggleTweaks(false);
  $$('#twPanel .tw-seg').forEach((seg) => { const key = seg.dataset.key; $$('.tw-opt', seg).forEach((b) => b.onclick = () => setTweak(key, b.dataset.v)); });
  $$('#twPanel .tw-sw').forEach((sw) => sw.onclick = () => setTweak('palette', sw.dataset.v));
  $('#glowR').oninput = (e) => { state.glow = +e.target.value; $('#glowV').textContent = state.glow.toFixed(1) + '×'; if (graph) { graph.glow = state.glow; graph._start(); } persist(); };
}
function twSeg(label, key, opts) {
  return `<div class="tw-ctl"><div class="tw-l">${label}</div><div class="tw-seg" data-key="${key}">` +
    opts.map(([v, t]) => `<button class="tw-opt" data-v="${v}" data-on="${state[key] === v}">${t}</button>`).join('') + `</div></div>`;
}
function twSwatch(label, key) {
  const order = ['calm', 'vivid', 'mono'];
  return `<div class="tw-ctl"><div class="tw-l">${label} <span class="v">${state.palette}</span></div><div class="tw-swatches">` +
    order.map((p) => `<div class="tw-sw" data-v="${p}" data-on="${state.palette === p}" style="background:conic-gradient(${PALETTES[p].slice(0, 6).join(',')})"></div>`).join('') + `</div></div>`;
}
function setTweak(key, v) {
  state[key] = v;
  if (key === 'colorBy') state.mutedDomains = new Set();
  if (key === 'labels' && graph) graph.opts.labels = v;
  refreshGraph(); renderTweaks(); persist();
  if (state.view === 'library') renderLibrary();
  if (state.noteId && state.view === 'note') renderAside(byId.get(state.noteId));
}
function toggleTweaks(on) {
  const show = on == null ? twPanel.hidden : on;
  twPanel.hidden = !show; $('#twFab').style.display = show ? 'none' : 'grid';
  if (show) renderTweaks();
}

/* persistence */
function persist() {
  try { localStorage.setItem('cortex.tweaks', JSON.stringify({ theme: state.theme, palette: state.palette, labels: state.labels, glow: state.glow })); } catch (e) {}
}
function restore() {
  try {
    const s = JSON.parse(localStorage.getItem('cortex.tweaks') || '{}');
    if (s.palette) state.palette = s.palette;
    if (s.labels) state.labels = s.labels;
    if (typeof s.glow === 'number') state.glow = s.glow;
  } catch (e) {}
}

/* search modes */
function setMode(m) {
  state.mode = m;
  $$('#modes .chip').forEach((c) => c.dataset.on = String(c.dataset.mode === m));
  $('#q').placeholder = m === 'ask' ? 'Ask your notes a question…' : 'Search your mind…';
  if (state.query.trim()) runSearch();
}

/* ===========================================================================
   WIRING / BOOT
   ========================================================================= */
let searchTimer;
$('#q').addEventListener('input', (e) => { state.query = e.target.value; clearTimeout(searchTimer); searchTimer = setTimeout(runSearch, state.mode === 'ask' ? 500 : 220); });
$('#q').addEventListener('keydown', (e) => { if (e.key === 'Enter') { clearTimeout(searchTimer); runSearch(); } });
$$('#modes .chip').forEach((c) => c.onclick = () => setMode(c.dataset.mode));
$$('#seg .seg-btn').forEach((b) => b.onclick = () => setView(b.dataset.view));
$$('.rail-btn[data-view]').forEach((b) => b.onclick = () => {
  if (b.dataset.view === 'search') { $('#q').focus(); return; }
  if (b.dataset.view === 'daily') { setView('library'); return; }
  setView(b.dataset.view);
});
$('#cmdBtn').onclick = openCmdk;
$('#cmdRailBtn').onclick = openCmdk;
$('#twFab').onclick = () => toggleTweaks(true);

cmdkInput.addEventListener('input', (e) => renderCmdk(e.target.value));
cmdkScrim.addEventListener('click', (e) => { if (e.target === cmdkScrim) closeCmdk(); });
window.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); cmdkScrim.dataset.open === 'true' ? closeCmdk() : openCmdk(); return; }
  if (cmdkScrim.dataset.open === 'true') {
    if (e.key === 'Escape') closeCmdk();
    if (e.key === 'ArrowDown') { e.preventDefault(); cmdkActive = Math.min(cmdkActive + 1, cmdkItems.length - 1); highlightCmdk(); ensureCmdkVisible(); }
    if (e.key === 'ArrowUp') { e.preventDefault(); cmdkActive = Math.max(cmdkActive - 1, 0); highlightCmdk(); ensureCmdkVisible(); }
    if (e.key === 'Enter') { e.preventDefault(); runCmdk(cmdkActive); }
  } else if (e.key === 'Escape' && !twPanel.hidden) toggleTweaks(false);
});
function ensureCmdkVisible() { const el = $(`.cmdk-item[data-i="${cmdkActive}"]`, cmdkList); if (el) { const r = el.getBoundingClientRect(), pr = cmdkList.getBoundingClientRect(); if (r.bottom > pr.bottom) cmdkList.scrollTop += r.bottom - pr.bottom; if (r.top < pr.top) cmdkList.scrollTop -= pr.top - r.top; } }

function setStatus(h) { $('#status').textContent = `${h.notes ?? '—'} notes · ${h.chunks ?? '—'} chunks`; }
function showOffline(e) {
  $('#list').innerHTML = `<div class="empty">Cortex engine not reachable.<br><span style="opacity:.7">${esc(String(e && e.message || e))}</span><br><br>Start it with <code>cortex watch</code> (serves this UI + the API on loopback).</div>`;
  $('#graphMeta').textContent = 'engine offline';
}

async function boot() {
  restore();
  try {
    const graphData = await api('/graph');
    buildModel(graphData);
    api('/health').then(setStatus).catch(() => {});
    renderDefaultList();
    setView('graph');
    // semantic edges are slower (first call embeds every note) — load then refresh.
    api('/semantic_graph?k=5').then((s) => { applySemantic(s.edges); if (graph) refreshGraph(); }).catch(() => {});
  } catch (e) {
    showOffline(e);
  }
}
boot();
