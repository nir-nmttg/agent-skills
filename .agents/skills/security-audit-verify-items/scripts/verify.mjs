#!/usr/bin/env node
// security-audit-verify-items の定型処理。集約 Issue の本文を読み、番号・決まった語・SHA・数だけを出す（項目の中身は出さない）。
// mark だけは書き込む本文を出すので、呼び出し側はファイルに書いて読まない。
// Claude Code 版（.claude/skills/security-audit-verify-items/scripts/verify.sh）からも共有して使うので、変えるときは両方の SKILL.md と合わせる。
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const MAX_CHARS = 60000;
const LOCK_STALE_MS = 3 * 60 * 60 * 1000;
const SECTIONS = { 確定: "confirmed", 要検証: "needs_validation", 未検証: "unverified", 棄却: "rejected", "未完了の工程・範囲": "incomplete" };
const REQUIRED = ["確定", "要検証", "未検証", "棄却"];
const BUSY_STAGES = ["starting", "auditing", "self_auditing"];
const SKIP_RESULTS = ["undetermined", "held"];
// 要検証の「判定に必要な確認」のうち、手元では確かめられず人が確かめる語。列がこれだけの項目は調べ直さない
const MANUAL_CHECKS = ["仕様確認", "環境・権限の確認"];
const TITLE = /^\[(\d{4}-\d{2}-\d{2})\] セキュリティ監査の調査・判定一覧$/;
const SHA = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/;
const ITEM_ID = /^A\d{2,}$/;
const MARKER = /^<!-- security-audit-verify:(\S+) sha=(\S+) result=([a-z]+)(?: stops=(\d+))? -->$/;
const MARKER_LIKE = /security-audit-verify:/;
const RECHECK_BULLET = /^- \*\*調べ直し\*\*:/;

class UsageError extends Error {}
class StructureError extends Error {}

function fail(message) {
  throw new UsageError(message);
}

function broken(reason) {
  throw new StructureError(reason);
}

function chars(text) {
  return [...text].length;
}

function lines(text) {
  return text.replace(/\r\n/g, "\n").split("\n");
}

function readStdinJson() {
  let raw;
  try {
    raw = fs.readFileSync(0, "utf8");
  } catch {
    fail("標準入力を読めません");
  }
  try {
    return JSON.parse(raw);
  } catch {
    fail("標準入力が JSON ではありません");
  }
}

function issueBody(json, { requireOpen = true } = {}) {
  if (!json || typeof json.body !== "string") fail("Issue の JSON に body がありません（gh issue view --json body,state を渡してください）");
  if (requireOpen && json.state !== undefined && json.state !== "OPEN") broken("issue_not_open");
  return json.body;
}

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    fail(`ファイルを読めません: ${file}`);
  }
}

