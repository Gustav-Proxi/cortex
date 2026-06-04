'use strict';
/* Cortex constellation — 3D force graph (3d-force-graph / three.js, vendored).
   Drop-in for the old 2D CortexGraph: identical public API
     new CortexGraph(host, opts)
     .setData(nodes, links) · .setLinks(links) · .setMutedDomains(set)
     .setHover(id) · .setPin(id) · .focus(id) · .reheat() · .fit(pad,dur)
     .resize() · .destroy()  + props .opts, .glow, ._start()
   Matte (flat-lit) nodes, continuous WebGL render so hover + motion are reliable,
   and a 3rd axis so a hub-heavy graph spreads into a cloud instead of a flat mush. */
(function () {
  const DIM_NODE = 'rgba(150,156,165,0.16)';
  const byId = (l, end) => (l[end] && l[end].id) || l[end];

  class CortexGraph {
    constructor(host, opts = {}) {
      this.host = host; this.opts = opts; this.glow = opts.glow || 1;
      this.nodes = []; this.links = []; this.adj = {};
      this.hoverId = null; this.hoverSet = new Set(); this.pinId = null; this.muted = new Set();

      const fg = ForceGraph3D({ rendererConfig: { antialias: true, alpha: true } })(host);
      this.fg = fg;
      fg.backgroundColor('rgba(0,0,0,0)')
        .showNavInfo(false)
        .nodeRelSize(4)
        .nodeResolution(opts.mini ? 8 : 16)
        .nodeVal((n) => 0.8 + Math.min(n.deg || 0, 22) * 0.4)
        .nodeColor((n) => this._nodeColor(n))
        .nodeOpacity(0.95)
        .nodeLabel(() => '')                 // we drive the app's own hovercard instead
        .linkColor((l) => this._linkColor(l))
        .linkWidth((l) => (this._hot(l) ? 0.7 : 0))
        .linkOpacity(0.5)
        .enableNodeDrag(!opts.mini)
        .onNodeHover((n) => {
          this._setHover(n ? n.id : null);
          host.style.cursor = n ? 'pointer' : 'grab';
          if (opts.onNodeHover) {
            if (n) { const c = fg.graph2ScreenCoords(n.x, n.y, n.z); opts.onNodeHover(n, c.x, c.y); }
            else opts.onNodeHover(null);
          }
        })
        .onNodeClick((n) => { if (opts.onNodeClick) opts.onNodeClick(n); })
        .onBackgroundClick(() => { this._setHover(null); if (opts.onBackground) opts.onBackground(); });

      // spread + calm physics (3D avoids the planar clumping the 2D layout fought)
      try { fg.d3Force('charge').strength(opts.mini ? -55 : -150).distanceMax(opts.mini ? 300 : 1000); } catch (e) {}
      try { fg.d3Force('link').distance((l) => (l.kind === 'sem' ? 70 : 46)); } catch (e) {}
      fg.d3VelocityDecay(0.42).cooldownTime(opts.mini ? 6000 : 14000);

      this._flatten();   // matte: strong ambient, weak directional → no shiny highlights
      this._ro = new ResizeObserver(() => this.resize());
      this._ro.observe(host);
      this.resize();
    }

    _flatten() {
      try {
        this.fg.scene().children.forEach((o) => {
          if (o.type === 'AmbientLight') o.intensity = 2.4;
          else if (o.type === 'DirectionalLight') o.intensity = 0.22;
        });
      } catch (e) {}
    }

    _nodeColor(n) {
      if (this.muted.has(n.domain)) return 'rgba(120,126,135,0.18)';
      if (this.hoverId && n.id !== this.hoverId && !this.hoverSet.has(n.id)) return DIM_NODE;
      return n.color || '#9aa0a9';
    }
    _hot(l) { const s = byId(l, 'source'), t = byId(l, 'target'); return this.hoverId && (s === this.hoverId || t === this.hoverId); }
    _linkColor(l) {
      if (this._hot(l)) return 'rgba(255,255,255,0.7)';
      if (this.hoverId) return 'rgba(255,255,255,0.04)';
      return `rgba(255,255,255,${l.kind === 'sem' ? 0.05 : 0.16})`;
    }
    _nodeById(id) { return (this.nodes || []).find((n) => n.id === id); }
    _setHover(id) { this.hoverId = id; this.hoverSet = (id && this.adj[id]) || new Set(); }

    setData(nodes, links) {
      this.nodes = nodes || [];
      this.adj = {};
      (links || []).forEach((e) => {
        (this.adj[e.source] = this.adj[e.source] || new Set()).add(e.target);
        (this.adj[e.target] = this.adj[e.target] || new Set()).add(e.source);
      });
      this.links = (links || []).map((e) => ({ source: e.source, target: e.target, kind: e.kind, score: e.score }));
      this.fg.graphData({ nodes: this.nodes, links: this.links });
    }
    setLinks(links) { this.setData(this.nodes, links); }
    setMutedDomains(set) { this.muted = set || new Set(); this.fg.nodeColor(this.fg.nodeColor()); }
    setHover(id) { this._setHover(id); }
    setPin(id) { this.pinId = id; }
    focus(id) {
      const n = this._nodeById(id);
      if (!n || n.x == null) return;
      const r = Math.hypot(n.x, n.y, n.z || 0) || 1, k = 1 + 90 / r;
      this.fg.cameraPosition({ x: n.x * k, y: n.y * k, z: (n.z || 0) * k + 40 }, n, 900);
    }
    reheat() { this.fg.d3ReheatSimulation(); this.fit(90, 800); }
    fit(pad = 80, dur = 600) { try { this.fg.zoomToFit(dur, pad); } catch (e) {} }
    resize() { const r = this.host.getBoundingClientRect(); if (r.width && r.height) this.fg.width(r.width).height(r.height); }
    _start() {}
    destroy() { try { this._ro.disconnect(); } catch (e) {} try { this.fg._destructor(); } catch (e) {} this.host.innerHTML = ''; }
  }
  window.CortexGraph = CortexGraph;
})();
