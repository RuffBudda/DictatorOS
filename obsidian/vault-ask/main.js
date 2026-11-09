// Ask the Vault (DictatorOS): a side chat that answers only from this vault,
// using local models through Ollama. Nothing leaves the machine.
//
// How it works: notes are split into chunks and embedded with an embedding
// model (cached in this plugin's data.json, refreshed when a note changes).
// Each question is embedded too; the closest chunks are given to the chat
// model, with the last few exchanges for follow-ups, and the answer streams
// into the side panel as it is written, citing the notes it used.
const { Plugin, ItemView, Notice, MarkdownRenderer, PluginSettingTab, Setting, FuzzySuggestModal, requestUrl } = require("obsidian");

const VIEW_TYPE = "dictatoros-vault-ask-chat";
const DEFAULTS = {
  ollamaUrl: "http://127.0.0.1:11434",
  chatModel: "qwen3:8b",
  embedModel: "nomic-embed-text",
  topK: 6,
  minScore: 0.35,
};
const CHUNK_CHARS = 1200;   // target chunk size
const EMBED_BATCH = 32;     // chunks per embedding request
const HISTORY_TURNS = 3;    // previous question/answer pairs sent for follow-ups
const NOT_FOUND = "I couldn't find that in your vault.";

// Split a note into ~CHUNK_CHARS pieces along paragraph boundaries.
function chunkText(text) {
  const body = text.replace(/^---\n[\s\S]*?\n---\n/, "");   // drop frontmatter
  const paras = body.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
  const chunks = [];
  let cur = "";
  for (const p of paras) {
    if (cur && cur.length + p.length + 2 > CHUNK_CHARS) { chunks.push(cur); cur = ""; }
    if (p.length > CHUNK_CHARS) {
      for (let i = 0; i < p.length; i += CHUNK_CHARS) chunks.push(p.slice(i, i + CHUNK_CHARS));
    } else {
      cur = cur ? cur + "\n\n" + p : p;
    }
  }
  if (cur) chunks.push(cur);
  return chunks;
}

function cosine(a, b) {
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
  return na && nb ? dot / Math.sqrt(na * nb) : 0;
}

class VaultAsk {
  constructor(plugin) { this.plugin = plugin; }
  get s() { return this.plugin.settings; }
  get base() { return this.s.ollamaUrl.replace(/\/$/, ""); }

  async post(path, body) {
    let res;
    try {
      res = await requestUrl({ url: this.base + path, method: "POST", contentType: "application/json", body: JSON.stringify(body), throw: false });
    } catch (e) {
      throw new Error("Can't reach Ollama at " + this.s.ollamaUrl + " (is it running? systemctl status ollama)");
    }
    if (res.status !== 200) throw new Error("Ollama " + path + " returned " + res.status + ": " + (res.text || "").slice(0, 200));
    return res.json;
  }

  async embed(texts) {
    const out = [];
    for (let i = 0; i < texts.length; i += EMBED_BATCH) {
      const r = await this.post("/api/embed", { model: this.s.embedModel, input: texts.slice(i, i + EMBED_BATCH) });
      out.push(...r.embeddings);
    }
    return out;
  }

  // Bring the cached index up to date with the vault (only changed notes are re-embedded).
  async refreshIndex(onProgress) {
    const app = this.plugin.app;
    const index = this.plugin.index;               // { [path]: { mtime, model, chunks: [{ text, vec }] } }
    const files = app.vault.getMarkdownFiles();
    const live = new Set(files.map((f) => f.path));
    for (const p of Object.keys(index)) if (!live.has(p)) delete index[p];
    const stale = files.filter((f) => !index[f.path] || index[f.path].mtime !== f.stat.mtime || index[f.path].model !== this.s.embedModel);
    let done = 0;
    for (const f of stale) {
      const text = await app.vault.cachedRead(f);
      const chunks = chunkText("# " + f.basename + "\n\n" + text);
      const vecs = chunks.length ? await this.embed(chunks.map((c) => "search_document: " + c)) : [];
      index[f.path] = { mtime: f.stat.mtime, model: this.s.embedModel, chunks: chunks.map((t, i) => ({ text: t, vec: vecs[i] })) };
      done++;
      if (onProgress) onProgress(done, stale.length);
    }
    if (stale.length) await this.plugin.saveIndex();
    return stale.length;
  }

