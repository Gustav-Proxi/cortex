// Bundled (esbuild) into ../cm6.js — exposes window.createCortexEditor.
// Markdown editor for Cortex: monochrome syntax styling, Obsidian-style live
// preview (markup hidden except on the line you're editing), clickable
// [[wikilinks]] (⌘/Ctrl-click), image paste, line wrap, undo/redo, read-only.
import { EditorState, Compartment, RangeSetBuilder } from "@codemirror/state";
import { EditorView, keymap, drawSelection, highlightActiveLine,
         Decoration, ViewPlugin, MatchDecorator } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxHighlighting, HighlightStyle, indentOnInput, bracketMatching, syntaxTree } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";

const highlight = HighlightStyle.define([
  { tag: t.heading1, fontSize: "1.55em", fontWeight: "700", color: "#ffffff", lineHeight: "1.5" },
  { tag: t.heading2, fontSize: "1.32em", fontWeight: "700", color: "#ffffff" },
  { tag: t.heading3, fontSize: "1.16em", fontWeight: "600", color: "#f1f2f4" },
  { tag: [t.heading4, t.heading5, t.heading6], fontWeight: "600", color: "#e7e8eb" },
  { tag: t.strong, fontWeight: "700", color: "#ffffff" },
  { tag: t.emphasis, fontStyle: "italic", color: "#e2e5ea" },
  { tag: t.strikethrough, textDecoration: "line-through", color: "#888e98" },
  { tag: [t.link, t.url], color: "#9ecbff" },
  { tag: t.monospace, color: "#ffd9a0", fontFamily: '"Spline Sans Mono", monospace' },
  { tag: t.quote, color: "#9aa0a9", fontStyle: "italic" },
  { tag: [t.list, t.contentSeparator], color: "#aeb4bd" },
  { tag: [t.processingInstruction, t.meta, t.labelName, t.punctuation], color: "#5f6671" },
  { tag: t.comment, color: "#5f6671", fontStyle: "italic" },
]);

const theme = EditorView.theme({
  "&": { color: "#f3f4f6", backgroundColor: "transparent", height: "100%", fontSize: "14px" },
  ".cm-scroller": { fontFamily: '"Spline Sans Mono", ui-monospace, monospace', lineHeight: "1.75", overflow: "auto" },
  ".cm-content": { padding: "26px 34px 60vh", caretColor: "#fff", maxWidth: "880px" },
  "&.cm-focused": { outline: "none" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "#ffffff", borderLeftWidth: "2px" },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground": { backgroundColor: "rgba(255,255,255,0.14)" },
  ".cm-activeLine": { backgroundColor: "rgba(255,255,255,0.022)" },
  ".cm-wikilink": { color: "#9ecbff", textDecoration: "underline",
                    textDecorationColor: "rgba(158,203,255,0.35)", textUnderlineOffset: "2px", cursor: "pointer" },
}, { dark: true });

// --- live preview: hide markdown markup, except on the line being edited -----
const HIDE = Decoration.replace({});
const MARK_TYPES = new Set([
  "HeaderMark", "EmphasisMark", "StrongEmphasisMark", "CodeMark",
  "QuoteMark", "StrikethroughMark", "LinkMark",
]);
function activeLines(state) {
  const set = new Set();
  for (const r of state.selection.ranges) {
    const a = state.doc.lineAt(r.from).number, b = state.doc.lineAt(r.to).number;
    for (let n = a; n <= b; n++) set.add(n);
  }
  return set;
}
const livePreview = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = this.build(view); }
  update(u) { if (u.docChanged || u.selectionSet || u.viewportChanged) this.decorations = this.build(u.view); }
  build(view) {
    const act = activeLines(view.state), ranges = [];
    for (const { from, to } of view.visibleRanges) {
      syntaxTree(view.state).iterate({ from, to, enter: (n) => {
        if (MARK_TYPES.has(n.name) && n.to > n.from) {
          if (!act.has(view.state.doc.lineAt(n.from).number)) ranges.push([n.from, n.to]);
        }
      }});
    }
    ranges.sort((a, b) => a[0] - b[0]);
    const b = new RangeSetBuilder();
    for (const [f, to] of ranges) b.add(f, to, HIDE);
    return b.finish();
  }
}, { decorations: (v) => v.decorations });

// --- wikilinks: style + clickable ------------------------------------------
const WIKI = /\[\[([^\]\n|#]+)(?:[#|][^\]\n]*)?\]\]/g;
const wikiMatcher = new MatchDecorator({ regexp: WIKI, decoration: () => Decoration.mark({ class: "cm-wikilink" }) });
const wikilinks = ViewPlugin.define(
  (view) => ({
    decorations: wikiMatcher.createDeco(view),
    update(u) { this.decorations = wikiMatcher.updateDeco(u, this.decorations); },
  }),
  { decorations: (v) => v.decorations }
);

window.createCortexEditor = function (parent, opts) {
  opts = opts || {};
  const onChange = opts.onChange || function () {};
  const onOpenLink = opts.onOpenLink || function () {};
  const onImagePaste = opts.onImagePaste || null;
  const ro = new Compartment();
  let silent = false;

  const view = new EditorView({
    parent: parent,
    state: EditorState.create({
      doc: opts.doc || "",
      extensions: [
        history(), drawSelection(), highlightActiveLine(), indentOnInput(), bracketMatching(),
        markdown({ base: markdownLanguage }),
        syntaxHighlighting(highlight),
        livePreview, wikilinks,
        EditorView.lineWrapping,
        ro.of(EditorState.readOnly.of(false)),
        theme,
        keymap.of([indentWithTab, ...historyKeymap, ...defaultKeymap]),
        EditorView.updateListener.of((u) => { if (u.docChanged && !silent) onChange(view.state.doc.toString()); }),
        EditorView.domEventHandlers({
          mousedown(e) {
            const el = e.target;
            if (el && el.classList && el.classList.contains("cm-wikilink") && (e.metaKey || e.ctrlKey)) {
              const m = (el.textContent || "").match(/\[\[([^\]\n|#]+)/);
              if (m) { e.preventDefault(); onOpenLink(m[1].trim()); return true; }
            }
          },
          paste(e) {
            if (!onImagePaste) return false;
            const items = (e.clipboardData && e.clipboardData.items) || [];
            for (const it of items) {
              if (it.type && it.type.indexOf("image/") === 0) {
                const file = it.getAsFile();
                if (file) {
                  e.preventDefault();
                  onImagePaste(file, (snippet) => view.dispatch(view.state.replaceSelection(snippet)));
                  return true;
                }
              }
            }
            return false;
          },
        }),
      ],
    }),
  });

  return {
    getValue: () => view.state.doc.toString(),
    setValue: (text) => {
      silent = true;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text || "" } });
      silent = false;
    },
    setReadOnly: (flag) => view.dispatch({ effects: ro.reconfigure(EditorState.readOnly.of(!!flag)) }),
    focus: () => view.focus(),
  };
};
