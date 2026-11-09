// Ask the Vault (DictatorOS): a side chat that answers only from this vault,
// using local models through Ollama. Nothing leaves the machine.
//
// - Ask: each question is matched against the vault (embeddings cached in
//   data.json, refreshed when a note changes); the closest chunks go to the
//   chat model, which answers only from them, streaming, citing the notes.
// - Expand: select text -> the model first asks clarifying questions, then
//   writes the expanded passage (using related notes for consistency), with
//   buttons to replace the selection or insert below it.
// - Chats are saved (data.json) and listed under History.
// - Link picker: link the selected text to a note or an H2 heading in a note.
const { Plugin, ItemView, Notice, MarkdownRenderer, PluginSettingTab, Setting, FuzzySuggestModal, TFile, requestUrl, setIcon } = require("obsidian");

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
const HISTORY_TURNS = 6;    // previous messages sent along for follow-ups (ask mode)
const MAX_CHATS = 100;      // saved chats kept in History
const NOT_FOUND = "I couldn't find that in your vault.";

const ASK_SYSTEM =
  "You answer questions using ONLY the notes provided from the user's Obsidian vault. " +
  "Do not use outside knowledge. If the notes do not contain the answer, reply exactly: " +
  `"${NOT_FOUND}" Be concise. When you use a note, cite it exactly as it is labelled, e.g. [[Folder/Note name]].`;

const EXPAND_SYSTEM =
  "You help the user expand a passage from their Obsidian notes. Related notes from their vault are " +
  "provided for context; stay consistent with them and don't invent facts that contradict them.\n" +
  "Step 1 (your first reply): do NOT write the expansion yet. Ask 2 to 4 short, numbered questions to " +
  "understand what they need, for example purpose, audience, length, tone, and details to include. " +
  "Reply with only the questions.\n" +
  "Step 2 (after they answer): write the expanded passage in Markdown. Output only the passage, with no " +
  "preamble or commentary.\n" +
  "If they then ask for changes, output the full revised passage.";

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

const noteName = (path) => path.replace(/\.md$/, "");
const notesBlock = (hits) => hits.map((h) => `Note [[${noteName(h.path)}]]:\n${h.text}`).join("\n\n---\n\n");
const stripThink = (t) => t.replace(/<think>[\s\S]*?(<\/think>|$)/g, "");

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
    if (stale.length) await this.plugin.save();
    return stale.length;
  }

  async search(text, k) {
    const [q] = await this.embed(["search_query: " + text]);
    const hits = [];
    for (const [path, entry] of Object.entries(this.plugin.index))
      for (const c of entry.chunks) hits.push({ path, text: c.text, score: cosine(q, c.vec) });
    hits.sort((a, b) => b.score - a.score);
    return hits.filter((h) => h.score >= this.s.minScore).slice(0, k || this.s.topK);
  }

  // Ask mode: system + recent turns + (notes + question).
  askMessages(question, hits, turns) {
    const past = turns.slice(-HISTORY_TURNS).map((t) => ({ role: t.role, content: t.content }));
    return [
      { role: "system", content: ASK_SYSTEM },
      ...past,
      { role: "user", content: `Notes:\n\n${notesBlock(hits)}\n\nQuestion: ${question}` },
    ];
  }

  // Expand mode: system + the passage and related notes + the whole conversation.
  expandMessages(expand, hits, turns) {
    const ctx = `Passage to expand (from [[${noteName(expand.path)}]]):\n"""\n${expand.text}\n"""\n\n` +
      (hits.length ? `Related notes from the vault:\n\n${notesBlock(hits)}` : "No related notes were found in the vault.");
    return [{ role: "system", content: EXPAND_SYSTEM }, { role: "user", content: ctx },
      ...turns.map((t) => ({ role: t.role, content: t.content }))];
  }

  // Stream a chat completion: onToken(fullTextSoFar) is called as the model writes.
  async stream(messages, onToken, signal, temperature) {
    let res;
    try {
      res = await fetch(this.base + "/api/chat", {
        method: "POST", signal, headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ model: this.s.chatModel, stream: true, think: false, options: { temperature }, messages }),
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
        if (msg.message && msg.message.content) { text += msg.message.content; onToken(stripThink(text)); }
      }
    }
    return stripThink(text).trim();
  }
}