  async search(question) {
    const [q] = await this.embed(["search_query: " + question]);
    const hits = [];
    for (const [path, entry] of Object.entries(this.plugin.index))
      for (const c of entry.chunks) hits.push({ path, text: c.text, score: cosine(q, c.vec) });
    hits.sort((a, b) => b.score - a.score);
    return hits.filter((h) => h.score >= this.s.minScore).slice(0, this.s.topK);
  }

  messages(question, hits, history) {
    const notes = hits.map((h) => `Note [[${h.path.replace(/\.md$/, "")}]]:\n${h.text}`).join("\n\n---\n\n");
    const system =
      "You answer questions using ONLY the notes provided from the user's Obsidian vault. " +
      "Do not use outside knowledge. If the notes do not contain the answer, reply exactly: " +
      `"${NOT_FOUND}" Be concise. When you use a note, cite it exactly as it is labelled, e.g. [[Folder/Note name]].`;
    const past = [];
    for (const t of history.slice(-HISTORY_TURNS)) past.push({ role: "user", content: t.question }, { role: "assistant", content: t.answer });
    return [
      { role: "system", content: system },
      ...past,
      { role: "user", content: `Notes:\n\n${notes}\n\nQuestion: ${question}` },
    ];
  }

  // Stream the answer: onToken(fullTextSoFar) is called as the model writes.
  async streamAnswer(question, hits, history, onToken, signal) {
    let res;
    try {
      res = await fetch(this.base + "/api/chat", {
        method: "POST", signal, headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ model: this.s.chatModel, stream: true, think: false, options: { temperature: 0.2 }, messages: this.messages(question, hits, history) }),
      });
    } catch (e) {
      if (e.name === "AbortError") throw e;
      throw new Error("Can't reach Ollama at " + this.s.ollamaUrl + " (is it running? systemctl status ollama)");
    }
    if (!res.ok) throw new Error("Ollama /api/chat returned " + res.status + ": " + (await res.text()).slice(0, 200));
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "", text = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
        if (!line) continue;
        const msg = JSON.parse(line);
        if (msg.error) throw new Error("Ollama: " + msg.error);
        if (msg.message && msg.message.content) { text += msg.message.content; onToken(text.replace(/<think>[\s\S]*?(<\/think>|$)/g, "")); }
      }
    }
    return text.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
  }
}

class ChatView extends ItemView {
  constructor(leaf, plugin) { super(leaf); this.plugin = plugin; this.ask = new VaultAsk(plugin); this.history = []; this.abort = null; }
  getViewType() { return VIEW_TYPE; }
  getDisplayText() { return "Ask the Vault"; }
  getIcon() { return "bot"; }

