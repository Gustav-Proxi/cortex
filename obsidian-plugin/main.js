'use strict';

/*
 * Cortex — in-house semantic brain, inside Obsidian.
 *
 * This plugin is only the FACE. The engine (embeddings, sqlite-vec index, file
 * access) runs OUTSIDE Obsidian at ~/cortex and is reached over a loopback JSON
 * API (default http://127.0.0.1:8788), served by the cortex watcher. The arrow
 * points plugin -> engine; Obsidian never has to be the source of truth.
 *
 * Features:
 *   - Semantic search pane (embeddings query lookup)
 *   - Auto "Connections": embedding-nearest notes for the note you're viewing
 *     (Smart-Connections style), refreshing as you navigate
 *   - Look up selection (semantic search on highlighted text)
 *   - Capture: create a note straight into the vault via the engine (write)
 *
 * Hand-written CommonJS (no build step) — Obsidian provides `obsidian` at runtime.
 */

const { Plugin, ItemView, PluginSettingTab, Setting, Modal, Menu, Notice, setIcon, requestUrl } = require('obsidian');

const VIEW_TYPE_CORTEX = 'cortex-search';
const DEFAULT_SETTINGS = { serverUrl: 'http://127.0.0.1:8788', k: 8, autoConnections: true };

const sleep = (ms) => new Promise((r) => window.setTimeout(r, ms));

class CortexView extends ItemView {
  constructor(leaf, plugin) {
    super(leaf);
    this.plugin = plugin;
  }

  getViewType() { return VIEW_TYPE_CORTEX; }
  getDisplayText() { return 'Cortex'; }
  getIcon() { return 'brain-circuit'; }

  async onOpen() {
    const root = this.contentEl;
    root.empty();
    root.addClass('cortex-pane');

    const header = root.createDiv({ cls: 'cortex-header' });
    header.createDiv({ cls: 'cortex-title', text: 'Cortex' });
    this.statusEl = header.createDiv({ cls: 'cortex-status', text: '…' });

    const box = root.createDiv({ cls: 'cortex-searchbox' });
    this.input = box.createEl('input', { type: 'text', cls: 'cortex-input' });
    this.input.placeholder = 'Search…';
    const iconBtn = (icon, label, fn) => {
      const b = box.createEl('button', { cls: 'cortex-iconbtn' });
      setIcon(b, icon);
      b.setAttribute('aria-label', label);
      b.onclick = fn;
    };
    iconBtn('search', 'Search', () => this.search(this.input.value));
    iconBtn('git-fork', 'Knowledge graph', (e) => this.graphMenu(e));
    iconBtn('plus', 'Capture a note', () => new CaptureModal(this.app, this.plugin).open());

    this.results = root.createDiv({ cls: 'cortex-results' });

    this.input.addEventListener('keydown', (e) => { if (e.key === 'Enter') this.search(this.input.value); });

    this.checkHealth();
    window.setTimeout(() => this.input && this.input.focus(), 60);

    // Auto-show connections for the active note.
    const active = this.app.workspace.getActiveFile();
    if (this.plugin.settings.autoConnections && active) {
      this.showConnections(active.path);
    } else {
      this.results.createDiv({ cls: 'cortex-empty', text: 'Open a note for connections, or search above.' });
    }
  }

  _api(path) { return this.plugin.settings.serverUrl.replace(/\/$/, '') + path; }

  async checkHealth() {
    if (!this.statusEl) return;
    try {
      const r = await requestUrl({ url: this._api('/health') });
      const j = r.json;
      this.statusEl.setText(`${j.notes} notes · ${j.chunks} chunks`);
      this.statusEl.removeClass('cortex-bad');
      this.statusEl.addClass('cortex-ok');
    } catch (e) {
      this.statusEl.setText('engine offline');
      this.statusEl.removeClass('cortex-ok');
      this.statusEl.addClass('cortex-bad');
    }
  }

  async search(query) {
    query = (query || '').trim();
    if (!query || !this.results) return;
    this.results.empty();
    this.results.createDiv({ cls: 'cortex-loading', text: 'Searching…' });
    try {
      const r = await requestUrl({
        url: this._api('/search'),
        method: 'POST',
        contentType: 'application/json',
        body: JSON.stringify({ query, k: this.plugin.settings.k }),
      });
      this.results.empty();
      this.results.createDiv({ cls: 'cortex-label', text: 'Search · ' + query });
      this.render(r.json, true);
    } catch (e) {
      this._offline(e);
    }
    this.checkHealth();
  }

  async related(path, label) {
    if (!this.results) return;
    this.results.empty();
    this.results.createDiv({ cls: 'cortex-loading', text: 'Finding connections…' });
    try {
      const r = await requestUrl({
        url: this._api('/related'),
        method: 'POST',
        contentType: 'application/json',
        body: JSON.stringify({ path, k: this.plugin.settings.k }),
      });
      this.results.empty();
      this.results.createDiv({ cls: 'cortex-label', text: label || ('Related · ' + path.split('/').pop()) });
      this.render(r.json, true);
    } catch (e) {
      this._offline(e);
    }
  }