class ChatView extends ItemView {
  constructor(leaf, plugin) { super(leaf); this.plugin = plugin; this.ask = new VaultAsk(plugin); this.chat = null; this.abort = null; this.showingHistory = false; }
  getViewType() { return VIEW_TYPE; }
  getDisplayText() { return "Ask the Vault"; }
  getIcon() { return "bot"; }

  iconButton(parent, icon, label, onClick) {
    const b = parent.createEl("button", { cls: "clickable-icon vault-ask-icon", attr: { "aria-label": label } });
    setIcon(b, icon); b.onclick = onClick; return b;
  }

  async onOpen() {
    const root = this.contentEl;
    root.empty(); root.addClass("vault-ask-view");
    const head = root.createDiv({ cls: "vault-ask-head" });
    this.titleEl = head.createDiv({ cls: "vault-ask-title", text: "Ask the Vault" });
    this.historyBtn = this.iconButton(head, "history", "Previous chats", () => this.toggleHistory());
    this.iconButton(head, "square-pen", "New chat", () => this.newChat());
    this.iconButton(head, "panel-right-close", "Close chat panel", () => this.leaf.detach());

    this.log = root.createDiv({ cls: "vault-ask-log" });
    // Clicks on [[links]] in answers and on source links open the note.
    this.log.addEventListener("click", (e) => {
      const a = e.target.closest("a.internal-link, a.vault-ask-source");
      if (!a) return;
      e.preventDefault();
      this.app.workspace.openLinkText(a.getAttribute("data-href") || a.textContent, "", false);
    });

    // Composer: one rounded box holding the text area and a round send button.
    this.form = root.createDiv({ cls: "vault-ask-form" });
    const box = this.form.createDiv({ cls: "vault-ask-composer" });
    this.input = box.createEl("textarea", { cls: "vault-ask-input", attr: { rows: "1", placeholder: "Ask about your notes…", title: "Enter to send · Shift+Enter for a new line" } });
    this.sendBtn = box.createEl("button", { cls: "vault-ask-send", attr: { "aria-label": "Send" } });
    setIcon(this.sendBtn, "arrow-up");
    this.sendBtn.onclick = () => (this.abort ? this.abort.abort() : this.send());
    this.grow = () => { this.input.style.height = "auto"; this.input.style.height = Math.min(this.input.scrollHeight, 180) + "px"; };
    this.input.addEventListener("input", this.grow);
    this.input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); if (!this.abort) this.send(); } });
    this.newChat();
  }

  async onClose() { if (this.abort) this.abort.abort(); }

  // ── chats ────────────────────────────────────────────────────────────────
  newChat(mode, expand) {
    if (this.abort) this.abort.abort();
    this.chat = { id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6), mode: mode || "ask", title: "", created: Date.now(), turns: [], expand: expand || null };
    this.showingHistory = false; this.historyBtn.removeClass("is-active");
    this.titleEl.setText(this.chat.mode === "expand" ? "Expand with AI" : "Ask the Vault");
    this.input.placeholder = this.chat.mode === "expand" ? "Answer the questions, or ask for changes…" : "Ask about your notes…";
    this.form.show();
    this.log.empty();
    if (this.chat.mode === "ask")
      this.log.createDiv({ cls: "vault-ask-hint", text: "Ask anything your notes can answer. Answers come only from this vault, run on this laptop, and link the notes they used." });
    this.input.focus();
  }

  async saveChat() {
    const c = this.chat;
    if (!c.turns.length) return;
    if (!c.title) {
      const first = c.mode === "expand" ? "Expand: " + c.expand.text : c.turns[0].content;
      c.title = first.replace(/\s+/g, " ").trim().slice(0, 60);
    }
    c.updated = Date.now();
    const chats = this.plugin.chats.filter((x) => x.id !== c.id);
    chats.unshift(JSON.parse(JSON.stringify(c)));
    this.plugin.chats = chats.slice(0, MAX_CHATS);
    await this.plugin.save();
  }

  openChat(saved) {
    this.newChat(saved.mode, saved.expand);
    this.chat = JSON.parse(JSON.stringify(saved));
    this.titleEl.setText(this.chat.mode === "expand" ? "Expand with AI" : "Ask the Vault");
    this.log.empty();
    if (this.chat.mode === "expand") this.renderPassage();
    let answers = 0;
    for (const t of this.chat.turns) {
      if (t.role === "user") this.log.createDiv({ cls: "vault-ask-msg vault-ask-user", text: t.content });
      else this.renderBot(t.content, t.sources, this.chat.mode === "expand" && answers++ > 0);
    }
    this.scroll();
  }

  toggleHistory() {
    if (this.showingHistory) { this.openChat(this.chat); return; }
    this.showingHistory = true; this.historyBtn.addClass("is-active");
    this.form.hide();
    this.log.empty();
    const chats = this.plugin.chats;
    this.log.createDiv({ cls: "vault-ask-section", text: "Previous chats" });
    if (!chats.length) { this.log.createDiv({ cls: "vault-ask-hint", text: "No saved chats yet." }); return; }
    for (const c of chats) {
      const row = this.log.createDiv({ cls: "vault-ask-chat-row" });
      const ic = row.createSpan({ cls: "vault-ask-chat-icon" }); setIcon(ic, c.mode === "expand" ? "wand-2" : "message-square");
      const txt = row.createDiv({ cls: "vault-ask-chat-text" });
      txt.createDiv({ cls: "vault-ask-chat-title", text: c.title || "(untitled)" });
      txt.createDiv({ cls: "vault-ask-chat-date", text: new Date(c.updated || c.created).toLocaleString() });
      const del = this.iconButton(row, "trash-2", "Delete chat", async (e) => {
        e.stopPropagation();
        this.plugin.chats = this.plugin.chats.filter((x) => x.id !== c.id);
        await this.plugin.save();
        this.showingHistory = false; this.toggleHistory();
      });
      del.addClass("vault-ask-chat-del");
      row.onclick = () => this.openChat(c);
    }
  }

  // ── rendering ────────────────────────────────────────────────────────────
  scroll() { this.log.scrollTop = this.log.scrollHeight; }

  renderPassage() {
    const e = this.chat.expand;
    const q = this.log.createDiv({ cls: "vault-ask-passage" });
    q.createDiv({ cls: "vault-ask-passage-label", text: "Expanding from " + noteName(e.path) });
    q.createDiv({ cls: "vault-ask-passage-text", text: e.text });
  }

  renderBot(text, sources, withActions) {
    const bubble = this.log.createDiv({ cls: "vault-ask-msg vault-ask-bot" });
    const body = bubble.createDiv({ cls: "vault-ask-body markdown-rendered" });
    MarkdownRenderer.render(this.app, text, body, "", this);
    if (sources && sources.length) this.renderSources(bubble, sources);
    if (withActions) this.renderActions(bubble, text);
    return bubble;
  }

  renderSources(bubble, sources) {
    const src = bubble.createDiv({ cls: "vault-ask-sources" });
    src.createSpan({ text: this.chat.mode === "expand" ? "Context: " : "Searched: ", cls: "vault-ask-sources-title" });
    for (const p of sources) src.createEl("a", { text: noteName(p), cls: "vault-ask-source", href: "#", attr: { "data-href": p } });
  }

  renderActions(bubble, text) {
    const bar = bubble.createDiv({ cls: "vault-ask-actions" });
    const mk = (label, icon, fn) => { const b = bar.createEl("button", { cls: "vault-ask-action" }); const i = b.createSpan(); setIcon(i, icon); b.createSpan({ text: label }); b.onclick = fn; };
    mk("Replace selection", "replace", () => this.applyExpansion(text, "replace"));
    mk("Insert below", "list-plus", () => this.applyExpansion(text, "below"));
    mk("Copy", "copy", async () => { await navigator.clipboard.writeText(text); new Notice("Copied"); });
  }

  // Put the expansion into the note: replace the original passage, or add it after it.
  async applyExpansion(text, how) {
    const e = this.chat.expand;
    const file = this.app.vault.getAbstractFileByPath(e.path);
    if (!(file instanceof TFile)) { await navigator.clipboard.writeText(text); new Notice("Note not found; the text is on your clipboard."); return; }
    let found = false;
    await this.app.vault.process(file, (data) => {
      const i = data.indexOf(e.text);
      if (i < 0) return data;
      found = true;
      return how === "replace" ? data.slice(0, i) + text + data.slice(i + e.text.length)
                               : data.slice(0, i + e.text.length) + "\n\n" + text + data.slice(i + e.text.length);
    });
    if (!found) { await navigator.clipboard.writeText(text); new Notice("The original text has changed in the note; the expansion is on your clipboard."); return; }
    if (how === "replace") e.text = text;   // so a later "replace" swaps this version
    await this.saveChat();
    new Notice(how === "replace" ? "Selection replaced" : "Inserted below the selection");
  }

  setBusy(busy) {
    setIcon(this.sendBtn, busy ? "square" : "arrow-up");
    this.sendBtn.setAttribute("aria-label", busy ? "Stop" : "Send");
    this.sendBtn.toggleClass("vault-ask-stop", busy);
  }

  // ── sending ──────────────────────────────────────────────────────────────
  async startExpand(path, text) {
    this.newChat("expand", { path, text });
    this.renderPassage();
    await this.run(null);
  }

  async send() {
    const content = this.input.value.trim();
    if (!content || this.showingHistory) return;
    this.input.value = ""; this.grow();
    const hint = this.log.querySelector(".vault-ask-hint"); if (hint) hint.remove();
    this.log.createDiv({ cls: "vault-ask-msg vault-ask-user", text: content });
    await this.run(content);
  }

  // One model reply. content = the user's new message (null for the first expand turn).
  async run(content) {
    const chat = this.chat;
    const bubble = this.log.createDiv({ cls: "vault-ask-msg vault-ask-bot" });
    const status = bubble.createDiv({ cls: "vault-ask-status" });
    const body = bubble.createDiv({ cls: "vault-ask-body markdown-rendered" });
    this.scroll();
    this.abort = new AbortController();
    this.setBusy(true);
    let answer = "", sources = [];
    try {
      status.setText("Indexing notes…");
      await this.ask.refreshIndex((d, n) => status.setText(`Indexing notes… ${d}/${n}`));
      status.setText("Searching your notes…");
      let messages, temperature;
      if (chat.mode === "expand") {
        const hits = await this.ask.search(chat.expand.text, 4);
        sources = [...new Set(hits.map((h) => h.path))];
        if (content) chat.turns.push({ role: "user", content });
        messages = this.ask.expandMessages(chat.expand, hits, chat.turns);
        temperature = 0.6;
      } else {
        const hits = await this.ask.search(content);
        sources = [...new Set(hits.map((h) => h.path))];
        if (!hits.length) {
          status.remove(); body.setText(NOT_FOUND);
          chat.turns.push({ role: "user", content }, { role: "assistant", content: NOT_FOUND });
          await this.saveChat(); return;
        }
        messages = this.ask.askMessages(content, hits, chat.turns);
        chat.turns.push({ role: "user", content });
        temperature = 0.2;
      }
      status.setText(chat.mode === "expand" && !content ? "Reading the passage…" : "Thinking (local model)…");
      let pending = null, latest = "";
      const render = async () => { pending = null; body.empty(); await MarkdownRenderer.render(this.app, latest, body, "", this); this.scroll(); };
      answer = await this.ask.stream(messages, (t) => {
        if (status.isConnected) status.remove();
        latest = t;
        if (!pending) pending = setTimeout(render, 60);   // re-render at most ~16x a second
      }, this.abort.signal, temperature);
      if (pending) clearTimeout(pending);
      latest = answer; await render();
      chat.turns.push({ role: "assistant", content: answer, sources });
      if (sources.length) this.renderSources(bubble, sources);
      // In expand chats every reply after the questions is a draft you can use.
      const replies = chat.turns.filter((t) => t.role === "assistant").length;
      if (chat.mode === "expand" && replies > 1) this.renderActions(bubble, answer);
      await this.saveChat();
    } catch (e) {
      if (status.isConnected) status.remove();
      if (e.name === "AbortError") {
        body.createDiv({ cls: "vault-ask-note", text: "(stopped)" });
        if (answer) { chat.turns.push({ role: "assistant", content: answer, sources }); await this.saveChat(); }
      } else body.setText("Error: " + e.message);
    } finally {
      this.abort = null;
      this.setBusy(false);
      this.scroll();
      this.input.focus();
    }
  }
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
    const note = noteName(item.file.path);
    return item.heading ? `${note} › ${item.heading}` : note;
  }
  renderSuggestion(match, el) {
    const item = match.item;
    el.addClass("vault-ask-link-item");
    if (item.heading) {
      el.createSpan({ text: "## ", cls: "vault-ask-link-h2" });
      el.createSpan({ text: item.heading });
      el.createSpan({ text: "  " + noteName(item.file.path), cls: "vault-ask-link-path" });
    } else {
      el.createSpan({ text: noteName(item.file.path) });
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
      .addText((t) => t.setValue(String(s[key])).onChange(async (v) => { s[key] = key === "topK" ? (parseInt(v, 10) || DEFAULTS.topK) : v.trim(); await this.plugin.save(); }));
    text("Ollama URL", "Where the local Ollama server listens.", "ollamaUrl");
    text("Chat model", "Ollama model that writes the answers.", "chatModel");
    text("Embedding model", "Ollama model used to search notes (changing it re-indexes the vault).", "embedModel");
    text("Notes per answer", "How many note chunks are given to the model.", "topK");
    new Setting(containerEl).setName("Rebuild index").setDesc("Re-embed every note from scratch.")
      .addButton((b) => b.setButtonText("Rebuild").onClick(async () => {
        this.plugin.index = {}; await this.plugin.save();
        new Notice("Ask the Vault: indexing…");
        const n = await new VaultAsk(this.plugin).refreshIndex();
        new Notice(`Ask the Vault: indexed ${n} notes.`);
      }));
    new Setting(containerEl).setName("Delete chat history").setDesc(`${this.plugin.chats.length} saved chats.`)
      .addButton((b) => b.setButtonText("Delete all").setWarning().onClick(async () => {
        this.plugin.chats = []; await this.plugin.save(); this.display(); new Notice("Chat history deleted");
      }));
  }
}