  async onOpen() {
    const root = this.contentEl;
    root.empty(); root.addClass("vault-ask-view");
    const head = root.createDiv({ cls: "vault-ask-head" });
    head.createSpan({ text: "Ask the Vault", cls: "vault-ask-title" });
    head.createSpan({ text: "local · only your notes", cls: "vault-ask-sub" });
    const newBtn = head.createEl("button", { text: "New chat", cls: "vault-ask-new" });
    newBtn.onclick = () => this.reset();

    this.log = root.createDiv({ cls: "vault-ask-log" });
    // Clicks on [[links]] in answers open the note.
    this.log.addEventListener("click", (e) => {
      const a = e.target.closest("a.internal-link, a.vault-ask-source");
      if (!a) return;
      e.preventDefault();
      this.app.workspace.openLinkText(a.getAttribute("data-href") || a.textContent, "", false);
    });

    const form = root.createDiv({ cls: "vault-ask-form" });
    this.input = form.createEl("textarea", { cls: "vault-ask-input", attr: { rows: "2", placeholder: "Ask about your notes…", title: "Enter to send · Shift+Enter for a new line" } });
    this.sendBtn = form.createEl("button", { text: "Send", cls: "mod-cta vault-ask-send" });
    this.sendBtn.onclick = () => (this.abort ? this.abort.abort() : this.send());
    this.input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); if (!this.abort) this.send(); } });
    this.reset();
  }

  reset() {
    if (this.abort) this.abort.abort();
    this.history = [];
    this.log.empty();
    this.log.createDiv({ cls: "vault-ask-hint", text: "Ask anything your notes can answer. Answers come only from this vault, run on this laptop, and link the notes they used." });
    if (this.input) this.input.focus();
  }

  setBusy(busy) {
    this.sendBtn.setText(busy ? "Stop" : "Send");
    this.sendBtn.toggleClass("vault-ask-stop", busy);
  }

  scroll() { this.log.scrollTop = this.log.scrollHeight; }

  async send() {
    const question = this.input.value.trim();
    if (!question) return;
    this.input.value = "";
    const hint = this.log.querySelector(".vault-ask-hint"); if (hint) hint.remove();
    this.log.createDiv({ cls: "vault-ask-msg vault-ask-user", text: question });
    const bubble = this.log.createDiv({ cls: "vault-ask-msg vault-ask-bot" });
    const status = bubble.createDiv({ cls: "vault-ask-status" });
    const body = bubble.createDiv({ cls: "vault-ask-body markdown-rendered" });
    this.scroll();
    this.abort = new AbortController();
    this.setBusy(true);
    let answer = "";
    try {
      status.setText("Indexing notes…");
      await this.ask.refreshIndex((d, n) => status.setText(`Indexing notes… ${d}/${n}`));
      status.setText("Searching your notes…");
      const hits = await this.ask.search(question);
      if (!hits.length) { status.remove(); body.setText(NOT_FOUND); this.history.push({ question, answer: NOT_FOUND }); return; }
      status.setText("Thinking (local model)…");
      let pending = null, latest = "";
      const render = async () => { pending = null; body.empty(); await MarkdownRenderer.render(this.app, latest, body, "", this); this.scroll(); };
      answer = await this.ask.streamAnswer(question, hits, this.history, (t) => {
        if (status.isConnected) status.remove();
        latest = t;
        if (!pending) pending = setTimeout(render, 60);   // re-render at most ~16x a second
      }, this.abort.signal);
      if (pending) clearTimeout(pending);
      latest = answer; await render();
      this.history.push({ question, answer });
      // The notes the answer was drawn from.
      const src = bubble.createDiv({ cls: "vault-ask-sources" });
      src.createSpan({ text: "Searched: ", cls: "vault-ask-sources-title" });
      for (const p of [...new Set(hits.map((h) => h.path))])
        src.createEl("a", { text: p.replace(/\.md$/, ""), cls: "vault-ask-source", href: "#", attr: { "data-href": p } });
    } catch (e) {
      if (status.isConnected) status.remove();
      if (e.name === "AbortError") { body.createDiv({ cls: "vault-ask-note", text: "(stopped)" }); if (answer) this.history.push({ question, answer }); }
      else body.setText("Error: " + e.message);
    } finally {
      this.abort = null;
      this.setBusy(false);
      this.scroll();
      this.input.focus();
    }
  }

  async onClose() { if (this.abort) this.abort.abort(); }
}

// "Link selection to…": pick a note, or an H2 heading inside a note, and turn
// the selected text into a link to it: [[Note#Heading|selected text]].
class LinkPicker extends FuzzySuggestModal {
  constructor(app, editor, sourcePath) {
    super(app); this.editor = editor; this.sourcePath = sourcePath;
    this.setPlaceholder("Link to a note, or to an H2 heading in a note…");
    this.setInstructions([{ command: "↑↓", purpose: "choose" }, { command: "↵", purpose: "link the selected text" }, { command: "esc", purpose: "cancel" }]);
  }
  getItems() {
    const items = [];
    for (const file of this.app.vault.getMarkdownFiles().sort((a, b) => a.path.localeCompare(b.path))) {
      items.push({ file, heading: null });
      const headings = (this.app.metadataCache.getFileCache(file) || {}).headings || [];
      for (const h of headings) if (h.level === 2) items.push({ file, heading: h.heading });
    }
    return items;
  }
  getItemText(item) {
    const note = item.file.path.replace(/\.md$/, "");
    return item.heading ? `${note} › ${item.heading}` : note;
  }
  renderSuggestion(match, el) {
    const item = match.item;
    el.addClass("vault-ask-link-item");
    if (item.heading) {
      el.createSpan({ text: "## ", cls: "vault-ask-link-h2" });
      el.createSpan({ text: item.heading });
      el.createSpan({ text: "  " + item.file.path.replace(/\.md$/, ""), cls: "vault-ask-link-path" });
    } else {
      el.createSpan({ text: item.file.path.replace(/\.md$/, "") });
    }
  }
  onChooseItem(item) {
    const selected = this.editor.getSelection();
    const sub = item.heading ? "#" + item.heading : "";
    const link = this.app.fileManager.generateMarkdownLink(item.file, this.sourcePath, sub, selected || undefined);
    this.editor.replaceSelection(link);
  }
}