// 集約 Issue の本文を、区画の外・区画のマーカー・区分・項目（一覧表の行と詳細）に分ける。
export function parse(text) {
  const ls = lines(text);
  const begins = ls.flatMap((l, i) => (l.trim() === "<!-- security-audit:summary-begin -->" ? [i] : []));
  const ends = ls.flatMap((l, i) => (l.trim() === "<!-- security-audit:summary-end -->" ? [i] : []));
  if (begins.length !== 1 || ends.length !== 1 || begins[0] > ends[0]) broken("summary_block");
  const [b, e] = [begins[0], ends[0]];
  const block = ls.slice(b + 1, e);
  const outside = [...ls.slice(0, b + 1), "\0", ...ls.slice(e)].join("\n");
  // 監査用のマーカー（summary-*・source-sha など）。調べ直しの印（security-audit-verify:）は含まない
  const auditMarkers = block.filter((l) => l.startsWith("<!-- security-audit:"));
  const ids = block.flatMap((l) => {
    const m = /^<!-- security-audit:summary-id=(.+) -->$/.exec(l.trim());
    return m ? [m[1]] : [];
  });
  if (ids.length !== 1 || !/^[0-9A-Za-z][0-9A-Za-z._-]{0,127}$/.test(ids[0])) broken("summary_id");

  const sections = {};
  const items = new Map();
  // 区画の中で、区分の見出しと項目の行・詳細のほかの行。書き込みの前後で変わらないことを確かめる（冒頭は件数が変わるので数字を伏せる）
  const rest = [];
  let seenHeading = false;
  let current = null;
  let openDetails = null;
  let detailsOpen = 0;
  let detailsClose = 0;
  for (let i = 0; i < block.length; i++) {
    const line = block[i];
    if (line.startsWith("## ")) {
      if (openDetails) broken("details_unclosed");
      seenHeading = true;
      const m = /^## (.+?)（(.*)）\s*$/.exec(line);
      const name = m && Object.hasOwn(SECTIONS, m[1]) ? m[1] : null;
      if (name) {
        if (sections[name]) broken(`section_duplicate:${SECTIONS[name]}`);
        const count = /^(\d+)件$/.exec(m[2]);
        sections[name] = { heading: line, count: count ? Number(count[1]) : null, rows: [], details: [] };
        current = name;
      } else {
        current = null;
        rest.push(line);
      }
      continue;
    }
    if (/^<details>/.test(line)) detailsOpen++;
    if (/<\/details>\s*$/.test(line)) detailsClose++;
    const row = current && !openDetails ? /^\|\s*([AU]\d+)\s*\|/.exec(line) : null;
    if (row) {
      sections[current].rows.push(row[1]);
      itemOf(items, row[1]).rows.push({ section: current, line });
      continue;
    }
    const open = current && !openDetails ? /^<details><summary><b>([AU]\d+)<\/b>/.exec(line) : null;
    if (open) openDetails = { id: open[1], start: i, section: current };
    if (openDetails) {
      if (/<\/details>\s*$/.test(line)) {
        const body = block.slice(openDetails.start, i + 1);
        sections[current].details.push(openDetails.id);
        itemOf(items, openDetails.id).details.push({ section: current, lines: body, start: b + 1 + openDetails.start });
        openDetails = null;
      }
      continue;
    }
    if (line.trim() === "" || line.startsWith("<!-- security-audit:")) continue;
    if (!seenHeading) {
      rest.push(line.replace(/\d+/g, "#"));
      continue;
    }
    if (current && /^\|\s*No\./.test(line)) sections[current].header = line;
    // 区分が空になる・空でなくなるときに増減する行（「0件。」・一覧表の見出しと区切り）は比べない
    if (line.trim() === "0件。" || /^\|\s*(No\.|-{3,})/.test(line)) continue;
    rest.push(line);
  }
  if (openDetails) broken("details_unclosed");
  if (detailsOpen !== detailsClose) broken("details_count");
  for (const name of REQUIRED) if (!sections[name]) broken(`section_missing:${SECTIONS[name]}`);
  for (const [name, s] of Object.entries(sections)) {
    if (s.rows.length !== s.details.length) broken(`count_mismatch:${SECTIONS[name]}`);
    if (s.count !== null && s.count !== s.rows.length) broken(`count_mismatch:${SECTIONS[name]}`);
  }
  for (const [id, it] of items) {
    if (it.rows.length !== 1 || it.details.length !== 1) broken(`item_duplicate_or_missing:${id}`);
    if (it.rows[0].section !== it.details[0].section) broken(`item_section_mismatch:${id}`);
    it.section = it.rows[0].section;
    it.row = it.rows[0].line;
    it.detail = it.details[0].lines;
    it.start = it.details[0].start;
    it.marker = markerOf(id, it.detail);
  }
  return { outside, auditMarkers, rest, sections, items, chars: chars(text) };
}

function itemOf(items, id) {
  if (!items.has(id)) items.set(id, { rows: [], details: [] });
  return items.get(id);
}

