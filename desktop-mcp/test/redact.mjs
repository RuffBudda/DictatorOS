import { test } from "node:test";
import assert from "node:assert/strict";
import { PNG } from "pngjs";
import { scrubText, secretSpans, secretBoxesFromTsv, blackout, downscale, isSensitiveWindow } from "../redact/index.js";

const MUST_HIDE = [
  "export OPENAI_API_KEY=sk-proj-AbC123xyzDEF456ghiJKL789mnoPQR",
  "ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789",
  "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE",
  "token ghp_1234567890abcdefghijABCDEFGHIJ123456",
  "password: hunter2-Summer!",
  "Password = correct horse battery staple",
  "DB_PASS=s3cr3t",
  "Authorization: Bearer abc.def.ghi",
  "postgres://admin:Sup3rS3cret@db.internal:5432/app",
  "https://example.com/cb?code=4/0AY0e-g7abcdefXYZ&state=1",
  "-----BEGIN OPENSSH PRIVATE KEY-----",
  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
  "xoxb-1234567890-abcdefghij",
  "random R7f9Kq2LmZ8xW4tP1vB6nC3hJ5dG0sYe here",
];
const MUST_KEEP = [
  "Hello world, this is a normal sentence.",
  "Forgot your password?",
  "Enter your password",
  "password: ********",
  "/home/user/dotfiles/desktop-mcp/node_modules/pngjs",
  "https://wiki.hypr.land/Configuring/Variables/",
  "Thu 19 Nov 17:29",
];

test("credentials are scrubbed from text", () => {
  for (const line of MUST_HIDE) {
    const out = scrubText(line);
    assert.match(out, /\[REDACTED\]/, `not redacted: ${line}`);
  }
  assert.equal(scrubText("password: hunter2-Summer!"), "password: [REDACTED]");
  assert.ok(!scrubText("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE").includes("AKIA"));
});

test("ordinary text is left alone", () => {
  for (const line of MUST_KEEP) assert.deepEqual(secretSpans(line), [], `false positive: ${line}`);
});

test("TSV → boxes only over the secret words", () => {
  const hdr = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext";
  const row = (word, l, text) => `5\t1\t1\t1\t1\t${word}\t${l}\t10\t50\t12\t95\t${text}`;
  const tsv = [hdr, row(1, 0, "password:"), row(2, 60, "hunter2"), row(3, 200, "ok")].join("\n");
  // "ok" sits on the same line after the secret, so it is hidden too (everything after the label).
  const boxes = secretBoxesFromTsv(tsv);
  assert.deepEqual(boxes.map((b) => b.x), [60, 200]);
  const tsv2 = [hdr, row(1, 0, "hello"), row(2, 60, "world")].join("\n");
  assert.deepEqual(secretBoxesFromTsv(tsv2), []);
});

test("blackout paints the box and downscale shrinks", () => {
  const img = new PNG({ width: 40, height: 20 });
  img.data.fill(255);
  const out = PNG.sync.read(blackout(PNG.sync.write(img), [{ x: 10, y: 5, width: 5, height: 5 }], 0));
  const px = (x, y) => out.data[(y * 40 + x) * 4];
  assert.ok(px(12, 7) < 100, "box not painted");
  assert.equal(px(0, 0), 255, "outside box changed");
  const small = PNG.sync.read(downscale(PNG.sync.write(out), 20, 10));
  assert.equal(small.width, 20);
  assert.equal(small.height, 10);
});

test("sensitive windows", () => {
  assert.ok(isSensitiveWindow({ class: "org.keepassxc.KeePassXC", title: "db" }));
  assert.ok(isSensitiveWindow({ class: "Bitwarden", title: "Vault" }));
  assert.ok(isSensitiveWindow({ class: "gcr-prompter", title: "Unlock Keyring" }));
  assert.ok(isSensitiveWindow({ class: "foot", title: "Enter passphrase for key" }));
  assert.ok(!isSensitiveWindow({ class: "chromium", title: "Google - Chromium" }));
  assert.ok(!isSensitiveWindow({ class: "foot", title: "~/Projects" }));
});
