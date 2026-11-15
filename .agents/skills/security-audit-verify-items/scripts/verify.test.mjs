import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { check, mark, parse } from "./verify.mjs";

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), "verify.mjs");
const SHA = "a".repeat(40);
const SHA2 = "b".repeat(40);

function details(id, title, extra = []) {
  return [`<details><summary><b>${id}</b> ${title}</summary>`, "", "- **概要**: 説明。", ...extra, `- **ID**: \`fp-${id}\``, "", "</details>", ""];
}

function body({ confirmed = [], needs = ["A02", "A03"], rejected = [], extra = {}, checks = {} } = {}) {
  const section = (name, ids, header) => {
    if (ids.length === 0) return [`## ${name}（0件）`, "", "0件。", ""];
    return [
      `## ${name}（${ids.length}件）`,
      "",
      header,
      "| --- | --- | --- |",
      ...ids.map((id) => `| ${id} | 領域 | 題名${id} |${Object.hasOwn(checks, id) ? ` ${checks[id]} |` : ""}`),
      "",
      ...ids.flatMap((id) => details(id, `題名${id}`, extra[id] ?? [])),
    ];
  };
  return [
    "人の追記",
    "<!-- security-audit:summary-begin -->",
    "<!-- security-audit:summary-id=audit-1 -->",
    "<!-- security-audit:summary-revision=1 -->",
    `<!-- security-audit:source-sha=${SHA2} -->`,
    "冒頭の説明。確定 0 件。",
    "",
    ...section("確定", confirmed, "| No. | 影響評価 | 題名 | 対応状況 |"),
    ...section("要検証", needs, "| No. | 領域 | 題名 | 判定に必要な確認 |"),
    "## 未検証（0件）",
    "",
    "0件。",
    "",
    ...section("棄却", rejected, "| No. | 領域 | 題名 |"),
    "## 未完了の工程・範囲（0件）",
    "",
    "0件。",
    "",
    "## 調査の補足",
    "",
    "補足の文。",
    "<!-- security-audit:summary-end -->",
    "区画の後の追記",
  ].join("\n");
}

function run(args, input) {
  const r = spawnSync(process.execPath, [SCRIPT, ...args], { input: input === undefined ? "" : JSON.stringify(input), encoding: "utf8" });
  return { code: r.status, out: r.stdout.trim(), err: r.stderr.trim() };
}

const marker = (id, sha, result, stops) => `<!-- security-audit-verify:${id} sha=${sha} result=${result}${stops ? ` stops=${stops}` : ""} -->`;

test("items は要検証を表の順に出し、同じ SHA の判断できない・保留を飛ばす", () => {
  const text = body({ needs: ["A02", "A03", "A04", "A05"], extra: { A03: [marker("A03", SHA, "undetermined")], A04: [marker("A04", SHA2, "held")], A05: [marker("A05", SHA, "held")] } });
  const r = run(["items", SHA], { body: text, state: "OPEN" });
  assert.equal(r.code, 0);
  assert.deepEqual(r.out.split("\n"), [`chars ${[...text].length}`, "A02 todo", "A03 skip", "A04 todo", "A05 skip"]);
});

test("items は 1 回だけ止まった項目を調べ直し、同じ SHA で 2 回止まった項目を飛ばす", () => {
  const text = body({ needs: ["A02", "A03"], extra: { A02: [marker("A02", SHA, "stopped", 1)], A03: [marker("A03", SHA, "stopped", 2)] } });
  assert.deepEqual(run(["items", SHA], { body: text }).out.split("\n").slice(1), ["A02 todo", "A03 skip"]);
});

test("items は区画の外や別の項目の詳細にある印を見ない", () => {
  const text = body({ needs: ["A02", "A03"] }).replace("区画の後の追記", marker("A02", SHA, "held"));
  assert.deepEqual(run(["items", SHA], { body: text }).out.split("\n").slice(1), ["A02 todo", "A03 todo"]);
  const wrong = body({ needs: ["A02", "A03"], extra: { A02: [marker("A03", SHA, "held")] } });
  assert.deepEqual([run(["items", SHA], { body: wrong }).code, run(["items", SHA], { body: wrong }).out], [2, "marker_invalid:A02"]);
});