function markerOf(id, detail) {
  const found = detail.filter((l) => MARKER_LIKE.test(l));
  if (found.length === 0) return null;
  if (found.length > 1) broken(`marker_duplicate:${id}`);
  const m = MARKER.exec(found[0].trim());
  if (!m || m[1] !== id || !SHA.test(m[2])) broken(`marker_invalid:${id}`);
  return { sha: m[2], result: m[3], stops: m[4] ? Number(m[4]) : 0 };
}

function shaArg(sha) {
  if (!sha || !SHA.test(sha)) fail("VERIFY_SHA は完全なコミット SHA で指定してください");
  return sha;
}

function idArg(id) {
  if (!id || !ITEM_ID.test(id)) fail("番号は A03 の形で指定してください");
  return id;
}

function skipped(marker, sha) {
  if (!marker || marker.sha !== sha) return false;
  if (SKIP_RESULTS.includes(marker.result)) return true;
  return marker.result === "stopped" && marker.stops >= 2;
}

function cells(row) {
  return row.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
}

// 要検証の一覧表の行の「判定に必要な確認」が、人が確かめる語だけか。
// 見出しの最後の列がその列で、行の列数が見出しと同じときだけ読む。
// 列がない・列数が違う・列が空・語が書式にない・ほかの語を含むときは、取りこぼさないよう調べ直す側に倒す
function manual(row, header) {
  const head = header ? cells(header) : [];
  const cols = cells(row);
  if (head[head.length - 1] !== "判定に必要な確認" || cols.length !== head.length) return false;
  return cols[cols.length - 1].split("、").every((w) => MANUAL_CHECKS.includes(w.trim()));
}

function cmdPick() {
  const list = readStdinJson();
  if (!Array.isArray(list)) fail("Issue の一覧の JSON 配列を渡してください");
  const candidates = list
    .filter((x) => x && x.state !== "CLOSED" && typeof x.title === "string" && TITLE.test(x.title))
    .filter((x) => typeof x.body === "string" && /<!-- security-audit:summary-id=.+ -->/.test(x.body))
    .map((x) => ({ number: x.number, date: TITLE.exec(x.title)[1], createdAt: String(x.createdAt ?? ""), author: x.author?.login ?? "unknown" }))
    .sort((a, b) => b.date.localeCompare(a.date) || b.createdAt.localeCompare(a.createdAt));
  if (candidates.length === 0) broken("no_summary_issue");
  return `${candidates[0].number} ${candidates[0].author}`;
}

function cmdItems(args) {
  const sha = shaArg(args[0]);
  const p = parse(issueBody(readStdinJson()));
  const out = [`chars ${p.chars}`];
  const { rows, header } = p.sections["要検証"];
  for (const id of rows) {
    if (!ITEM_ID.test(id)) broken(`item_id:${id}`);
    const it = p.items.get(id);
    out.push(`${id} ${manual(it.row, header) ? "manual" : skipped(it.marker, sha) ? "skip" : "todo"}`);
  }
  return out.join("\n");
}

function cmdStatus(args) {
  const id = idArg(args[0]);
  const p = parse(issueBody(readStdinJson(), { requireOpen: false }));
  const it = p.items.get(id);
  if (!it) broken(`item_not_found:${id}`);
  const m = it.marker;
  return `${SECTIONS[it.section]} ${m ? m.sha : "none"} ${m ? m.result : "none"}${m?.stops ? ` stops=${m.stops}` : ""}`;
}