class VaultAskSettings extends PluginSettingTab {
  constructor(app, plugin) { super(app, plugin); this.plugin = plugin; }
  display() {
    const { containerEl } = this; containerEl.empty();
    const s = this.plugin.settings;
    const text = (name, desc, key) => new Setting(containerEl).setName(name).setDesc(desc)
      .addText((t) => t.setValue(String(s[key])).onChange(async (v) => { s[key] = key === "topK" ? (parseInt(v, 10) || DEFAULTS.topK) : v.trim(); await this.plugin.saveSettings(); }));
    text("Ollama URL", "Where the local Ollama server listens.", "ollamaUrl");
    text("Chat model", "Ollama model that writes the answers.", "chatModel");
    text("Embedding model", "Ollama model used to search notes (changing it re-indexes the vault).", "embedModel");
    text("Notes per answer", "How many note chunks are given to the model.", "topK");
    new Setting(containerEl).setName("Rebuild index").setDesc("Re-embed every note from scratch.")
      .addButton((b) => b.setButtonText("Rebuild").onClick(async () => {
        this.plugin.index = {}; await this.plugin.saveIndex();
        new Notice("Ask the Vault: indexing…");
        const n = await new VaultAsk(this.plugin).refreshIndex();
        new Notice(`Ask the Vault: indexed ${n} notes.`);
      }));
  }
}

module.exports = class VaultAskPlugin extends Plugin {
  async onload() {
    const data = (await this.loadData()) || {};
    this.settings = Object.assign({}, DEFAULTS, data.settings || {});
    this.index = data.index || {};
    this.registerView(VIEW_TYPE, (leaf) => new ChatView(leaf, this));
    this.addRibbonIcon("bot", "Ask the Vault (local AI side chat)", () => this.openChat());
    this.addCommand({ id: "open-chat", name: "Open side chat", callback: () => this.openChat() });
    // A distinct red button in the status bar.
    const bar = this.addStatusBarItem();
    bar.addClass("vault-ask-statusbar", "mod-clickable");
    bar.setAttribute("aria-label", "Ask the Vault (local AI side chat)");
    bar.createSpan({ text: "Ask vault" });
    bar.onClickEvent(() => this.openChat());
    this.addSettingTab(new VaultAskSettings(this.app, this));

    // Link the selected text to a note or to an H2 heading in a note.
    const pick = (editor, view) => new LinkPicker(this.app, editor, view.file ? view.file.path : "").open();
    this.addCommand({ id: "link-selection", name: "Link selection to note or heading…", icon: "link",
      hotkeys: [{ modifiers: ["Mod", "Shift"], key: "l" }], editorCallback: pick });
    this.registerEvent(this.app.workspace.on("editor-menu", (menu, editor, view) => {
      menu.addItem((item) => item.setTitle(editor.getSelection() ? "Link selection to…" : "Insert link to note or heading…")
        .setIcon("link").onClick(() => pick(editor, view)));
    }));
  }

  async openChat() {
    let leaf = this.app.workspace.getLeavesOfType(VIEW_TYPE)[0];
    if (!leaf) {
      leaf = this.app.workspace.getRightLeaf(false);
      await leaf.setViewState({ type: VIEW_TYPE, active: true });
    }
    this.app.workspace.revealLeaf(leaf);
    const view = leaf.view;
    if (view && view.input) setTimeout(() => view.input.focus(), 50);
  }

  async saveSettings() { await this.saveData({ settings: this.settings, index: this.index }); }
  async saveIndex() { await this.saveData({ settings: this.settings, index: this.index }); }
};

// Exposed for tests (not used by Obsidian).
module.exports.VaultAsk = VaultAsk;
module.exports.chunkText = chunkText;
module.exports.LinkPicker = LinkPicker;