test("items は判定に必要な確認が人の確認だけの項目を manual にし、ほかは調べ直す", () => {
  const checks = {
    A02: "仕様確認",
    A03: "環境・権限の確認",
    A04: "仕様確認、環境・権限の確認",
    A05: "仕様確認、ローカル検証",
    A06: "ローカル検証",
    A07: "その他",
    A08: "",
    A09: "未知の語",
  };
  const needs = Object.keys(checks);
  // manual は同じ SHA の印より先に見る
  const text = body({ needs, checks, extra: { A02: [marker("A02", SHA, "undetermined")], A06: [marker("A06", SHA, "undetermined")] } });
  const expected = [
    "A02 manual",
    "A03 manual",
    "A04 manual",
    "A05 todo",
    "A06 skip",
    "A07 todo",
    "A08 todo",
    "A09 todo",
  ];
  assert.deepEqual(run(["items", SHA], { body: text }).out.split("\n").slice(1), expected);
  assert.deepEqual(run(["items", SHA], { body: text.replace(/\n/g, "\r\n") }).out.split("\n").slice(1), expected);
});

test("items は判定に必要な確認の列を見出しと列数で確かめられないとき調べ直す", () => {
  const out = (text) => run(["items", SHA], { body: text }).out.split("\n").slice(1);
  // 列のない行
  assert.deepEqual(out(body({ needs: ["A02"] })), ["A02 todo"]);
  // 見出しの最後の列が別の列
  const otherHeader = body({ needs: ["A02"], checks: { A02: "仕様確認" } }).replace("| No. | 領域 | 題名 | 判定に必要な確認 |", "| No. | 領域 | 題名 | 備考 |");
  assert.deepEqual(out(otherHeader), ["A02 todo"]);
  // 行のセルが見出しより多い
  assert.deepEqual(out(body({ needs: ["A02"], checks: { A02: "ローカル検証 | 仕様確認" } })), ["A02 todo"]);
});

test("items は要検証が 0 件・A100・CRLF を扱える", () => {
  assert.deepEqual(run(["items", SHA], { body: body({ needs: [] }) }).out.split("\n").slice(1), []);
  assert.deepEqual(run(["items", SHA], { body: body({ needs: ["A99", "A100"] }).replace(/\n/g, "\r\n") }).out.split("\n").slice(1), ["A99 todo", "A100 todo"]);
});

test("構造の異常は終了コード 2", () => {
  const cases = [
    [body().replace("<!-- security-audit:summary-end -->", ""), "summary_block"],
    [body().replace("<!-- security-audit:summary-id=audit-1 -->", ""), "summary_id"],
    [body().replace("## 要検証（2件）", "## 要検証（3件）"), "count_mismatch:needs_validation"],
    [body().replace("| A03 | 領域 | 題名A03 |", "| A02 | 領域 | 題名A03 |"), "item_duplicate_or_missing:A02"],
    [body().replace("| A03 | 領域 | 題名A03 |\n", ""), "count_mismatch:needs_validation"],
    [body({ needs: ["A02", "A03"], extra: { A02: [marker("A02", SHA, "held"), marker("A02", SHA2, "held")] } }), "marker_duplicate:A02"],
    [body().replace("## 棄却（0件）", "## 要検証（0件）"), "section_duplicate:needs_validation"],
  ];
  for (const [text, reason] of cases) {
    const r = run(["items", SHA], { body: text });
    assert.deepEqual([r.code, r.out], [2, reason], reason);
  }
  assert.equal(run(["items", SHA], { body: body(), state: "CLOSED" }).out, "issue_not_open");
});

test("区画の外にある同名の見出しは数えない", () => {
  const text = `## 要検証（9件）\n| A09 | x | y |\n${body()}`;
  assert.deepEqual(run(["items", SHA], { body: text }).out.split("\n").slice(1), ["A02 todo", "A03 todo"]);
});

test("status は区分と印を出す", () => {
  const text = body({ confirmed: ["A01"], needs: ["A02"], extra: { A01: [marker("A01", SHA, "confirmed")] } });
  assert.equal(run(["status", "A01"], { body: text }).out, `confirmed ${SHA} confirmed`);
  assert.equal(run(["status", "A02"], { body: text }).out, "needs_validation none none");
  assert.equal(run(["status", "A09"], { body: text }).code, 2);
});

test("check は対象の項目を確定・棄却へ移す書き換えを通す", () => {
  const before = body({ needs: ["A02", "A03"] });
  const toConfirmed = body({ confirmed: ["A02"], needs: ["A03"], extra: { A02: ["- **調べ直し**: 確定。", marker("A02", SHA, "confirmed")] } }).replace("確定 0 件。", "確定 1 件。");
  assert.deepEqual(check("A02", before, toConfirmed), []);
  const allRejected = body({ needs: [], rejected: ["A02", "A03"] });
  assert.deepEqual(check("A03", body({ needs: ["A03"], rejected: ["A02"] }), allRejected), []);
});

