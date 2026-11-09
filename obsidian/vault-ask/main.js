// Ask the Vault (DictatorOS): ask questions answered only from this vault,
// using local models through Ollama. Nothing leaves the machine.
//
// How it works: notes are split into chunks and embedded with an embedding
// model (cached in this plugin's data.json, refreshed when a note changes).
// A question is embedded too; the closest chunks are given to the chat model
// with instructions to answer only from them and to cite the notes it used.
const { Plugin, Modal, Notice, MarkdownRenderer, PluginSettingTab, Setting, requestUrl, Component } = require("obsidian");

const DEFAULTS = {
  ollamaUrl: "http://127.0.0.1:11434",
  chatModel: "qwen3:8b",
  embedModel: "nomic-embed-text",
  topK: 6,
  minScore: 0.35,
};
const CHUNK_CHARS = 1200;   // target chunk size
const EMBED_BATCH = 32;     // chunks per embedding request

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

  async post(path, body) {
    let res;
    try {
      res = await requestUrl({ url: this.s.ollamaUrl.replace(/\/$/, "") + path, method: "POST",
        contentType: "application/json", body: JSON.stringify(body), throw: false });
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
    const index = this.plugin.index;               // { [path]: { mtime, chunks: [{ text, vec }] } }
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

  async answer(question, hits) {
    const notes = hits.map((h) => `Note [[${h.path.replace(/\.md$/, "")}]]:\n${h.text}`).join("\n\n---\n\n");
    const system =
      "You answer questions using ONLY the notes provided from the user's Obsidian vault. " +
      "Do not use outside knowledge. If the notes do not contain the answer, reply exactly: " +
      "\"I couldn't find that in your vault.\" Be concise. When you use a note, cite it exactly as it is labelled, e.g. [[Folder/Note name]].";
    const r = await this.post("/api/chat", {
      model: this.s.chatModel, stream: false, think: false,
      options: { temperature: 0.2 },
      messages: [
        { role: "system", content: system },
        { role: "user", content: `Notes:\n\n${notes}\n\nQuestion: ${question}` },
      ],
    });
    return (r.message && r.message.content || "").replace(/<think>[\s\S]*?<\/think>/g, "").trim();
  }
}

class AskModal extends Modal {
  constructor(plugin) { super(plugin.app); this.plugin = plugin; this.ask = new VaultAsk(plugin); }

  onOpen() {
    const { contentEl } = this;
    this.modalEl.addClass("vault-ask-modal");
    contentEl.createEl("h3", { text: "Ask the vault" });
    const input = contentEl.createEl("textarea", { cls: "vault-ask-input", attr: { rows: "3", placeholder: "Ask something your notes can answer…" } });
    const btn = contentEl.createEl("button", { text: "Ask", cls: "mod-cta vault-ask-button" });
    this.status = contentEl.createDiv({ cls: "vault-ask-status" });
    this.out = contentEl.createDiv({ cls: "vault-ask-answer markdown-rendered" });
    this.sources = contentEl.createDiv({ cls: "vault-ask-sources" });
    const go = () => this.run(input.value.trim(), btn);
    btn.onclick = go;
    input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); go(); } });
    setTimeout(() => input.focus(), 0);
  }

  async run(question, btn) {
    if (!question) return;
    btn.disabled = true;
    this.out.empty(); this.sources.empty();
    try {
      this.status.setText("Indexing notes…");
      await this.ask.refreshIndex((d, n) => this.status.setText(`Indexing notes… ${d}/${n}`));
      this.status.setText("Searching your notes…");
      const hits = await this.ask.search(question);
      if (!hits.length) { this.status.setText(""); this.out.setText("I couldn't find anything relevant in your vault."); return; }
      this.status.setText("Thinking (local model)…");
      const md = await this.ask.answer(question, hits);
      this.status.setText("");
      const comp = new Component(); comp.load();
      await MarkdownRenderer.render(this.app, md, this.out, "", comp);
      this.out.querySelectorAll("a.internal-link").forEach((a) => a.addEventListener("click", (e) => {
        e.preventDefault(); this.app.workspace.openLinkText(a.getAttribute("data-href") || a.textContent, "", false); this.close();
      }));
      this.sources.createEl("div", { text: "Notes searched:", cls: "vault-ask-sources-title" });
      const seen = new Set();
      for (const h of hits) {
        if (seen.has(h.path)) continue; seen.add(h.path);
        const a = this.sources.createEl("a", { text: h.path.replace(/\.md$/, ""), cls: "vault-ask-source", href: "#" });
        a.onclick = (e) => { e.preventDefault(); this.app.workspace.openLinkText(h.path, "", false); this.close(); };
      }
    } catch (e) {
      this.status.setText("");
      this.out.setText("Error: " + e.message);
    } finally {
      btn.disabled = false;
    }
  }

  onClose() { this.contentEl.empty(); }
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
    this.addRibbonIcon("bot", "Ask the vault (local AI)", () => new AskModal(this).open());
    // A labelled button in the status bar too, so it's easy to find.
    const bar = this.addStatusBarItem();
    bar.addClass("vault-ask-statusbar", "mod-clickable");
    bar.setAttribute("aria-label", "Ask the vault (local AI)");
    bar.createSpan({ text: "Ask vault" });
    bar.onClickEvent(() => new AskModal(this).open());
    this.addCommand({ id: "ask", name: "Ask the vault", callback: () => new AskModal(this).open() });
    this.addSettingTab(new VaultAskSettings(this.app, this));
  }
  async saveSettings() { await this.saveData({ settings: this.settings, index: this.index }); }
  async saveIndex() { await this.saveData({ settings: this.settings, index: this.index }); }
};

// Exposed for tests (not used by Obsidian).
module.exports.VaultAsk = VaultAsk;
module.exports.chunkText = chunkText;
