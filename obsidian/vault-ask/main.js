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
const { Plugin, ItemView, Modal, Notice, MarkdownRenderer, PluginSettingTab, Setting, TFile, requestUrl, setIcon } = require("obsidian");

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

// ── Auto-link ────────────────────────────────────────────────────────────
// Find plain-text mentions of other notes' names and H2 headings in a note and
// turn the first mention of each into a link. Skips text that is already a
// link, code, headings, tags, %%comments%%, URLs and the properties block.
function protectedRanges(text) {
  const ranges = [];
  const add = (re) => { for (const m of text.matchAll(re)) ranges.push([m.index, m.index + m[0].length]); };
  const fm = text.match(/^---\n[\s\S]*?\n---\n/); if (fm) ranges.push([0, fm[0].length]);
  add(/```[\s\S]*?```/g);              // fenced code
  add(/`[^`\n]*`/g);                   // inline code
  add(/%%[\s\S]*?%%/g);                // comments (incl. live tag-link markers)
  add(/!?\[\[[^\]]*\]\]/g);            // wiki links / embeds
  add(/!?\[[^\]]*\]\([^)]*\)/g);       // markdown links
  add(/https?:\/\/\S+/g);              // URLs
  add(/^#{1,6} .*$/gm);                // heading lines
  add(/(^|\s)#[\p{L}\p{N}_/-]+/gu);    // tags
  return ranges;
}

// candidates: [{ text, file, heading }]. Returns [{ from, to, matched, target }] (offsets), longest names first.
function findAutoLinks(text, candidates) {
  const blocked = protectedRanges(text);
  const overlaps = (a, b) => blocked.some(([x, y]) => a < y && b > x);
  const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const out = [];
  const seen = new Set(), seenText = new Set();
  // Targets the note already links to (by note name, and note#heading) are skipped.
  const linked = new Set();
  const base = (p) => p.split("/").pop().replace(/\.md$/, "").toLowerCase();
  for (const m of text.matchAll(/\[\[([^\]|]+)/g)) {
    const [name, head] = m[1].split("#");
    if (name) { linked.add(base(name)); if (head) linked.add(base(name) + "#" + head.toLowerCase()); }
  }
  for (const c of candidates.slice().sort((a, b) => b.text.length - a.text.length || (a.heading ? 1 : 0) - (b.heading ? 1 : 0))) {
    if (c.text.length < 3) continue;
    const key = c.file.path + "#" + (c.heading || "");
    if (seen.has(key)) continue;
    if (c.heading ? linked.has(base(c.file.path) + "#" + c.heading.toLowerCase()) : linked.has(base(c.file.path))) { seenText.add(c.text.toLowerCase()); continue; }
    if (seenText.has(c.text.toLowerCase())) continue;     // one link per name; a note beats a heading of the same name
    const re = new RegExp(`(?<![\\p{L}\\p{N}])${esc(c.text)}(?![\\p{L}\\p{N}])`, "giu");
    for (const m of text.matchAll(re)) {
      const from = m.index, to = from + m[0].length;
      if (overlaps(from, to)) continue;
      out.push({ from, to, matched: m[0], target: c });
      blocked.push([from, to]);           // no other link inside this one
      seen.add(key); seenText.add(c.text.toLowerCase());
      break;                               // first mention only
    }
  }
  return out.sort((a, b) => a.from - b.from);
}

function autoLinkCandidates(app, sourcePath) {
  const cands = [];
  for (const file of app.vault.getMarkdownFiles()) {
    if (file.path !== sourcePath) cands.push({ text: file.basename, file, heading: null });
    for (const h of (app.metadataCache.getFileCache(file) || {}).headings || [])
      if (h.level === 2 && !(file.path === sourcePath)) cands.push({ text: h.heading, file, heading: h.heading });
  }
  return cands;
}

// ── Expand with AI, inside the note ──────────────────────────────────────
// A small box asks the clarifying questions; once answered, the expansion
// streams straight into the note in place of the selection (Ctrl+Z undoes it).
class ExpandModal extends Modal {
  constructor(plugin, editor, file) {
    super(plugin.app);
    this.plugin = plugin; this.editor = editor; this.file = file;
    this.ask = new VaultAsk(plugin);
    this.from = editor.getCursor("from"); this.to = editor.getCursor("to");
    this.text = editor.getRange(this.from, this.to);
    this.turns = []; this.abort = null;
  }
  onOpen() {
    const { contentEl } = this;
    this.modalEl.addClass("vault-ask-expand-modal");
    this.titleEl.setText("Expand with AI");
    const q = contentEl.createDiv({ cls: "vault-ask-passage" });
    q.createDiv({ cls: "vault-ask-passage-text", text: this.text });
    this.qEl = contentEl.createDiv({ cls: "vault-ask-body markdown-rendered vault-ask-questions" });
    this.qEl.createDiv({ cls: "vault-ask-status", text: "Reading the passage…" });
    const box = contentEl.createDiv({ cls: "vault-ask-composer" });
    this.input = box.createEl("textarea", { cls: "vault-ask-input", attr: { rows: "3", placeholder: "Answer the questions…" } });
    this.go = contentEl.createEl("button", { text: "Write it", cls: "mod-cta vault-ask-write" });
    this.go.disabled = true;
    this.go.onclick = () => this.write();
    this.input.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); this.write(); } });
    this.questions();
  }
  onClose() { if (this.abort) this.abort.abort(); this.contentEl.empty(); }

  async context() {
    if (!this.hits) {
      await this.ask.refreshIndex();
      this.hits = await this.ask.search(this.text, 4);
    }
    return this.hits;
  }

  async questions() {
    try {
      const hits = await this.context();
      this.abort = new AbortController();
      const q = await this.ask.stream(this.ask.expandMessages({ path: this.file.path, text: this.text }, hits, []), async (t) => {
        this.qEl.empty(); await MarkdownRenderer.render(this.app, t, this.qEl, this.file.path, this.plugin);
      }, this.abort.signal, 0.6);
      this.turns.push({ role: "assistant", content: q });
      this.go.disabled = false;
      this.input.focus();
    } catch (e) {
      if (e.name !== "AbortError") { this.qEl.empty(); this.qEl.setText("Error: " + e.message); }
    } finally { this.abort = null; }
  }

  // Close the box and stream the expansion into the note, replacing the selection.
  async write() {
    const answer = this.input.value.trim();
    if (!answer || this.go.disabled) return;
    this.turns.push({ role: "user", content: answer });
    const hits = await this.context();
    const messages = this.ask.expandMessages({ path: this.file.path, text: this.text }, hits, this.turns);
    const editor = this.editor, start = editor.posToOffset(this.from);
    let written = this.text.length;               // length of what currently sits at the selection
    this.close();
    const notice = new Notice("Writing the expansion into the note…", 0);
    try {
      const put = (t) => {
        editor.replaceRange(t, editor.offsetToPos(start), editor.offsetToPos(start + written));
        written = t.length;
      };
      const final = await this.ask.stream(messages, put, undefined, 0.6);
      put(final);
      notice.hide();
      new Notice("Expanded. Ctrl+Z to undo.");
    } catch (e) {
      notice.hide();
      new Notice("Expand failed: " + e.message);
    }
  }
}

// ── Auto-link the open note ──────────────────────────────────────────────
function autoLinkEditor(plugin, editor, file) {
  const app = plugin.app;
  const text = editor.getValue();
  const found = findAutoLinks(text, autoLinkCandidates(app, file.path));
  if (!found.length) { new Notice("Auto-link: no unlinked mentions of your notes or headings found."); return; }
  const changes = found.map((h) => {
    const t = h.target;
    const alias = t.heading ? h.matched : (h.matched === t.file.basename ? undefined : h.matched);
    let link = app.fileManager.generateMarkdownLink(t.file, file.path, t.heading ? "#" + t.heading : "", alias);
    const lineStart = text.lastIndexOf("\n", h.from) + 1;
    if (text.slice(lineStart, h.from).trimStart().startsWith("|")) link = link.replace(/(?<!\\)\|/g, "\\|");
    return { from: editor.offsetToPos(h.from), to: editor.offsetToPos(h.to), text: link };
  });
  editor.transaction({ changes });             // one step: Ctrl+Z undoes all of it
  const names = found.map((h) => h.matched);
  new Notice(`Auto-linked ${found.length}: ${names.slice(0, 6).join(", ")}${names.length > 6 ? "…" : ""}\nCtrl+Z to undo.`, 6000);
}

// Same, for text on disk: returns { text, found } with the links written in.
function autoLinkText(app, text, file) {
  const found = findAutoLinks(text, autoLinkCandidates(app, file.path));
  let out = text;
  for (const h of found.slice().sort((a, b) => b.from - a.from)) {
    const t = h.target;
    const alias = t.heading ? h.matched : (h.matched === t.file.basename ? undefined : h.matched);
    let link = app.fileManager.generateMarkdownLink(t.file, file.path, t.heading ? "#" + t.heading : "", alias);
    const lineStart = out.lastIndexOf("\n", h.from) + 1;
    if (out.slice(lineStart, h.from).trimStart().startsWith("|")) link = link.replace(/(?<!\\)\|/g, "\\|");
    out = out.slice(0, h.from) + link + out.slice(h.to);
  }
  return { text: out, found };
}

// ── Auto-link the whole vault ────────────────────────────────────────────
// Scans every note, shows what it would link (untick notes to skip), then
// writes the links. The originals are kept so "Undo" puts every note back.
class VaultAutoLinkModal extends Modal {
  constructor(plugin) { super(plugin.app); this.plugin = plugin; }
  async onOpen() {
    this.modalEl.addClass("vault-ask-autolink-modal");
    this.titleEl.setText("Auto-link the vault");
    const { contentEl } = this;
    contentEl.createDiv({ cls: "vault-ask-status", text: "Looking through your notes…" });
    const plan = [];
    for (const file of this.app.vault.getMarkdownFiles().sort((a, b) => a.path.localeCompare(b.path))) {
      const text = await this.app.vault.cachedRead(file);
      const r = autoLinkText(this.app, text, file);
      if (r.found.length) plan.push({ file, found: r.found, on: true });
    }
    contentEl.empty();
    if (!plan.length) { contentEl.createDiv({ cls: "vault-ask-status", text: "Nothing to link: every mention of a note or heading is already linked." }); return; }
    const total = () => plan.filter((x) => x.on).reduce((n, x) => n + x.found.length, 0);
    contentEl.createDiv({ cls: "vault-ask-autolink-intro", text: "Plain mentions of other notes and their headings that would become links (first mention in each note):" });
    const list = contentEl.createDiv({ cls: "vault-ask-autolink-list" });
    const go = contentEl.createEl("button", { cls: "mod-cta vault-ask-write" });
    const label = () => { const n = total(), m = plan.filter((x) => x.on).length; go.setText(`Link ${n} mention${n === 1 ? "" : "s"} in ${m} note${m === 1 ? "" : "s"}`); go.disabled = !n; };
    for (const item of plan) {
      const row = list.createEl("label", { cls: "vault-ask-autolink-row" });
      const cb = row.createEl("input", { attr: { type: "checkbox" } });
      cb.checked = true; cb.onchange = () => { item.on = cb.checked; label(); };
      const body = row.createDiv({ cls: "vault-ask-pick-body" });
      body.createDiv({ cls: "vault-ask-pick-title", text: item.file.basename });
      body.createDiv({ cls: "vault-ask-pick-sub", text: item.found.map((h) => h.matched + " → " + (h.target.heading ? h.target.file.basename + " › " + h.target.heading : h.target.file.basename)).join(" · ") });
    }
    label();
    go.onclick = async () => {
      go.disabled = true;
      const undo = {};
      let n = 0, m = 0;
      for (const item of plan.filter((x) => x.on)) {
        await this.app.vault.process(item.file, (text) => {
          const r = autoLinkText(this.app, text, item.file);   // recomputed on the live text
          if (r.found.length) { undo[item.file.path] = text; n += r.found.length; m++; }
          return r.text;
        });
      }
      this.plugin.lastVaultAutoLink = undo;
      this.close();
      const note = new Notice("", 12000);
      note.noticeEl.empty();
      note.noticeEl.createSpan({ text: `Auto-linked ${n} mention${n === 1 ? "" : "s"} in ${m} note${m === 1 ? "" : "s"}. ` });
      const u = note.noticeEl.createEl("a", { text: "Undo", href: "#" });
      u.onclick = (e) => { e.preventDefault(); note.hide(); this.plugin.undoVaultAutoLink(); };
    };
  }
  onClose() { this.contentEl.empty(); }
}

// ── Heading graph ────────────────────────────────────────────────────────
// Like Obsidian's graph, but split by headings: notes, their headings (H2 and
// below; text above the first one belongs to the note), and tags. Lines join a
// note to its headings, a heading to whatever its section links to (a note or
// a specific heading), and a heading to the tags in its section.
const GRAPH_VIEW = "dictatoros-heading-graph";

function buildHeadingGraph(app) {
  const nodes = new Map(), edges = new Map();
  const node = (id, n) => { if (!nodes.has(id)) nodes.set(id, Object.assign({ id, deg: 0 }, n)); return nodes.get(id); };
  const edge = (a, b, kind) => { if (a === b) return; const k = a < b ? a + "|" + b : b + "|" + a; if (!edges.has(k)) edges.set(k, { a, b, kind }); };
  const files = app.vault.getMarkdownFiles();
  const sharing = new Map();   // tag id -> set of heading/note ids carrying it
  const sections = (file) => {
    const cache = app.metadataCache.getFileCache(file) || {};
    return { cache, heads: (cache.headings || []).filter((h) => h.level >= 2).sort((a, b) => a.position.start.line - b.position.start.line) };
  };
  const ownerId = (file, heads, line) => {
    let owner = null;
    for (const h of heads) { if (h.position.start.line <= line) owner = h; else break; }
    return owner ? file.path + "#" + owner.heading : file.path;
  };
  for (const file of files) {
    node(file.path, { kind: "note", label: file.basename, path: file.path });
    for (const h of sections(file).heads) {
      node(file.path + "#" + h.heading, { kind: "heading", label: h.heading, path: file.path, heading: h.heading });
      edge(file.path, file.path + "#" + h.heading, "contains");
    }
  }
  for (const file of files) {
    const { cache, heads } = sections(file);
    for (const l of cache.links || []) {
      const [linkpath, sub] = l.link.split("#");
      const dest = linkpath ? app.metadataCache.getFirstLinkpathDest(linkpath, file.path) : file;
      if (!dest || dest.extension !== "md") continue;
      const target = sub && nodes.has(dest.path + "#" + sub) ? dest.path + "#" + sub : dest.path;
      edge(ownerId(file, heads, l.position.start.line), target, "link");
    }
    for (const t of cache.tags || []) {
      const tid = "tag:" + t.tag.toLowerCase();
      node(tid, { kind: "tag", label: t.tag });
      const owner = ownerId(file, heads, t.position.start.line);
      edge(owner, tid, "tag");
      if (!sharing.has(tid)) sharing.set(tid, new Set());
      sharing.get(tid).add(owner);
    }
  }
  // Headings (or notes) that share a tag are linked to each other directly.
  // Big groups get a chain instead of every pair, to keep the graph readable.
  for (const owners of sharing.values()) {
    const list = [...owners];
    if (list.length <= 12) { for (let i = 0; i < list.length; i++) for (let j = i + 1; j < list.length; j++) edge(list[i], list[j], "shared"); }
    else for (let i = 1; i < list.length; i++) edge(list[i - 1], list[i], "shared");
  }
  const list = [...edges.values()];
  for (const e of list) { nodes.get(e.a).deg++; nodes.get(e.b).deg++; }
  return { nodes: [...nodes.values()], edges: list };
}

class HeadingGraphView extends ItemView {
  constructor(leaf, plugin) { super(leaf); this.plugin = plugin; }
  getViewType() { return GRAPH_VIEW; }
  getDisplayText() { return "Heading graph"; }
  getIcon() { return "network"; }

  async onOpen() {
    const root = this.contentEl; root.empty(); root.addClass("vault-ask-graph");
    this.canvas = root.createEl("canvas");
    this.legend = root.createDiv({ cls: "vault-ask-graph-legend" });
    for (const [cls, label] of [["note", "Note"], ["heading", "Heading"], ["tag", "Tag"]]) {
      const i = this.legend.createDiv({ cls: "vault-ask-graph-key" }); i.createSpan({ cls: "dot " + cls }); i.createSpan({ text: label });
    }
    const sk = this.legend.createDiv({ cls: "vault-ask-graph-key" }); sk.createSpan({ cls: "line shared" }); sk.createSpan({ text: "Same tag" });
    this.ctx = this.canvas.getContext("2d");
    this.view = { x: 0, y: 0, k: 1 };
    this.hover = null; this.drag = null;
    this.registerDomEvent(this.canvas, "wheel", (e) => this.onWheel(e), { passive: false });
    this.registerDomEvent(this.canvas, "pointerdown", (e) => this.onDown(e));
    this.registerDomEvent(window, "pointermove", (e) => this.onMove(e));
    this.registerDomEvent(window, "pointerup", (e) => this.onUp(e));
    this.ro = new ResizeObserver(() => this.resize()); this.ro.observe(root);
    // Rebuild when notes change (debounced).
    const soon = () => { clearTimeout(this.rebuildT); this.rebuildT = setTimeout(() => this.build(), 400); };
    this.registerEvent(this.app.metadataCache.on("changed", soon));
    this.registerEvent(this.app.metadataCache.on("resolved", soon));
    this.registerEvent(this.app.vault.on("delete", soon));
    this.registerEvent(this.app.vault.on("rename", soon));
    this.build();
  }

  async onClose() { if (this.ro) this.ro.disconnect(); cancelAnimationFrame(this.raf); }

  colors() {
    const cs = getComputedStyle(document.body);
    const v = (n, d) => (cs.getPropertyValue(n) || "").trim() || d;
    return { accent: v("--text-accent", "#e5383b"), text: v("--text-normal", "#ddd"), muted: v("--text-muted", "#888"),
      faint: v("--text-faint", "#555"), line: v("--background-modifier-border", "#444"), bg: v("--background-primary", "#000") };
  }

  build() {
    const g = buildHeadingGraph(this.app);
    const old = new Map((this.nodes || []).map((n) => [n.id, n]));
    this.nodes = g.nodes.map((n) => { const o = old.get(n.id); return Object.assign(n, o ? { x: o.x, y: o.y, vx: 0, vy: 0 } : { x: (Math.random() - 0.5) * 400, y: (Math.random() - 0.5) * 400, vx: 0, vy: 0 }); });
    const byId = new Map(this.nodes.map((n) => [n.id, n]));
    this.edges = g.edges.map((e) => ({ a: byId.get(e.a), b: byId.get(e.b), kind: e.kind }));
    this.neighbours = new Map(this.nodes.map((n) => [n, new Set()]));
    for (const e of this.edges) { this.neighbours.get(e.a).add(e.b); this.neighbours.get(e.b).add(e.a); }
    this.alpha = 1; this.loop();
  }

  radius(n) { return (n.kind === "note" ? 7 : n.kind === "tag" ? 5 : 4.5) + Math.min(6, Math.sqrt(n.deg)); }

  // Simple force layout: repulsion, springs on edges, gentle pull to centre.
  step() {
    const N = this.nodes, a = this.alpha;
    for (let i = 0; i < N.length; i++) for (let j = i + 1; j < N.length; j++) {
      const p = N[i], q = N[j]; let dx = q.x - p.x, dy = q.y - p.y; let d2 = dx * dx + dy * dy || 0.01;
      if (d2 > 250000) continue;
      const f = (900 * a) / d2, d = Math.sqrt(d2); dx /= d; dy /= d;
      p.vx -= dx * f; p.vy -= dy * f; q.vx += dx * f; q.vy += dy * f;
    }
    for (const e of this.edges) {
      const len = e.kind === "contains" ? 45 : e.kind === "shared" ? 110 : 90;
      let dx = e.b.x - e.a.x, dy = e.b.y - e.a.y; const d = Math.sqrt(dx * dx + dy * dy) || 0.01;
      const f = (d - len) * 0.04 * a; dx /= d; dy /= d;
      e.a.vx += dx * f; e.a.vy += dy * f; e.b.vx -= dx * f; e.b.vy -= dy * f;
    }
    for (const n of N) {
      n.vx -= n.x * 0.002 * a; n.vy -= n.y * 0.002 * a;
      if (this.drag && this.drag.node === n) { n.vx = n.vy = 0; continue; }
      n.vx *= 0.6; n.vy *= 0.6; n.x += n.vx; n.y += n.vy;
    }
    this.alpha = Math.max(this.drag ? 0.3 : 0, this.alpha * 0.985);
  }

  loop() {
    cancelAnimationFrame(this.raf);
    const tick = () => { if (this.alpha > 0.005) this.step(); this.draw(); if (this.alpha > 0.005 || this.drag) this.raf = requestAnimationFrame(tick); };
    this.raf = requestAnimationFrame(tick);
  }

  resize() {
    const r = this.contentEl.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    this.w = r.width; this.h = r.height;
    this.canvas.width = r.width * dpr; this.canvas.height = r.height * dpr;
    this.canvas.style.width = r.width + "px"; this.canvas.style.height = r.height + "px";
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.draw();
  }

  toScreen(n) { return [this.w / 2 + (n.x + this.view.x) * this.view.k, this.h / 2 + (n.y + this.view.y) * this.view.k]; }
  toWorld(sx, sy) { return [(sx - this.w / 2) / this.view.k - this.view.x, (sy - this.h / 2) / this.view.k - this.view.y]; }
  hit(e) {
    const r = this.canvas.getBoundingClientRect(); const [wx, wy] = this.toWorld(e.clientX - r.left, e.clientY - r.top);
    let best = null, bd = Infinity;
    for (const n of this.nodes) { const d = Math.hypot(n.x - wx, n.y - wy); const rr = this.radius(n) + 4 / this.view.k; if (d < rr && d < bd) { best = n; bd = d; } }
    return best;
  }

  draw() {
    if (!this.ctx || !this.nodes) return;
    const c = this.ctx, col = this.colors(), k = this.view.k, focus = this.hover || (this.drag && this.drag.node);
    const near = focus ? this.neighbours.get(focus) : null;
    c.fillStyle = col.bg; c.fillRect(0, 0, this.w, this.h);
    for (const e of this.edges) {
      const lit = focus && (e.a === focus || e.b === focus);
      const shared = e.kind === "shared";
      c.strokeStyle = lit || shared ? col.accent : col.line;
      c.globalAlpha = focus && !lit ? 0.2 : shared && !lit ? 0.45 : 1;
      c.lineWidth = lit ? 1.6 : e.kind === "contains" ? 0.8 : 1.1;
      c.setLineDash(e.kind === "tag" ? [3, 3] : []);
      const [x1, y1] = this.toScreen(e.a), [x2, y2] = this.toScreen(e.b);
      c.beginPath(); c.moveTo(x1, y1); c.lineTo(x2, y2); c.stroke();
    }
    c.setLineDash([]);
    for (const n of this.nodes) {
      const [x, y] = this.toScreen(n), r = this.radius(n) * Math.sqrt(k);
      const dim = focus && n !== focus && !near.has(n);
      c.globalAlpha = dim ? 0.25 : 1;
      c.fillStyle = n.kind === "tag" ? col.accent : n.kind === "note" ? col.text : col.muted;
      c.beginPath(); c.arc(x, y, r, 0, Math.PI * 2); c.fill();
      if (n === focus) { c.strokeStyle = col.accent; c.lineWidth = 2; c.stroke(); }
      if (k > 0.6 || n === focus || (near && near.has(n)) || n.kind === "note") {
        c.fillStyle = n === focus ? col.accent : n.kind === "note" ? col.text : col.muted;
        c.font = `${n.kind === "note" ? 12 : 11}px var(--font-interface, sans-serif)`;
        c.textAlign = "center"; c.fillText(n.label, x, y + r + 12);
      }
    }
    c.globalAlpha = 1;
  }

  onWheel(e) {
    e.preventDefault();
    const r = this.canvas.getBoundingClientRect(), sx = e.clientX - r.left, sy = e.clientY - r.top;
    const [wx, wy] = this.toWorld(sx, sy);
    this.view.k = Math.min(4, Math.max(0.2, this.view.k * Math.exp(-e.deltaY * 0.0015)));
    const [nx, ny] = this.toWorld(sx, sy); this.view.x += nx - wx; this.view.y += ny - wy;
    this.draw();
  }
  onDown(e) {
    const n = this.hit(e);
    this.drag = { node: n, sx: e.clientX, sy: e.clientY, vx: this.view.x, vy: this.view.y, moved: false };
    if (n) { this.alpha = Math.max(this.alpha, 0.3); this.loop(); }
  }
  onMove(e) {
    if (!this.drag) { const h = this.hit(e); if (h !== this.hover) { this.hover = h; this.canvas.style.cursor = h ? "pointer" : "grab"; this.draw(); } return; }
    const dx = e.clientX - this.drag.sx, dy = e.clientY - this.drag.sy;
    if (Math.abs(dx) + Math.abs(dy) > 3) this.drag.moved = true;
    if (this.drag.node) { const r = this.canvas.getBoundingClientRect(); const [wx, wy] = this.toWorld(e.clientX - r.left, e.clientY - r.top); this.drag.node.x = wx; this.drag.node.y = wy; }
    else { this.view.x = this.drag.vx + dx / this.view.k; this.view.y = this.drag.vy + dy / this.view.k; this.draw(); }
  }
  onUp() {
    const d = this.drag; this.drag = null;
    if (d && d.node && !d.moved) {
      const n = d.node;
      if (n.kind === "tag") this.app.internalPlugins.getPluginById("global-search")?.instance.openGlobalSearch("tag:" + n.label);
      else this.app.workspace.openLinkText(n.heading ? n.path + "#" + n.heading : n.path, "", false);
    }
  }
}

// "Link selection to…": pick a note, an H2 heading inside a note, or a tag.
// A note/heading turns the selected text into a link: [[Note#Heading|text]].
// A tag links to every heading carrying that tag, optionally only in one note
// (a tag belongs to the heading whose section it sits in; tags above the first
// heading or in the note's properties belong to the note itself).
//
// Tag links stay live: they are written between hidden markers,
//   %%tag:#data-collection in:Business Function/Marketing%%[[…]], [[…]]%%/tag%%
// and rewritten whenever notes change (see TagLinkUpdater).
function tagTargets(app) {
  const byTag = new Map();
  const add = (tag, target) => {
    const key = tag.replace(/^#/, "").toLowerCase();
    if (!byTag.has(key)) byTag.set(key, { tag: "#" + tag.replace(/^#/, ""), targets: [] });
    const list = byTag.get(key).targets;
    if (!list.some((t) => t.file === target.file && t.heading === target.heading)) list.push(target);
  };
  for (const file of app.vault.getMarkdownFiles().sort((a, b) => a.path.localeCompare(b.path))) {
    const cache = app.metadataCache.getFileCache(file) || {};
    const headings = (cache.headings || []).slice().sort((a, b) => a.position.start.line - b.position.start.line);
    for (const t of cache.tags || []) {
      const line = t.position.start.line;
      let owner = null;
      for (const h of headings) { if (h.position.start.line < line) owner = h; else break; }
      add(t.tag, { file, heading: owner ? owner.heading : null });
    }
    const fm = cache.frontmatter && (cache.frontmatter.tags || cache.frontmatter.tag);
    for (const t of (Array.isArray(fm) ? fm : fm ? String(fm).split(/[,\s]+/) : []).filter(Boolean)) add(String(t), { file, heading: null });
  }
  return [...byTag.values()].sort((a, b) => a.tag.localeCompare(b.tag));
}

const TAG_BLOCK = /%%tag:(#[^\s%]+)(?: in:([^%]+?))?%%([\s\S]*?)%%\/tag%%/g;

// The links for a tag (optionally only inside one note), as Markdown.
function tagLinksMarkdown(app, tag, scopePath, sourcePath, inTable) {
  const entry = tagTargets(app).find((t) => t.tag.toLowerCase() === tag.toLowerCase());
  const targets = entry ? entry.targets.filter((t) => !scopePath || t.file.path === scopePath) : [];
  return targets.map((t) => {
    const link = app.fileManager.generateMarkdownLink(t.file, sourcePath, t.heading ? "#" + t.heading : "", t.heading || undefined);
    return inTable ? link.replace(/(?<!\\)\|/g, "\\|") : link;   // a bare | would split a table cell
  }).join(", ");
}

function tagBlock(app, tag, scopePath, sourcePath, inTable) {
  return `%%tag:${tag}${scopePath ? " in:" + scopePath : ""}%%${tagLinksMarkdown(app, tag, scopePath, sourcePath, inTable)}%%/tag%%`;
}

// Rewrite every live tag-link block in a note's text; returns the new text.
function refreshTagBlocks(app, text, sourcePath) {
  text = text.replace(/ ?\((%%tag:[^%]*%%[\s\S]*?%%\/tag%%)\)/g, " · $1");   // older format used brackets
  return text.replace(TAG_BLOCK, (m, tag, scope, inner, offset) => {
    const lineStart = text.lastIndexOf("\n", offset) + 1;
    const inTable = text.slice(lineStart, offset).trimStart().startsWith("|");
    return tagBlock(app, tag, scope ? scope.trim() : null, sourcePath, inTable);
  });
}

// Link picker: a tree like the file explorer (folder › note › heading) plus a
// tag tree (tag › the notes that use it), with filter chips across the top.
// Arrows move, → / ← open and close, Tab switches filter, Enter links.
const PICK_FILTERS = [
  { id: "all", label: "All", picks: ["note", "heading", "tag", "tagnote"] },
  { id: "notes", label: "Notes", picks: ["note"] },
  { id: "headings", label: "Headings", picks: ["heading"] },
  { id: "tags", label: "Tags", picks: ["tag", "tagnote"] },
];

class LinkPicker extends Modal {
  constructor(app, editor, sourcePath) {
    super(app); this.editor = editor; this.sourcePath = sourcePath;
    const line = editor.getLine(editor.getCursor("from").line);
    this.inTable = line.trimStart().startsWith("|");
    this.lineNotes = [];
    for (const m of line.matchAll(/\[\[([^\]|#]+)/g)) {
      const f = app.metadataCache.getFirstLinkpathDest(m[1].trim(), sourcePath);
      if (f && !this.lineNotes.includes(f)) this.lineNotes.push(f);
    }
    this.filter = "all"; this.query = ""; this.cursor = 0;
    this.collapsed = new Set();
    this.roots = this.build();
  }

  build() {
    const h2s = (file) => ((this.app.metadataCache.getFileCache(file) || {}).headings || []).filter((h) => h.level === 2);
    // Folder › note › heading
    const top = { kind: "root", children: [] }, folders = new Map([["", top]]);
    const folderNode = (path) => {
      if (folders.has(path)) return folders.get(path);
      const parent = folderNode(path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "");
      const n = { kind: "folder", id: "f:" + path, label: path.split("/").pop(), children: [] };
      parent.children.push(n); folders.set(path, n); return n;
    };
    for (const file of this.app.vault.getMarkdownFiles().sort((a, b) => a.path.localeCompare(b.path))) {
      const dir = file.parent && file.parent.path !== "/" ? file.parent.path : "";
      folderNode(dir).children.push({ kind: "note", id: "n:" + file.path, label: file.basename, file, row: this.lineNotes.includes(file),
        children: h2s(file).map((h) => ({ kind: "heading", id: "h:" + file.path + "#" + h.heading, label: h.heading, file, heading: h.heading, children: [] })) });
    }
    const sortTree = (n) => { n.children.sort((a, b) => (a.kind === "folder" ? 0 : 1) - (b.kind === "folder" ? 0 : 1) || a.label.localeCompare(b.label)); n.children.forEach(sortTree); };
    sortTree(top);
    // Tag › note (only that note's headings)
    const where = (t) => t.heading || "whole note";
    const tags = { kind: "section", id: "s:tags", label: "Tags", children: tagTargets(this.app).map((t) => {
      const byNote = new Map();
      for (const x of t.targets) { if (!byNote.has(x.file)) byNote.set(x.file, []); byNote.get(x.file).push(x); }
      const kids = byNote.size > 1 ? [...byNote].map(([file, list]) => ({ kind: "tagnote", id: "t:" + t.tag + ":" + file.path, label: file.basename, file, tag: t.tag, scope: file, targets: list, row: this.lineNotes.includes(file), detail: list.map(where).join(", "), children: [] })) : [];
      return { kind: "tag", id: "t:" + t.tag, label: t.tag, tag: t.tag, scope: null, targets: t.targets, children: kids,
        detail: t.targets.map((x) => x.heading ? x.file.basename + " › " + x.heading : x.file.basename).join(", ") };
    }) };
    return [{ kind: "section", id: "s:notes", label: "Notes", children: top.children }, tags];
  }

  // Rows to show for the current filter/search: [{ node, depth, pick }]
  rows() {
    const f = PICK_FILTERS.find((x) => x.id === this.filter);
    const words = this.query.toLowerCase().split(/\s+/).filter(Boolean);
    const searching = words.length > 0;
    const matches = (text) => { const t = text.toLowerCase(); return words.every((w) => t.includes(w)); };
    const out = [];
    const walk = (n, depth, ctx) => {
      if (this.filter === "notes" && n.kind === "heading") return [];
      if (this.filter === "tags" && n.id === "s:notes") return [];
      if ((this.filter === "notes" || this.filter === "headings") && n.id === "s:tags") return [];
      const pick = f.picks.includes(n.kind);
      const self = pick && (!searching || matches(n.label + " " + (ctx || "") + " " + (n.detail || "")));
      const open = searching || !this.collapsed.has(n.id);
      const kids = [];
      for (const c of n.children) kids.push(...walk(c, depth + 1, n.kind === "note" || n.kind === "tag" ? n.label : ctx));
      if (!self && !kids.length) return [];
      const me = { node: n, depth, pick: self, hasKids: n.children.length > 0 && !(this.filter === "notes" && n.kind === "note") && n.kind !== "section" };
      return [me, ...(open || n.kind === "section" ? kids : [])];
    };
    for (const r of this.roots) out.push(...walk(r, -1, ""));
    return out;
  }

  onOpen() {
    this.modalEl.addClass("vault-ask-picker");
    const { contentEl } = this;
    this.input = contentEl.createEl("input", { cls: "vault-ask-picker-search", attr: { type: "text", placeholder: "Search notes, headings and tags…" } });
    this.chips = contentEl.createDiv({ cls: "vault-ask-picker-chips" });
    this.list = contentEl.createDiv({ cls: "vault-ask-picker-list" });
    const hint = contentEl.createDiv({ cls: "vault-ask-picker-hint" });
    hint.setText(this.editor.getSelection() ? "↵ link the selected text   ← → open / close   Tab filter   Esc cancel" : "↵ insert link   ← → open / close   Tab filter   Esc cancel");
    this.input.addEventListener("input", () => { this.query = this.input.value.trim().replace(/^#/, ""); if (this.input.value.trim().startsWith("#")) this.setFilter("tags", true); this.cursor = -1; this.render(); });
    this.input.addEventListener("keydown", (e) => this.key(e));
    this.renderChips(); this.render();
    setTimeout(() => this.input.focus(), 0);
  }
  onClose() { this.contentEl.empty(); }

  setFilter(id, keepQuery) {
    this.filter = id; this.cursor = -1;
    if (!keepQuery) { this.query = ""; this.input.value = ""; }
    this.renderChips(); this.render();
  }
  renderChips() {
    this.chips.empty();
    for (const f of PICK_FILTERS) {
      const c = this.chips.createEl("button", { text: f.label, cls: "vault-ask-chip" + (f.id === this.filter ? " is-active" : "") });
      c.onclick = () => { this.setFilter(f.id, true); this.input.focus(); };
    }
  }

  render() {
    this.view = this.rows();
    const picks = this.view.map((r, i) => r.pick ? i : -1).filter((i) => i >= 0);
    if (this.cursor < 0 || !this.view[this.cursor]) this.cursor = picks.length ? picks[0] : 0;
    this.list.empty();
    if (!this.view.some((r) => r.pick)) { this.list.createDiv({ cls: "vault-ask-picker-empty", text: "Nothing matches." }); return; }
    this.view.forEach((r, i) => {
      const n = r.node;
      if (n.kind === "section") { if (this.filter === "all") this.list.createDiv({ cls: "vault-ask-picker-section", text: n.label }); return; }
      const el = this.list.createDiv({ cls: `vault-ask-picker-row is-${n.kind}` + (r.pick ? "" : " is-context") + (i === this.cursor ? " is-selected" : "") });
      el.style.paddingLeft = 8 + r.depth * 18 + "px";
      const tw = el.createDiv({ cls: "vault-ask-picker-twisty" });
      if (r.hasKids) setIcon(tw, this.query || !this.collapsed.has(n.id) ? "chevron-down" : "chevron-right");
      const ic = el.createDiv({ cls: "vault-ask-picker-icon" });
      setIcon(ic, { folder: "folder", note: "file-text", heading: "heading-2", tag: "hash", tagnote: "file-text" }[n.kind]);
      const body = el.createDiv({ cls: "vault-ask-picker-body" });
      const t = body.createDiv({ cls: "vault-ask-picker-label" });
      if (n.kind === "tag") t.createSpan({ text: n.label, cls: "vault-ask-pick-tag" });
      else if (n.kind === "tagnote") { t.createSpan({ text: "only in " }); t.createSpan({ text: n.label, cls: "vault-ask-picker-strong" }); }
      else t.setText(n.label);
      if (n.row) t.createSpan({ text: "this row", cls: "vault-ask-picker-badge" });
      if (n.kind === "tag") body.createDiv({ cls: "vault-ask-picker-detail", text: (n.children.length ? "everywhere: " : "") + n.detail });
      if (n.kind === "tagnote") body.createDiv({ cls: "vault-ask-picker-detail", text: n.detail });
      if (r.pick) el.createDiv({ cls: "vault-ask-picker-action", text: "↵" });
      el.onmouseenter = () => { if (this.cursor !== i) { this.cursor = i; this.paintCursor(); } };
      el.onclick = (e) => {
        if (r.hasKids && (!r.pick || e.target.closest(".vault-ask-picker-twisty"))) { this.toggle(n); return; }
        if (r.pick) this.choose(n);
      };
    });
    this.paintCursor();
  }
  paintCursor() {
    const els = this.list.querySelectorAll(".vault-ask-picker-row, .vault-ask-picker-section");
    let k = 0;
    this.view.forEach((r, i) => {
      if (r.node.kind === "section" && this.filter !== "all") return;
      const el = els[k++]; if (!el) return;
      el.toggleClass("is-selected", i === this.cursor);
      if (i === this.cursor) el.scrollIntoView({ block: "nearest" });
    });
  }
  toggle(n) { if (this.query) return; this.collapsed.has(n.id) ? this.collapsed.delete(n.id) : this.collapsed.add(n.id); this.render(); }
  key(e) {
    const moveable = this.view.map((r, i) => r.node.kind !== "section" ? i : -1).filter((i) => i >= 0);
    const at = moveable.indexOf(this.cursor);
    const r = this.view[this.cursor];
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      const next = moveable[Math.max(0, Math.min(moveable.length - 1, at + (e.key === "ArrowDown" ? 1 : -1)))];
      if (next !== undefined) { this.cursor = next; this.paintCursor(); }
    } else if ((e.key === "ArrowRight" || e.key === "ArrowLeft") && r && r.hasKids && !this.query) {
      const closed = this.collapsed.has(r.node.id);
      if ((e.key === "ArrowRight") === closed) { e.preventDefault(); this.toggle(r.node); }
    } else if (e.key === "Tab") {
      e.preventDefault();
      const i = PICK_FILTERS.findIndex((f) => f.id === this.filter);
      this.setFilter(PICK_FILTERS[(i + (e.shiftKey ? PICK_FILTERS.length - 1 : 1)) % PICK_FILTERS.length].id, true);
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (!r) return;
      if (r.pick) this.choose(r.node); else if (r.hasKids) this.toggle(r.node);
    }
  }

  choose(n) {
    this.close();
    const selected = this.editor.getSelection();
    if (n.kind === "tag" || n.kind === "tagnote") {
      const block = tagBlock(this.app, n.tag, n.scope ? n.scope.path : null, this.sourcePath, this.inTable);
      this.editor.replaceSelection(selected ? `${selected} · ${block}` : block);
      return;
    }
    let link = this.app.fileManager.generateMarkdownLink(n.file, this.sourcePath, n.heading ? "#" + n.heading : "", selected || undefined);
    if (this.inTable) link = link.replace(/(?<!\\)\|/g, "\\|");
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
    this.registerView(GRAPH_VIEW, (leaf) => new HeadingGraphView(leaf, this));
    this.addRibbonIcon("network", "Heading graph", () => this.openGraph());
    this.addCommand({ id: "open-heading-graph", name: "Open heading graph", callback: () => this.openGraph() });
    this.addRibbonIcon("bot", "Ask the Vault (local AI side chat)", () => this.openChat());
    this.addCommand({ id: "open-chat", name: "Open side chat", callback: () => this.openChat() });
    // A distinct red button in the status bar.
    const bar = this.addStatusBarItem();
    bar.addClass("vault-ask-statusbar", "mod-clickable");
    bar.setAttribute("aria-label", "Ask the Vault (local AI side chat)");
    bar.createSpan({ text: "Ask vault" });
    bar.onClickEvent(() => this.openChat());
    this.addSettingTab(new VaultAskSettings(this.app, this));

    // Auto-link: turn plain mentions of other notes / H2 headings into links.
    this.addCommand({ id: "auto-link", name: "Auto-link mentions in this note", icon: "link-2",
      editorCallback: (editor, view) => view.file && autoLinkEditor(this, editor, view.file) });
    this.addCommand({ id: "auto-link-vault", name: "Auto-link the whole vault…", icon: "link-2",
      callback: () => new VaultAutoLinkModal(this).open() });
    this.addCommand({ id: "auto-link-vault-undo", name: "Undo the last vault auto-link",
      checkCallback: (check) => { if (!this.lastVaultAutoLink) return false; if (!check) this.undoVaultAutoLink(); return true; } });
    const linkBar = this.addStatusBarItem();
    linkBar.addClass("vault-ask-statusbar", "vault-ask-autolink", "mod-clickable");
    linkBar.setAttribute("aria-label", "Auto-link mentions of notes and headings across the whole vault");
    linkBar.createSpan({ text: "Auto-link" });
    linkBar.onClickEvent(() => new VaultAutoLinkModal(this).open());

    // Keep live tag-link blocks up to date as tags move between headings.
    const refreshAll = async () => {
      for (const f of this.app.vault.getMarkdownFiles()) {
        const text = await this.app.vault.cachedRead(f);
        if (!text.includes("%%tag:")) continue;
        if (refreshTagBlocks(this.app, text, f.path) !== text)
          await this.app.vault.process(f, (d) => refreshTagBlocks(this.app, d, f.path));
      }
    };
    let tagTimer = null;
    const scheduleTags = () => { clearTimeout(tagTimer); tagTimer = setTimeout(refreshAll, 800); };
    this.registerEvent(this.app.metadataCache.on("changed", scheduleTags));
    this.registerEvent(this.app.vault.on("rename", scheduleTags));
    this.registerEvent(this.app.vault.on("delete", scheduleTags));
    this.app.workspace.onLayoutReady(scheduleTags);

    // Link the selected text to a note or to an H2 heading in a note.
    const pick = (editor, view) => new LinkPicker(this.app, editor, view.file ? view.file.path : "").open();
    this.addCommand({ id: "link-selection", name: "Link selection to note or heading…", icon: "link",
      hotkeys: [{ modifiers: ["Mod", "Shift"], key: "l" }], editorCallback: pick });
    // Expand the selected text in place (the AI asks clarifying questions first).
    const expand = (editor, view) => {
      if (!editor.getSelection().trim()) { new Notice("Select the text you want to expand first."); return; }
      if (view.file) new ExpandModal(this, editor, view.file).open();
    };
    this.addCommand({ id: "expand-selection", name: "Expand selection with AI…", icon: "wand-2",
      hotkeys: [{ modifiers: ["Mod", "Shift"], key: "e" }], editorCallback: expand });
    this.registerEvent(this.app.workspace.on("editor-menu", (menu, editor, view) => {
      const sel = !!editor.getSelection().trim();
      menu.addItem((item) => item.setTitle(sel ? "Link selection to…" : "Insert link to note or heading…").setIcon("link").onClick(() => pick(editor, view)));
      if (sel) menu.addItem((item) => item.setTitle("Expand with AI…").setIcon("wand-2").onClick(() => expand(editor, view)));
    }));
  }

  async openGraph() {
    let leaf = this.app.workspace.getLeavesOfType(GRAPH_VIEW)[0];
    if (!leaf) { leaf = this.app.workspace.getLeaf("tab"); await leaf.setViewState({ type: GRAPH_VIEW, active: true }); }
    await this.app.workspace.revealLeaf(leaf);
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

  async undoVaultAutoLink() {
    const undo = this.lastVaultAutoLink; if (!undo) return;
    this.lastVaultAutoLink = null;
    let n = 0;
    for (const [path, text] of Object.entries(undo)) {
      const f = this.app.vault.getAbstractFileByPath(path);
      if (f instanceof TFile) { await this.app.vault.modify(f, text); n++; }
    }
    new Notice(`Auto-link undone in ${n} note${n === 1 ? "" : "s"}.`);
  }
  async save() { await this.saveData({ settings: this.settings, index: this.index, chats: this.chats }); }
};

// Exposed for tests (not used by Obsidian).
module.exports.VaultAsk = VaultAsk;
module.exports.chunkText = chunkText;
module.exports.LinkPicker = LinkPicker;
module.exports.tagTargets = tagTargets;
module.exports.refreshTagBlocks = refreshTagBlocks;
module.exports.tagBlock = tagBlock;
module.exports.findAutoLinks = findAutoLinks;
module.exports.autoLinkText = autoLinkText;
module.exports.buildHeadingGraph = buildHeadingGraph;