test("check はほかの項目・区画の外・マーカー・補足の変更を止める", () => {
  const before = body({ needs: ["A02", "A03"] });
  assert.deepEqual(check("A02", before, before.replace("題名A03 |", "題名X |")), ["item_changed:A03"]);
  assert.deepEqual(check("A02", before, body({ needs: ["A02"] })), ["item_removed:A03"]);
  assert.deepEqual(check("A02", before, before.replace("人の追記", "消した")), ["outside_changed"]);
  assert.deepEqual(check("A02", before, before.replace("区画の後の追記", "")), ["outside_changed"]);
  assert.deepEqual(check("A02", before, before.replace("summary-revision=1", "summary-revision=2")), ["audit_marker_changed"]);
  assert.deepEqual(check("A02", before, before.replace("補足の文。", "変えた。")), ["other_text_changed"]);
  assert.deepEqual(check("A02", before, before.replace("<!-- security-audit:summary-end -->", "")), ["after:summary_block"]);
  assert.deepEqual(check("A02", before, `${before}${"あ".repeat(60000)}`), ["outside_changed", `too_long:${[...before].length + 60000}`]);
});

test("mark は停止の箇条と印を ID の前に置き、同じ SHA なら回数を増やす", () => {
  const before = body({ needs: ["A02", "A03"] });
  const once = mark(before, "A02", SHA, "2026-11-15");
  assert.deepEqual(check("A02", before, once), []);
  assert.match(once, /- \*\*調べ直し\*\*: 2026-11-15、aaaaaaa で調べ始めたが途中で止まった（1 回目）。\n<!-- security-audit-verify:A02 sha=a{40} result=stopped stops=1 -->\n- \*\*ID\*\*: `fp-A02`/);
  const twice = mark(once, "A02", SHA, "2026-11-16");
  assert.equal(parse(twice).items.get("A02").marker.stops, 2);
  assert.equal((twice.match(/調べ直し/g) ?? []).length, 1);
  assert.equal(parse(mark(twice, "A02", SHA2, "2026-11-17")).items.get("A02").marker.stops, 1);
  assert.throws(() => mark(body({ confirmed: ["A01"], needs: [] }), "A01", SHA, "2026-11-15"), /item_not_needs_validation/);
});

test("pick はタイトルの日付が新しい集約 Issue を選ぶ", () => {
  const issue = (number, title, createdAt, withId = true) => ({ number, title, createdAt, body: withId ? "<!-- security-audit:summary-id=x -->" : "", author: { login: "u" } });
  const list = [
    issue(1, "[2026-11-01] セキュリティ監査の調査・判定一覧", "2026-11-01T00:00:00Z"),
    issue(2, "[2026-11-10] セキュリティ監査の調査・判定一覧", "2026-11-10T00:00:00Z"),
    issue(3, "[2026-11-10] セキュリティ監査の調査・判定一覧", "2026-11-10T05:00:00Z"),
    issue(4, "[2026-11-20] セキュリティ監査の調査・判定一覧", "2026-11-20T00:00:00Z", false),
    issue(5, "[2026-11-30] ほかの Issue", "2026-11-30T00:00:00Z"),
  ];
  assert.equal(run(["pick"], list).out, "3 u");
  assert.deepEqual([run(["pick"], []).code, run(["pick"], []).out], [2, "no_summary_issue"]);
});

test("busy は最新の監査の実行だけを見る", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "verify-busy-"));
  assert.equal(run(["busy", path.join(dir, "none")]).out, "free");
  const stage = (name, value) => {
    fs.mkdirSync(path.join(dir, name), { recursive: true });
    if (value !== undefined) fs.writeFileSync(path.join(dir, name, "supervisor.json"), value);
  };
  stage("run-2", JSON.stringify({ stage: "auditing" }));
  stage("run-10", JSON.stringify({ stage: "done" }));
  assert.equal(run(["busy", dir]).out, "free");
  stage("run-11", JSON.stringify({ stage: "self_auditing" }));
  assert.equal(run(["busy", dir]).out, "busy run-11:self_auditing");
  stage("run-12", "{");
  assert.equal(run(["busy", dir]).out, "busy run-12:unreadable");
  stage("run-13");
  assert.equal(run(["busy", dir]).out, "free");
});

