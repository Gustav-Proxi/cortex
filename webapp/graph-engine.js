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
        .nodeVal((n) => this._val(n))
        .nodeColor((n) => this._nodeColor(n))
        .nodeVisibility((n) => this._nodeVisible(n))   // hover isolates: unconnected neurons vanish
        .nodeOpacity(0.9)
        .nodeLabel(() => '')                 // hover card + HTML overlay labels handle text
        .linkColor((l) => this._linkColor(l))
        .linkVisibility((l) => this._linkVisible(l))   // only the hovered neuron's synapses remain
        .linkWidth((l) => (this._hot(l) ? 1.0 : 0.35))             // faint always-on synapse web; hot links thicken
        .linkOpacity(0.6)
        // Two firing modes share these pulse visuals:
        //  · hover  → a SMOOTH continuous stream along the hovered neuron's synapses (persistent particles)
        //  · ambient→ sparse one-shot emitParticle spikes elsewhere (a living brain at rest)
        .linkDirectionalParticles((l) => (this._hot(l) ? 3 : 0))   // evenly-spaced, looping → reads as smooth flow, not a stutter
        .linkDirectionalParticleSpeed(0.006)
        .linkDirectionalParticleWidth(2.4)
        .linkDirectionalParticleColor(() => 'rgba(190,226,255,0.95)')   // electric near-white synaptic pulse
        .enableNodeDrag(!opts.mini)
        .onNodeHover((n) => {
          this._setHover(n ? n.id : null);   // _refresh() turns on the hovered synapses' smooth particle stream
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

      // HTML overlay labels (reliable text without three-instance issues).
      if (getComputedStyle(host).position === 'static') host.style.position = 'relative';
      this.labelLayer = document.createElement('div');
      Object.assign(this.labelLayer.style, { position: 'absolute', inset: '0', overflow: 'hidden', pointerEvents: 'none', zIndex: '4' });
      host.appendChild(this.labelLayer);
      this.labelEls = new Map();
      this._startLabelLoop();

      this._ro = new ResizeObserver(() => this.resize());
      this._ro.observe(host);
      this.resize();

      if (!opts.mini) { this._ambientFire(); window.__cortexGraph = this; }   // passive firing + debug handle (main graph only)

      // Power management — a WebGL + rAF graph left open in a hidden/off-screen tab
      // pins a CPU core + the GPU and thrashes the machine into swap (this cooked the
      // Mac once). Suspend ALL animation — the render loop, the label rAF, and ambient
      // firing — whenever the page is hidden or this host is off-screen; resume on return.
      this._active = true;
      this._onVis = () => this._setActive(document.visibilityState === 'visible' && this.host.offsetParent !== null);
      document.addEventListener('visibilitychange', this._onVis);
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
      const inHover = this.hoverId && (n.id === this.hoverId || this.hoverSet.has(n.id));
      if (this.muted.has(n.domain) && !inHover) return 'rgba(120,126,135,0.18)';  // muting yields to an active hover
      if (this.hoverId && !inHover) return DIM_NODE;
      return n.color || '#9aa0a9';
    }
    _hot(l) { const s = byId(l, 'source'), t = byId(l, 'target'); return this.hoverId && (s === this.hoverId || t === this.hoverId); }
    // On hover, isolate the hovered neuron: only it and its direct connections stay visible.
    _nodeVisible(n) { return !this.hoverId || n.id === this.hoverId || this.hoverSet.has(n.id); }
    _linkVisible(l) { return !this.hoverId || this._hot(l); }
    _linkColor(l) {
      if (this._hot(l)) return 'rgba(198,228,255,0.9)';   // hovered synapses glow electric-white
      if (this.hoverId) return 'rgba(255,255,255,0.03)';  // everything else recedes
      return `rgba(255,255,255,${l.kind === 'sem' ? 0.05 : 0.14})`;
    }
    _nodeById(id) { return (this.nodes || []).find((n) => n.id === id); }
    _setHover(id) { this.hoverId = id; this.hoverSet = (id && this.adj[id]) || new Set(); this._refresh(); }
    // Force 3d-force-graph to re-run the style accessors. Without this, changing
    // hoverId does nothing visible — colors/widths are cached until reassigned.
    _refresh() {
      if (!this.fg) return;
      try {
        this.fg.nodeColor(this.fg.nodeColor());
        this.fg.nodeVisibility(this.fg.nodeVisibility());
        this.fg.linkColor(this.fg.linkColor());
        this.fg.linkVisibility(this.fg.linkVisibility());
        this.fg.linkWidth(this.fg.linkWidth());
        this.fg.linkDirectionalParticles(this.fg.linkDirectionalParticles());   // toggle the hovered synapses' stream
      } catch (e) {}
    }
    _val(n) { return 0.6 + Math.min(n.deg || 0, 22) * 0.32; }
    _radius(n) { return 4 * Math.cbrt(this._val(n)); }   // matches nodeRelSize(4)

    // ---- neuron firing -------------------------------------------------
    // Emit one-shot pulses along every synapse of a neuron. emitParticle travels
    // source→target, so the pulse direction reads as the link's direction.
    fire(id) {
      if (!this.fg) return;
      const links = this.fg.graphData().links || [];
      for (const l of links) {
        if (byId(l, 'source') === id || byId(l, 'target') === id) {
          try { this.fg.emitParticle(l); } catch (e) {}
        }
      }
    }
    // Passive activity: a couple of random neurons spike now and then so the graph
    // ripples with motion the moment the view opens. Pauses while a node is hovered
    // (hover firing takes over) and while the view is hidden.
    _ambientFire() {
      const tick = () => {
        if (!this.fg) return;
        const live = !this.opts.mini && this.host.offsetParent !== null && this.nodes.length && !this.hoverId;
        if (live) {
          const ns = this.nodes, k = ns.length > 40 ? 2 : 1;
          for (let i = 0; i < k; i++) this.fire(ns[(Math.random() * ns.length) | 0].id);
        }
        this._fireTimer = setTimeout(tick, 360 + Math.random() * 640);
      };
      this._fireTimer = setTimeout(tick, 450);
    }
    _buildLabels() {
      if (!this.labelLayer) return;
      this.labelLayer.innerHTML = ''; this.labelEls.clear();
      if (this.opts.mini) return;
      for (const n of this.nodes) {
        const el = document.createElement('div');
        el.textContent = n.label || n.id;
        Object.assign(el.style, {
          position: 'absolute', top: '0', left: '0', whiteSpace: 'nowrap', opacity: '0',
          font: '500 11px "Spline Sans Mono", ui-monospace, monospace',
          color: 'rgba(226,229,235,0.95)', textShadow: '0 1px 3px rgba(0,0,0,0.95), 0 0 2px #000',
          pointerEvents: 'none', willChange: 'transform, opacity',
        });
        this.labelLayer.appendChild(el);
        this.labelEls.set(n.id, el);
      }
    }
    _positionLabels() {
      if (!this.fg || this.opts.mini || !this.labelEls || !this.labelEls.size) return;
      if (this.host.offsetParent === null) return;          // graph view hidden → skip
      const cam = this.fg.camera(); if (!cam) return;
      const cp = cam.position;
      if (!this._fwd) this._fwd = new (cp.constructor)();
      cam.getWorldDirection(this._fwd);
      const fx = this._fwd.x, fy = this._fwd.y, fz = this._fwd.z;
      for (const n of this.nodes) {
        const el = this.labelEls.get(n.id); if (!el) continue;
        if (n.x == null) { el.style.opacity = '0'; continue; }
        const vx = n.x - cp.x, vy = n.y - cp.y, vz = (n.z || 0) - cp.z;
        if (vx * fx + vy * fy + vz * fz <= 0) { el.style.opacity = '0'; continue; }   // behind camera
        const sc = this.fg.graph2ScreenCoords(n.x, n.y, n.z || 0);
        let op = Math.max(0.16, Math.min(0.95, 320 / Math.hypot(vx, vy, vz)));
        if (this.hoverId) op = (n.id === this.hoverId || this.hoverSet.has(n.id)) ? 1 : 0;   // isolate on hover
        el.style.opacity = String(op);
        el.style.transform = `translate(${sc.x}px, ${sc.y + 9}px) translateX(-50%)`;
      }
    }

    setData(nodes, links) {
      this.nodes = nodes || [];
      this.adj = {};
      (links || []).forEach((e) => {
        (this.adj[e.source] = this.adj[e.source] || new Set()).add(e.target);
        (this.adj[e.target] = this.adj[e.target] || new Set()).add(e.source);
      });
      this.links = (links || []).map((e) => ({ source: e.source, target: e.target, kind: e.kind, score: e.score }));
      this.fg.graphData({ nodes: this.nodes, links: this.links });
      this._buildLabels();
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
    _startLabelLoop() {
      if (this._labelRAF) return;
      const step = () => { this._labelRAF = requestAnimationFrame(step); this._positionLabels(); };
      this._labelRAF = requestAnimationFrame(step);
    }
    // Suspend/resume every animation source. Pausing the 3d-force-graph render loop is
    // the big win (stops continuous GPU work); the label rAF + ambient-fire timer are
    // torn down too, so a backgrounded graph costs ~0 CPU until it's visible again.
    _setActive(active) {
      active = !!active;
      if (active === this._active || !this.fg) return;
      this._active = active;
      if (active) {
        try { this.fg.resumeAnimation(); } catch (e) {}
        this._startLabelLoop();
        if (!this.opts.mini && !this._fireTimer) this._ambientFire();
      } else {
        try { this.fg.pauseAnimation(); } catch (e) {}
        cancelAnimationFrame(this._labelRAF); this._labelRAF = null;
        clearTimeout(this._fireTimer); this._fireTimer = null;
      }
    }
    reheat() { this.fg.d3ReheatSimulation(); this.fit(90, 800); }
    fit(pad = 80, dur = 600) { try { this.fg.zoomToFit(dur, pad); } catch (e) {} }
    resize() { const r = this.host.getBoundingClientRect(); if (r.width && r.height) this.fg.width(r.width).height(r.height); }
    _start() {}
    destroy() {
      document.removeEventListener('visibilitychange', this._onVis);
      cancelAnimationFrame(this._labelRAF); clearTimeout(this._fireTimer);
      const fg = this.fg; this.fg = null;                       // null first → any guarded callback bails out
      try { this._ro.disconnect(); } catch (e) {}
      try { fg && fg._destructor(); } catch (e) {}
      if (window.__cortexGraph === this) window.__cortexGraph = null;
      this.host.innerHTML = '';
    }
  }
  window.CortexGraph = CortexGraph;
})();