  // The signature "embeddings lookup": nearest notes to the active one by vector
  // similarity — Obsidian's in-app equivalent of Smart Connections.
  showConnections(path) {
    return this.related(path, 'Connections · ' + path.split('/').pop().replace(/\.md$/, ''));
  }

  // The knowledge-graph submenu: vault-wide graph, the active note's local
  // graph, or Cortex's semantic (embedding) connections for the active note.
  graphMenu(evt) {
    const menu = new Menu();
    menu.addItem((i) => i.setTitle('Knowledge graph — whole vault').setIcon('share-2')
      .onClick(() => {
        if (!this.app.commands.executeCommandById('graph:open')) {
          new Notice('Enable the core “Graph view” plugin');
        }
      }));
    menu.addItem((i) => i.setTitle('Local graph — active note').setIcon('git-fork')
      .onClick(() => {
        if (!this.app.commands.executeCommandById('graph:open-local')) {
          new Notice('Open a note first (needs the core Graph plugin)');
        }
      }));
    menu.addSeparator();
    menu.addItem((i) => i.setTitle('Semantic connections — active note').setIcon('search')
      .onClick(() => {
        const f = this.app.workspace.getActiveFile();
        if (f) this.showConnections(f.path);
        else new Notice('No active note');
      }));
    menu.showAtMouseEvent(evt);
  }

  _offline(e) {
    if (!this.results) return;
    this.results.empty();
    this.results.createDiv({
      cls: 'cortex-error',
      text: 'Cortex engine offline. Is the watcher running? (' + (e && e.message ? e.message : e) + ')',
    });
    this.checkHealth();
  }

  render(hits, append) {
    if (!this.results) return;
    if (!append) this.results.empty();
    if (!hits || !hits.length) {
      this.results.createDiv({ cls: 'cortex-empty', text: 'No matches.' });
      return;
    }
    for (const h of hits) {
      const card = this.results.createDiv({ cls: 'cortex-hit' });
      const name = (h.path.split('/').pop() || h.path).replace(/\.md$/, '');
      card.createDiv({ cls: 'cortex-hit-title', text: name });
      card.createDiv({ cls: 'cortex-hit-ctx', text: h.heading || h.path.replace(/\.md$/, '') });
      const snip = (h.text || '').replace(/\s+/g, ' ').trim().slice(0, 180);
      card.createDiv({ cls: 'cortex-hit-snippet', text: snip });
      card.onclick = () => {
        const file = this.app.vault.getAbstractFileByPath(h.path);
        if (file) this.app.workspace.getLeaf(false).openFile(file);
        else new Notice('Note not found: ' + h.path);
      };
    }
  }

  async onClose() {}
}

class CaptureModal extends Modal {
  constructor(app, plugin) {
    super(app);
    this.plugin = plugin;
  }

  onOpen() {
    const { contentEl } = this;
    contentEl.empty();
    contentEl.addClass('cortex-capture');
    contentEl.createEl('h3', { text: 'Cortex · capture note' });

    const pathInput = contentEl.createEl('input', { type: 'text', cls: 'cortex-cap-path' });
    pathInput.placeholder = 'folder/Note name.md';

    const body = contentEl.createEl('textarea', { cls: 'cortex-cap-body' });
    body.placeholder = 'Markdown content…';

    const row = contentEl.createDiv({ cls: 'cortex-cap-row' });
    const save = row.createEl('button', { cls: 'mod-cta', text: 'Save & open' });
    const cancel = row.createEl('button', { text: 'Cancel' });
    cancel.onclick = () => this.close();

    save.onclick = async () => {
      let path = (pathInput.value || '').trim();
      if (!path) { new Notice('Give it a path'); return; }
      if (!path.endsWith('.md')) path += '.md';
      try {
        const r = await requestUrl({
          url: this.plugin.settings.serverUrl.replace(/\/$/, '') + '/write',
          method: 'POST',
          contentType: 'application/json',
          body: JSON.stringify({ path, content: body.value || '' }),
        });
        if (r.json && r.json.error) { new Notice('Cortex: ' + r.json.error); return; }
        new Notice('Saved ' + path);
        this.close();
        // The file exists on disk now; Obsidian may take a tick to register it.
        let file = null, tries = 0;
        while (!file && tries++ < 20) {
          file = this.app.vault.getAbstractFileByPath(path);
          if (!file) await sleep(50);
        }
        if (file) this.app.workspace.getLeaf(false).openFile(file);
      } catch (e) {
        new Notice('Cortex write failed: ' + (e && e.message ? e.message : e));
      }
    };

    window.setTimeout(() => pathInput.focus(), 40);
  }

  onClose() { this.contentEl.empty(); }
}