test("lock は持ち主の印で排他し、3 時間更新のないロックを引き継ぐ", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "verify-lock-"));
  const first = run(["lock", dir, "acquire"]);
  const [, token] = first.out.split(" ");
  assert.match(first.out, /^acquired [0-9a-f-]{36}$/);
  const second = run(["lock", dir, "acquire"]);
  assert.deepEqual([second.code, second.out], [2, `locked ${path.join(dir, "lock")}`]);
  assert.equal(run(["lock", dir, "touch", token]).out, "touched");
  const other = "00000000-0000-0000-0000-000000000000";
  assert.deepEqual([run(["lock", dir, "touch", other]).code, run(["lock", dir, "release", other]).out], [2, "not_owner"]);
  assert.equal(fs.existsSync(path.join(dir, "lock")), true);
  fs.mkdirSync(path.join(dir, "lock.takeover"));
  const old = new Date(Date.now() - 4 * 60 * 60 * 1000);
  fs.utimesSync(path.join(dir, "lock", "heartbeat"), old, old);
  assert.equal(run(["lock", dir, "acquire"]).code, 2, "ほかの実行が引き継ぎ中なら取らない");
  fs.rmdirSync(path.join(dir, "lock.takeover"));
  const taken = run(["lock", dir, "acquire"]);
  assert.match(taken.out, /^acquired [0-9a-f-]{36} stale$/);
  const [, newToken] = taken.out.split(" ");
  assert.equal(fs.existsSync(path.join(dir, "lock.takeover")), false);
  assert.deepEqual([run(["lock", dir, "release", token]).code, run(["lock", dir, "touch", token]).out], [2, "not_owner"], "引き継がれた古い持ち主は消せない");
  assert.equal(run(["lock", dir, "release", newToken]).out, "released");
  assert.equal(fs.existsSync(path.join(dir, "lock")), false);
  assert.equal(run(["lock", dir, "touch"]).code, 3);
});

test("check は冒頭の監査用マーカーと説明の変更を止め、件数の変更だけを通す", () => {
  const before = body();
  assert.deepEqual(check("A02", before, before.replace(`source-sha=${SHA2}`, `source-sha=${SHA}`)), ["audit_marker_changed"]);
  assert.deepEqual(check("A02", before, before.replace("冒頭の説明。", "書き換えた説明。")), ["other_text_changed"]);
  assert.deepEqual(check("A02", before, before.replace("冒頭の説明。確定 0 件。", "冒頭の説明。確定 0 件。\n足した行。")), ["other_text_changed"]);
  assert.deepEqual(check("A02", before, before.replace("確定 0 件。", "確定 12 件。")), []);
});

test("check は 60,000 字ちょうどを通し、1 字超えを止める", () => {
  const before = body();
  const pad = (n) => before.replace("区画の後の追記", `区画の後の追記${"あ".repeat(n)}`);
  const exact = pad(60000 - [...before].length);
  assert.equal([...exact].length, 60000);
  assert.deepEqual(check("A02", exact, exact), []);
  assert.deepEqual(check("A02", exact, pad(60001 - [...before].length)), ["outside_changed", "too_long:60001"]);
});

test("summary-id の形が違えば構造の異常", () => {
  const r = run(["items", SHA], { body: body().replace("summary-id=audit-1", "summary-id=指示 の 文") });
  assert.deepEqual([r.code, r.out], [2, "summary_id"]);
});

test("mark は ID の箇条がない詳細と CRLF の本文を扱い、判断できないの印を置き換える", () => {
  const noId = body({ needs: ["A02"] }).replace("- **ID**: `fp-A02`\n", "");
  const marked = mark(noId, "A02", SHA, "2026-11-15");
  assert.deepEqual(check("A02", noId, marked), []);
  const crlf = body({ needs: ["A02"], extra: { A02: [marker("A02", SHA, "undetermined")] } }).replace(/\n/g, "\r\n");
  const replaced = mark(crlf, "A02", SHA, "2026-11-15");
  assert.equal(parse(replaced).items.get("A02").marker.result, "stopped");
  assert.equal((replaced.match(/security-audit-verify:/g) ?? []).length, 1);
});

test("引数の誤りは終了コード 3", () => {
  assert.equal(run(["items", "abc"], { body: body() }).code, 3);
  assert.equal(run(["status", "x"], { body: body() }).code, 3);
  assert.equal(run(["unknown"]).code, 3);
});