// 書き込む前の確認。対象の項目・件数・調べ直しの印のほかが変わっていないこと。
export function check(id, beforeText, afterText) {
  const reasons = [];
  let before;
  let after;
  try {
    before = parse(beforeText);
  } catch (error) {
    if (error instanceof StructureError) return [`before:${error.message}`];
    throw error;
  }
  try {
    after = parse(afterText);
  } catch (error) {
    if (error instanceof StructureError) return [`after:${error.message}`];
    throw error;
  }
  if (before.outside !== after.outside) reasons.push("outside_changed");
  if (before.auditMarkers.join("\n") !== after.auditMarkers.join("\n")) reasons.push("audit_marker_changed");
  if (before.rest.join("\n") !== after.rest.join("\n")) reasons.push("other_text_changed");
  if (!before.items.has(id)) reasons.push(`target_not_in_before:${id}`);
  if (!after.items.has(id)) reasons.push(`target_not_in_after:${id}`);
  for (const [other, it] of before.items) {
    if (other === id) continue;
    const a = after.items.get(other);
    if (!a) {
      reasons.push(`item_removed:${other}`);
      continue;
    }
    if (a.section !== it.section || a.row !== it.row || a.detail.join("\n") !== it.detail.join("\n")) reasons.push(`item_changed:${other}`);
  }
  for (const other of after.items.keys()) if (!before.items.has(other)) reasons.push(`item_added:${other}`);
  if (after.chars > MAX_CHARS) reasons.push(`too_long:${after.chars}`);
  return reasons;
}

function cmdCheck(args) {
  const id = idArg(args[0]);
  if (!args[1] || !args[2]) fail("使い方: verify.mjs check <番号> <前の本文のファイル> <後の本文のファイル>");
  const reasons = check(id, readText(args[1]), readText(args[2]));
  if (reasons.length) {
    process.exitCode = 1;
    return reasons.join("\n");
  }
  return "ok";
}

// 停止した項目の詳細に、調べ直しの箇条と印を置いた本文を返す。
export function mark(text, id, sha, date) {
  const p = parse(text);
  const it = p.items.get(id);
  if (!it) broken(`item_not_found:${id}`);
  if (it.section !== "要検証") broken(`item_not_needs_validation:${id}`);
  const stops = it.marker && it.marker.sha === sha && it.marker.result === "stopped" ? it.marker.stops + 1 : 1;
  const kept = it.detail.filter((l) => !RECHECK_BULLET.test(l) && !MARKER_LIKE.test(l));
  const added = [`- **調べ直し**: ${date}、${sha.slice(0, 7)} で調べ始めたが途中で止まった（${stops} 回目）。`, `<!-- security-audit-verify:${id} sha=${sha} result=stopped stops=${stops} -->`];
  let at = kept.findIndex((l) => /^- \*\*ID\*\*:/.test(l));
  if (at < 0) at = kept.length - 1;
  const detail = [...kept.slice(0, at), ...added, ...kept.slice(at)];
  const ls = lines(text);
  ls.splice(it.start, it.detail.length, ...detail);
  return ls.join("\n");
}

function cmdMark(args) {
  const id = idArg(args[0]);
  const sha = shaArg(args[1]);
  const date = args[2];
  if (!date || !/^\d{4}-\d{2}-\d{2}$/.test(date)) fail("日付は yyyy-mm-dd で指定してください");
  return mark(issueBody(readStdinJson()), id, sha, date);
}

function dirArg(arg) {
  if (!arg || !path.isAbsolute(arg)) fail("フォルダは絶対パスで指定してください");
  return path.resolve(arg);
}

// 同じリポジトリの監査（security-audit-sync-issues）の最新の実行が終わっていないか。
// 古い実行が止まったまま残っていても、新しい実行が始まっていればそれは書き込んでいないので見ない。
function cmdBusy(args) {
  const dir = dirArg(args[0]);
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (error) {
    if (error.code === "ENOENT") return "free";
    fail(`フォルダを読めません: ${dir}`);
  }
  const runs = entries
    .filter((e) => e.isDirectory() && /^run-\d+$/.test(e.name))
    .map((e) => e.name)
    .sort((a, b) => Number(b.slice(4)) - Number(a.slice(4)));
  if (runs.length === 0) return "free";
  let stage;
  try {
    stage = JSON.parse(fs.readFileSync(path.join(dir, runs[0], "supervisor.json"), "utf8")).stage;
  } catch (error) {
    stage = error.code === "ENOENT" ? "missing" : "unreadable";
  }
  return BUSY_STAGES.includes(stage) || stage === "unreadable" ? `busy ${runs[0]}:${stage}` : "free";
}