module.exports = class VaultAskPlugin extends Plugin {
  async onload() {
    const data = (await this.loadData()) || {};
    this.settings = Object.assign({}, DEFAULTS, data.settings || {});
    this.index = data.index || {};
    this.chats = data.chats || [];
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
    // Expand the selected text (the AI asks clarifying questions first).
    const expand = async (editor, view) => {
      const text = editor.getSelection().trim();
      if (!text) { new Notice("Select the text you want to expand first."); return; }
      if (!view.file) return;
      const chat = await this.openChat();
      if (chat) await chat.startExpand(view.file.path, text);
    };
    this.addCommand({ id: "expand-selection", name: "Expand selection with AI…", icon: "wand-2",
      hotkeys: [{ modifiers: ["Mod", "Shift"], key: "e" }], editorCallback: expand });
    this.registerEvent(this.app.workspace.on("editor-menu", (menu, editor, view) => {
      const sel = !!editor.getSelection().trim();
      menu.addItem((item) => item.setTitle(sel ? "Link selection to…" : "Insert link to note or heading…").setIcon("link").onClick(() => pick(editor, view)));
      if (sel) menu.addItem((item) => item.setTitle("Expand with AI…").setIcon("wand-2").onClick(() => expand(editor, view)));
    }));
  }

  // Open (or reveal) the side chat and return its view.
  async openChat() {
    let leaf = this.app.workspace.getLeavesOfType(VIEW_TYPE)[0];
    if (!leaf) {
      leaf = this.app.workspace.getRightLeaf(false);
      await leaf.setViewState({ type: VIEW_TYPE, active: true });
    }
    await this.app.workspace.revealLeaf(leaf);
    const view = leaf.view;
    if (view && view.input) setTimeout(() => view.input.focus(), 50);
    return view instanceof ChatView ? view : null;
  }

  async save() { await this.saveData({ settings: this.settings, index: this.index, chats: this.chats }); }
};

// Exposed for tests (not used by Obsidian).
module.exports.VaultAsk = VaultAsk;
module.exports.chunkText = chunkText;
module.exports.LinkPicker = LinkPicker;
