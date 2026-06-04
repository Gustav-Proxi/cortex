'use strict';
/* ============================================================================
   CortexGraph — a small, dependency-free force-directed graph on <canvas>.
   Hand-rolled physics (repulsion + springs + centering + collision), pan/zoom,
   hover-to-highlight-neighbours, level-of-detail labels, soft node glow.
   Used for both the full Constellation and the note-detail mini-graph.

   const g = new CortexGraph(hostEl, { onNodeClick, onNodeHover, interactive });
   g.setData(nodes, links);           // nodes: {id,label,color,deg,...}
   g.setLinkVisibility(fn);  g.setColorOf(fn);  g.focus(id);  g.reheat();
   ========================================================================== */

(function () {
  const TAU = Math.PI * 2;
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

  function hexToRgb(hex) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex || '');
    if (!m) return [255, 255, 255];
    const n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  const rgba = (hex, a) => { const [r, g, b] = hexToRgb(hex); return `rgba(${r},${g},${b},${a})`; };
  // mix a hex toward white by t (0..1) → returns rgb() for a luminous core
  function lighten(hex, t) {
    const [r, g, b] = hexToRgb(hex);
    return `rgb(${Math.round(r + (255 - r) * t)},${Math.round(g + (255 - g) * t)},${Math.round(b + (255 - b) * t)})`;
  }
  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  class CortexGraph {
    constructor(host, opts = {}) {
      this.host = host;
      this.opts = Object.assign({
        interactive: true, labels: 'all', hubDeg: 5, mini: false,
        onNodeClick: null, onNodeHover: null, inkLabels: true,
      }, opts);
      this.canvas = document.createElement('canvas');
      this.canvas.style.display = 'block';
      this.canvas.style.width = '100%';
      this.canvas.style.height = '100%';
      host.appendChild(this.canvas);
      this.ctx = this.canvas.getContext('2d');

      this.nodes = []; this.links = []; this.byId = new Map(); this.adj = new Map();
      this.t = { x: 0, y: 0, k: 1 };           // pan/zoom transform
      this.alpha = 1; this.running = false;
      this.hoverId = null; this.pinId = null; this.hoverSet = new Set();
      this.mutedDomains = new Set();
      this.dpr = Math.min(window.devicePixelRatio || 1, 2);
      this._frame = this._frame.bind(this);

      this._initInput();
      this._ro = new ResizeObserver(() => this.resize());
      this._ro.observe(host);
      this.resize();
    }

    /* ---- data ---- */
    setData(nodes, links) {
      const prev = this.byId;
      const N = nodes.length;
      const GA = Math.PI * (3 - Math.sqrt(5));       // golden angle
      const spread = (this.opts.mini ? 26 : 64) * Math.sqrt(Math.max(1, N));
      this.nodes = nodes.map((n, i) => {
        const old = prev.get(n.id);
        // Deterministic phyllotaxis seed → even disc, consistent settling, no
        // flung outliers (vs random init which gave wildly different layouts).
        const rr = spread * Math.sqrt((i + 0.5) / N);
        const th = i * GA;
        return Object.assign({
          x: old ? old.x : Math.cos(th) * rr,
          y: old ? old.y : Math.sin(th) * rr,
          vx: 0, vy: 0,
        }, n);
      });
      this.byId = new Map(this.nodes.map((n) => [n.id, n]));
      this.setLinks(links);
      this.alpha = 1;
      // Synchronous warmup + instant fit so the FIRST painted frame is already
      // laid out and centred — independent of requestAnimationFrame (which some
      // hosts pause for backgrounded iframes). rAF then just refines/animates.
      const warm = this.opts.mini ? 120 : 260;
      for (let i = 0; i < warm; i++) this._tick();
      this._fitInstant(this.opts.mini ? 24 : 80);
      this.alpha = Math.max(this.alpha, 0.12);
      this._render();
      this._start();
      return this;
    }
    _fitInstant(pad = 80) {
      if (!this.nodes.length) return;
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      for (const n of this.nodes) { minX = Math.min(minX, n.x); minY = Math.min(minY, n.y); maxX = Math.max(maxX, n.x); maxY = Math.max(maxY, n.y); }
      const w = Math.max(1, maxX - minX), h = Math.max(1, maxY - minY);
      const k = clamp(Math.min((this.W - pad * 2) / w, (this.H - pad * 2) / h), 0.15, this.opts.mini ? 2.4 : 2.0);
      const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
      this.t = { k, x: this.W / 2 - cx * k, y: this.H / 2 - cy * k };
    }
    setLinks(links) {
      this.links = links
        .map((l) => ({ source: this.byId.get(l.source), target: this.byId.get(l.target), kind: l.kind || 'wiki', score: l.score }))
        .filter((l) => l.source && l.target);
      this.adj = new Map();
      for (const l of this.links) {
        if (!this.adj.has(l.source.id)) this.adj.set(l.source.id, new Set());
        if (!this.adj.has(l.target.id)) this.adj.set(l.target.id, new Set());
        this.adj.get(l.source.id).add(l.target.id);
        this.adj.get(l.target.id).add(l.source.id);
      }
      this.alpha = Math.max(this.alpha, 0.6); this._start();
    }
    setMutedDomains(set) { this.mutedDomains = set || new Set(); }

    /* ---- view ---- */
    resize() {
      const r = this.host.getBoundingClientRect();
      this.W = Math.max(1, r.width); this.H = Math.max(1, r.height);
      this.canvas.width = Math.round(this.W * this.dpr);
      this.canvas.height = Math.round(this.H * this.dpr);
      this._start();
    }
    fit(pad = 80, dur = 600) {
      if (!this.nodes.length) return;
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      for (const n of this.nodes) { minX = Math.min(minX, n.x); minY = Math.min(minY, n.y); maxX = Math.max(maxX, n.x); maxY = Math.max(maxY, n.y); }
      const w = Math.max(1, maxX - minX), h = Math.max(1, maxY - minY);
      const k = clamp(Math.min((this.W - pad * 2) / w, (this.H - pad * 2) / h), 0.15, this.opts.mini ? 2.4 : 2.2);
      const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
      this._animateTo({ k, x: this.W / 2 - cx * k, y: this.H / 2 - cy * k }, dur);
    }
    _animateTo(target, dur) {
      const from = Object.assign({}, this.t), t0 = performance.now();
      const ease = (p) => 1 - Math.pow(1 - p, 3);
      const step = (now) => {
        const p = clamp((now - t0) / dur, 0, 1), e = ease(p);
        this.t = { x: from.x + (target.x - from.x) * e, y: from.y + (target.y - from.y) * e, k: from.k + (target.k - from.k) * e };
        this._start();
        if (p < 1) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    }
    focus(id, zoom = 2.0) {
      const n = this.byId.get(id); if (!n) return;
      this.pinId = id;
      this._animateTo({ k: zoom, x: this.W / 2 - n.x * zoom, y: this.H / 2 - n.y * zoom }, 600);
    }
    setPin(id) { this.pinId = id; this._start(); }
    reheat() { this.alpha = 0.9; this._start(); setTimeout(() => this.fit(this.opts.mini ? 24 : 80), 600); }

    /* ---- physics ---- */
    _tick() {
      const nodes = this.nodes, n = nodes.length;
      if (!n) return;
      const a = this.alpha;
      const charge = this.opts.mini ? -700 : -1200;
      const repRange = this.opts.mini ? 380 : 620;
      const linkDist = this.opts.mini ? 48 : 92, linkK = 0.42;
      const center = this.opts.mini ? 0.06 : 0.06;
      // repulsion + collision (O(n^2) — fine for <200 nodes)
      for (let i = 0; i < n; i++) {
        const p = nodes[i];
        for (let j = i + 1; j < n; j++) {
          const q = nodes[j];
          let dx = p.x - q.x, dy = p.y - q.y, d2 = dx * dx + dy * dy;
          if (d2 < 1e-4) { dx = (Math.random() - 0.5); dy = (Math.random() - 0.5); d2 = 1; }
          const dist = Math.sqrt(d2);
          // coulomb repulsion (1/d^2), capped range → spreads into a constellation
          if (dist < repRange) {
            const f = (charge * a) / d2;
            const fx = (dx / dist) * f, fy = (dy / dist) * f;
            p.vx += fx; p.vy += fy; q.vx -= fx; q.vy -= fy;
          }
          // soft collision so dots never overlap
          const rr = (this._r(p) + this._r(q) + 10);
          if (dist < rr) {
            const push = (rr - dist) / dist * 0.6 * a;
            p.vx += dx * push; p.vy += dy * push; q.vx -= dx * push; q.vy -= dy * push;
          }
        }
      }
      // springs
      for (const l of this.links) {
        const s = l.source, t = l.target;
        let dx = t.x - s.x, dy = t.y - s.y;
        const dist = Math.sqrt(dx * dx + dy * dy) || 1;
        const want = l.kind === 'sem' ? linkDist * 1.5 : linkDist;
        const f = (dist - want) / dist * linkK * a * (l.kind === 'sem' ? 0.4 : 1);
        const fx = dx * f, fy = dy * f;
        s.vx += fx; s.vy += fy; t.vx -= fx; t.vy -= fy;
      }
      // centering + integrate (with hard clamps so the sim can never diverge)
      const vmax = this.opts.mini ? 38 : 42;
      const pmax = 6000;
      for (const p of nodes) {
        p.vx -= p.x * center * a * 0.06;
        p.vy -= p.y * center * a * 0.06;
        if (p === this._drag) continue;
        p.vx *= 0.80; p.vy *= 0.80;
        if (!isFinite(p.vx)) p.vx = 0;
        if (!isFinite(p.vy)) p.vy = 0;
        p.vx = clamp(p.vx, -vmax, vmax);
        p.vy = clamp(p.vy, -vmax, vmax);
        p.x = clamp(p.x + p.vx, -pmax, pmax);
        p.y = clamp(p.y + p.vy, -pmax, pmax);
      }
      this.alpha *= 0.97;
      if (this.alpha < 0.01) this.alpha = 0;
    }
    _r(nd) {
      if (this.opts.mini) return nd.id === this.pinId ? 5 : 3.4;
      return 2.4 + Math.min(nd.deg || 0, 20) * 0.32;     // ~2.4–8.8px
    }

    /* ---- render loop ---- */
    _start() { if (!this.running) { this.running = true; requestAnimationFrame(this._frame); } }
    _frame() {
      if (this.alpha > 0) this._tick();
      this._render();
      if (this.alpha > 0 || this._anim || this.hoverId || this.pinId) { requestAnimationFrame(this._frame); }
      else this.running = false;
    }

    _isHot(l) { const f = this.hoverId || this.pinId; return f && (l.source.id === f || l.target.id === f); }
    _focusedNode(nd) {
      if (this.hoverId) return nd.id === this.hoverId || this.hoverSet.has(nd.id);
      return true;
    }
    _dim(nd) { return this.mutedDomains.has(nd.domain); }

    _render() {
      const ctx = this.ctx, dpr = this.dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, this.W, this.H);
      ctx.save();
      ctx.translate(this.t.x, this.t.y);
      ctx.scale(this.t.k, this.t.k);
      const k = this.t.k;
      const light = this.opts.light;
      const gm = this.glow == null ? 1 : this.glow;
      const now = performance.now();
      const baseInk = light ? '20,22,26' : '255,255,255';

      // ---- links: gently curved, endpoint-brightened (monochrome at rest;
      //      colour + flow only on the hovered/pinned focus path) ----
      ctx.lineCap = 'round';
      for (const l of this.links) {
        const hot = this._isHot(l);
        const faded = (this.hoverId && !hot) || this._dim(l.source) || this._dim(l.target);
        const s = l.source, t = l.target;
        const mx = (s.x + t.x) / 2, my = (s.y + t.y) / 2;
        const dx = t.x - s.x, dy = t.y - s.y;
        const bow = l.kind === 'sem' ? 0.16 : 0.05;
        const cx = mx - dy * bow, cy = my + dx * bow;
        ctx.beginPath();
        ctx.moveTo(s.x, s.y);
        ctx.quadraticCurveTo(cx, cy, t.x, t.y);
        if (hot) {
          // focus path: blend the two node colours + soft glow + flowing dashes
          const grad = ctx.createLinearGradient(s.x, s.y, t.x, t.y);
          grad.addColorStop(0, rgba(s.color || '#fff', 0.95));
          grad.addColorStop(1, rgba(t.color || '#fff', 0.95));
          ctx.strokeStyle = grad;
          ctx.lineWidth = 1.6 / k;
          ctx.shadowColor = rgba(s.color || '#fff', 0.7);
          ctx.shadowBlur = 7 * gm;
          ctx.setLineDash([7 / k, 9 / k]);
          ctx.lineDashOffset = -((now * 0.045) % (16 / k));
        } else {
          // resting: white-alpha, brighter near the nodes so edges read as joints
          const a = l.kind === 'sem' ? (faded ? 0.035 : 0.11) : (faded ? 0.05 : 0.2);
          const grad = ctx.createLinearGradient(s.x, s.y, t.x, t.y);
          grad.addColorStop(0, `rgba(${baseInk},${a * 1.5})`);
          grad.addColorStop(0.5, `rgba(${baseInk},${a * 0.55})`);
          grad.addColorStop(1, `rgba(${baseInk},${a * 1.5})`);
          ctx.strokeStyle = grad;
          ctx.lineWidth = (l.kind === 'sem' ? 0.55 : 0.85) / k;
          if (l.kind === 'sem') ctx.setLineDash([2.5 / k, 4.5 / k]); else ctx.setLineDash([]);
        }
        ctx.stroke();
        ctx.shadowBlur = 0; ctx.setLineDash([]); ctx.lineDashOffset = 0;
      }

      // ---- nodes: luminous orbs (additive halo · gradient core · sheen) ----
      // pass 1 — additive glow halos (drawn under the cores)
      {
        ctx.globalCompositeOperation = 'lighter';
        for (const nd of this.nodes) {
          const focused = this._focusedNode(nd) && !this._dim(nd);
          if (!focused) continue;
          const isHover = nd.id === this.hoverId, isPin = nd.id === this.pinId;
          const r = this._r(nd);
          const col = nd.color || '#9aa0a9';
          const boost = (isHover || isPin) ? 2.6 : 1;
          const hr = r * (this.opts.mini ? 3.2 : 4.2) * boost * (0.7 + 0.3 * gm);
          const halo = ctx.createRadialGradient(nd.x, nd.y, 0, nd.x, nd.y, hr);
          halo.addColorStop(0, rgba(col, (this.opts.mini ? 0.28 : 0.34) * (isHover || isPin ? 1.25 : 1)));
          halo.addColorStop(0.45, rgba(col, 0.07));
          halo.addColorStop(1, rgba(col, 0));
          ctx.fillStyle = halo;
          ctx.beginPath(); ctx.arc(nd.x, nd.y, hr, 0, TAU); ctx.fill();
        }
        ctx.globalCompositeOperation = 'source-over';
      }
      // pass 2 — cores
      for (const nd of this.nodes) {
        const r = this._r(nd);
        const focused = this._focusedNode(nd) && !this._dim(nd);
        const isHover = nd.id === this.hoverId, isPin = nd.id === this.pinId;
        const col = nd.color || '#9aa0a9';
        ctx.globalAlpha = focused ? 1 : 0.14;
        // spherical core: light sheen offset toward top-left → full colour at rim
        const cg = ctx.createRadialGradient(nd.x - r * 0.36, nd.y - r * 0.4, r * 0.1, nd.x, nd.y, r * 1.05);
        cg.addColorStop(0, lighten(col, 0.7));
        cg.addColorStop(0.45, lighten(col, 0.12));
        cg.addColorStop(1, col);
        ctx.beginPath(); ctx.arc(nd.x, nd.y, r, 0, TAU);
        ctx.fillStyle = cg; ctx.fill();
        // crisp contact rim for separation on bright clusters
        ctx.globalAlpha = focused ? 0.5 : 0.1;
        ctx.lineWidth = 0.75 / k;
        ctx.strokeStyle = light ? 'rgba(255,255,255,0.6)' : 'rgba(0,0,0,0.45)';
        ctx.stroke();
        ctx.globalAlpha = 1;
        if (isHover || isPin) {           // focus ring
          ctx.lineWidth = 1.5 / k;
          ctx.strokeStyle = light ? '#16181c' : '#ffffff';
          ctx.beginPath(); ctx.arc(nd.x, nd.y, r + 3.5 / k, 0, TAU); ctx.stroke();
        }
        // label
        const la = this._labelAlpha(nd, k);
        if (la > 0) {
          const fs = (this.opts.mini ? 8 : 10) / k;
          ctx.font = `${fs}px "Spline Sans Mono", ui-monospace, monospace`;
          ctx.textAlign = 'center'; ctx.textBaseline = 'top';
          const ly = nd.y + r + 4 / k;
          if (isHover || isPin) {         // legibility chip behind the focused label
            const w = ctx.measureText(nd.label).width;
            ctx.globalAlpha = 0.72;
            ctx.fillStyle = light ? 'rgba(244,244,242,0.92)' : 'rgba(8,10,14,0.82)';
            roundRect(ctx, nd.x - w / 2 - 5 / k, ly - 2 / k, w + 10 / k, fs + 5 / k, 4 / k);
            ctx.fill();
          }
          ctx.globalAlpha = la * (focused ? 1 : 0.4);
          ctx.lineWidth = 3 / k;
          ctx.strokeStyle = light ? 'rgba(244,244,242,0.85)' : 'rgba(0,0,0,0.8)';
          if (!(isHover || isPin)) ctx.strokeText(nd.label, nd.x, ly);
          ctx.fillStyle = (isHover || isPin)
            ? (light ? '#16181c' : '#fff')
            : (light ? '#3a3d42' : '#dfe2e7');
          ctx.fillText(nd.label, nd.x, ly);
          ctx.globalAlpha = 1;
        }
      }
      ctx.restore();
    }
    _labelAlpha(nd, k) {
      if (nd.id === this.hoverId || nd.id === this.pinId) return 1;
      if (this.hoverId && this.hoverSet.has(nd.id)) return 0.9;
      const mode = this.opts.labels;
      if (this.opts.mini) return 0;            // mini-graph: no labels (tooltip instead)
      if (mode === 'off') return 0;
      if (mode === 'all') return k > 1.25 ? 0.92 : k > 0.7 ? 0.5 : 0;
      // hubs
      if ((nd.deg || 0) >= this.opts.hubDeg && k > 0.5) return 0.78;
      if (k > 1.9) return 0.5;
      return 0;
    }

    /* ---- interaction ---- */
    _toWorld(px, py) { return { x: (px - this.t.x) / this.t.k, y: (py - this.t.y) / this.t.k }; }
    _hit(px, py) {
      const w = this._toWorld(px, py);
      let best = null, bestD = Infinity;
      for (const nd of this.nodes) {
        if (this._dim(nd)) continue;
        const dx = nd.x - w.x, dy = nd.y - w.y, d = dx * dx + dy * dy;
        const rr = (this._r(nd) + 6 / this.t.k); // generous target
        if (d < rr * rr && d < bestD) { bestD = d; best = nd; }
      }
      return best;
    }
    setHover(id) {
      this.hoverId = id;
      this.hoverSet = id ? (this.adj.get(id) || new Set()) : new Set();
      this._start();
    }
    _initInput() {
      if (!this.opts.interactive) { this.canvas.style.pointerEvents = 'none'; return; }
      const c = this.canvas;
      let dragging = null, panning = false, lastX = 0, lastY = 0, moved = false, downX = 0, downY = 0;

      const localXY = (e) => { const r = c.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };

      c.addEventListener('pointermove', (e) => {
        const [px, py] = localXY(e);
        if (dragging) {
          const w = this._toWorld(px, py);
          dragging.x = w.x; dragging.y = w.y; dragging.vx = 0; dragging.vy = 0;
          this._drag = dragging; this.alpha = Math.max(this.alpha, 0.12); this._start();
          moved = true; return;
        }
        if (panning) {
          this.t.x += px - lastX; this.t.y += py - lastY; lastX = px; lastY = py; moved = true; this._start(); return;
        }
        const hit = this._hit(px, py);
        const id = hit ? hit.id : null;
        if (id !== this.hoverId) {
          this.setHover(id);
          c.style.cursor = id ? 'pointer' : 'grab';
          if (this.opts.onNodeHover) this.opts.onNodeHover(hit, px, py);
        } else if (hit && this.opts.onNodeHover) {
          this.opts.onNodeHover(hit, px, py);   // keep tooltip following
        }
      });
      c.addEventListener('pointerdown', (e) => {
        const [px, py] = localXY(e); downX = px; downY = py; moved = false;
        const hit = this._hit(px, py);
        c.setPointerCapture(e.pointerId);
        if (hit) { dragging = hit; }
        else { panning = true; lastX = px; lastY = py; }
      });
      c.addEventListener('pointerup', (e) => {
        const [px, py] = localXY(e);
        if (dragging && !moved && this.opts.onNodeClick) this.opts.onNodeClick(dragging);
        else if (!dragging && !moved && this.opts.onBackground) this.opts.onBackground();
        if (dragging) { this._drag = null; this.alpha = Math.max(this.alpha, 0.1); }
        dragging = null; panning = false; this._start();
      });
      c.addEventListener('pointerleave', () => {
        if (this.hoverId) { this.setHover(null); if (this.opts.onNodeHover) this.opts.onNodeHover(null); }
      });
      c.addEventListener('wheel', (e) => {
        e.preventDefault();
        const [px, py] = localXY(e);
        const w = this._toWorld(px, py);
        const factor = Math.exp(-e.deltaY * 0.0015);
        const k = clamp(this.t.k * factor, 0.12, 6);
        this.t.x = px - w.x * k; this.t.y = py - w.y * k; this.t.k = k;
        this._start();
      }, { passive: false });
    }
    destroy() { this._ro.disconnect(); this.host.removeChild(this.canvas); }
  }

  window.CortexGraph = CortexGraph;
})();