module.exports = class CortexPlugin extends Plugin {
  async onload() {
    await this.loadSettings();

    this.registerView(VIEW_TYPE_CORTEX, (leaf) => new CortexView(leaf, this));

    this.addRibbonIcon('brain-circuit', 'Cortex', () => this.activateView());

    this.addCommand({ id: 'open-search', name: 'Open search', callback: () => this.activateView() });

    this.addCommand({
      id: 'connections-active',
      name: 'Connections for current note',
      callback: async () => {
        const file = this.app.workspace.getActiveFile();
        if (!file) { new Notice('No active note'); return; }
        const view = await this._viewReady();
        if (view) view.showConnections(file.path);
      },
    });

    this.addCommand({
      id: 'lookup-selection',
      name: 'Look up selection (semantic)',
      editorCallback: async (editor) => {
        const sel = (editor.getSelection() || '').trim();
        if (!sel) { new Notice('Select some text first'); return; }
        const view = await this._viewReady();
        if (view && view.input) { view.input.value = sel.slice(0, 200); view.search(sel); }
      },
    });

    this.addCommand({
      id: 'capture-note',
      name: 'Capture a note',
      callback: () => new CaptureModal(this.app, this).open(),
    });

    this.addSettingTab(new CortexSettingTab(this.app, this));

    // Embeddings lookup: auto-refresh connections as you move between notes.
    this.registerEvent(this.app.workspace.on('file-open', (file) => {
      if (!file || !this.settings.autoConnections) return;
      const leaf = this.app.workspace.getLeavesOfType(VIEW_TYPE_CORTEX)[0];
      if (!leaf || !leaf.view || !leaf.view.showConnections) return;
      const view = leaf.view;
      if (view.input && view.input.value.trim()) return; // don't clobber an active search
      window.clearTimeout(this._autoTimer);
      this._autoTimer = window.setTimeout(() => view.showConnections(file.path), 250);
    }));

    // Friendly boot ping (non-blocking).
    requestUrl({ url: this.settings.serverUrl.replace(/\/$/, '') + '/health' })
      .then((r) => new Notice(`Cortex ready · ${r.json.notes} notes indexed`))
      .catch(() => new Notice('Cortex engine offline — start the cortex watcher.'));
  }

  onunload() {}

  async loadSettings() {
    this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
  }

  async saveSettings() {
    await this.saveData(this.settings);
  }

  async activateView() {
    const { workspace } = this.app;
    let leaf = workspace.getLeavesOfType(VIEW_TYPE_CORTEX)[0];
    if (!leaf) {
      leaf = workspace.getRightLeaf(false) || workspace.getLeaf(true);
      await leaf.setViewState({ type: VIEW_TYPE_CORTEX, active: true });
    }
    workspace.revealLeaf(leaf);
    return leaf.view;
  }

  // Activate the view and wait until its DOM is built.
  async _viewReady() {
    const view = await this.activateView();
    let tries = 0;
    while (view && !view.results && tries++ < 40) await sleep(25);
    return view;
  }
};

class CortexSettingTab extends PluginSettingTab {
  constructor(app, plugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display() {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl('h2', { text: 'Cortex' });
    containerEl.createEl('p', {
      text: 'In-house semantic brain. The engine runs OUTSIDE Obsidian (the cortex watcher serves it on loopback), so this works even when the rest of the vault is idle — and nothing leaves your Mac.',
    });

    new Setting(containerEl)
      .setName('Engine URL')
      .setDesc('Cortex local HTTP API (served by the watcher).')
      .addText((t) =>
        t.setValue(this.plugin.settings.serverUrl).onChange(async (v) => {
          this.plugin.settings.serverUrl = v.trim();
          await this.plugin.saveSettings();
        }),
      );

    new Setting(containerEl)
      .setName('Results (k)')
      .setDesc('How many hits to return per lookup.')
      .addText((t) =>
        t.setValue(String(this.plugin.settings.k)).onChange(async (v) => {
          const n = parseInt(v, 10);
          if (!isNaN(n) && n > 0) {
            this.plugin.settings.k = n;
            await this.plugin.saveSettings();
          }
        }),
      );

    new Setting(containerEl)
      .setName('Auto-connections')
      .setDesc('Automatically show embedding-nearest notes for the note you’re viewing (Smart-Connections style).')
      .addToggle((t) =>
        t.setValue(this.plugin.settings.autoConnections).onChange(async (v) => {
          this.plugin.settings.autoConnections = v;
          await this.plugin.saveSettings();
        }),
      );

    new Setting(containerEl)
      .setName('Test connection')
      .setDesc('Ping the engine and report index size.')
      .addButton((b) =>
        b.setButtonText('Ping').onClick(async () => {
          try {
            const r = await requestUrl({ url: this.plugin.settings.serverUrl.replace(/\/$/, '') + '/health' });
            new Notice(`Cortex OK · ${r.json.notes} notes / ${r.json.chunks} chunks`);
          } catch (e) {
            new Notice('Cortex offline — is the watcher running?');
          }
        }),
      );
  }
}