// verify-items どうしの排他。acquire が返す持ち主の印を touch・release に渡す。
// Codex 版は Supervisor が待つあいだも、Claude Code 版は Verifier が書き込む前に touch する。3 時間更新のないロックは 1 つの実行だけが引き継ぐ。
function cmdLock(args) {
  const dir = dirArg(args[0]);
  const lock = path.join(dir, "lock");
  const takeover = path.join(dir, "lock.takeover");
  const ownerFile = path.join(lock, "owner");
  const heartbeat = path.join(lock, "heartbeat");
  const beat = () => fs.writeFileSync(heartbeat, `${new Date().toISOString()}\n`);
  const create = () => {
    fs.mkdirSync(lock);
    const token = randomUUID();
    fs.writeFileSync(ownerFile, `${token}\n`);
    beat();
    return token;
  };
  const stale = () => {
    for (const file of [heartbeat, lock]) {
      try {
        return Date.now() - fs.statSync(file).mtimeMs >= LOCK_STALE_MS;
      } catch {
        // 次のファイルで確かめる
      }
    }
    return true;
  };
  const owner = () => {
    try {
      return fs.readFileSync(ownerFile, "utf8").trim();
    } catch {
      return null;
    }
  };
  const locked = () => {
    process.exitCode = 2;
    return `locked ${lock}`;
  };
  const tokenArg = () => {
    if (!args[2] || !/^[0-9a-f-]{36}$/.test(args[2])) fail("acquire が返した持ち主の印を渡してください");
    return args[2];
  };
  switch (args[1]) {
    case "acquire": {
      fs.mkdirSync(dir, { recursive: true });
      try {
        return `acquired ${create()}`;
      } catch (error) {
        if (error.code !== "EEXIST") fail(`ロックを作れません: ${lock}`);
      }
      if (!stale()) return locked();
      try {
        fs.mkdirSync(takeover);
      } catch {
        return locked();
      }
      try {
        // 引き継ぎの印を取ったあとで確かめ直す（ほかの実行が先に引き継いでいれば新しい）
        if (!stale()) return locked();
        fs.rmSync(lock, { recursive: true, force: true });
        return `acquired ${create()} stale`;
      } finally {
        fs.rmSync(takeover, { recursive: true, force: true });
      }
    }
    case "touch": {
      const token = tokenArg();
      if (owner() !== token) {
        process.exitCode = 2;
        return "not_owner";
      }
      beat();
      return "touched";
    }
    case "release": {
      const token = tokenArg();
      if (!fs.existsSync(lock)) return "released";
      if (owner() !== token) {
        process.exitCode = 2;
        return "not_owner";
      }
      fs.rmSync(lock, { recursive: true, force: true });
      return "released";
    }
    default:
      fail("使い方: verify.mjs lock <フォルダ> <acquire|touch <印>|release <印>>");
  }
}

const COMMANDS = { pick: cmdPick, items: cmdItems, status: cmdStatus, check: cmdCheck, mark: cmdMark, busy: cmdBusy, lock: cmdLock };

export function main(argv) {
  const [command, ...args] = argv;
  const fn = COMMANDS[command];
  if (!fn) fail(`使い方: verify.mjs <${Object.keys(COMMANDS).join("|")}> [...]`);
  return fn(args);
}

if (process.argv[1]?.endsWith("/verify.mjs")) {
  try {
    process.stdout.write(`${main(process.argv.slice(2))}\n`);
  } catch (error) {
    if (error instanceof StructureError) {
      process.stdout.write(`${error.message}\n`);
      process.exit(2);
    }
    process.stderr.write(`verify.mjs: ${error instanceof UsageError ? error.message : "予期しないエラー"}\n`);
    process.exit(error instanceof UsageError ? 3 : 1);
  }
}
