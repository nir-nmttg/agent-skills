import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { main } from "./supervise.mjs";

function runDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "supervise-test-"));
}

function writeJson(dir, name, value) {
  fs.writeFileSync(path.join(dir, name), JSON.stringify(value));
}

function started(dir) {
  main(["init", dir]);
  main(["attach", dir, "agent-1"]);
}

test("段階は starting から auditing、gave_up、auditing、done へ移る", () => {
  const dir = runDir();
  assert.equal(main(["init", dir]), "starting");
  assert.throws(() => main(["init", dir]), /すでにあります/);
  assert.equal(main(["next", dir]), "none stage=starting");
  assert.equal(main(["attach", dir, "agent-1"]), "auditing");
  assert.throws(() => main(["resume", dir]), /gave_up ではありません/);
  assert.equal(main(["finish", dir, "gave_up"]), "gave_up");
  assert.equal(main(["resume", dir]), "auditing");
  assert.equal(main(["finish", dir, "done"]), "done");
  assert.match(main(["state", dir]), /^stage=done coordinator_id=agent-1 /);
});

test("進まない停止が2回続くと give_up", () => {
  const dir = runDir();
  started(dir);
  main(["record", dir, "stopped", "cyber_policy"]);
  assert.equal(main(["next", dir]), "continue");
  main(["record", dir, "resuming"]);
  main(["record", dir, "stopped", "cyber_policy"]);
  assert.equal(main(["next", dir]), "give_up reason=no_progress");
});

test("停止のあいだに成果物が変われば進んだとみなす", () => {
  const dir = runDir();
  started(dir);
  writeJson(dir, "coverage-ledger.json", [{ status: "planned" }]);
  main(["record", dir, "stopped"]);
  main(["record", dir, "resuming"]);
  fs.mkdirSync(path.join(dir, "agents", "hunter-1"), { recursive: true });
  main(["record", dir, "stopped"]);
  main(["record", dir, "resuming"]);
  writeJson(dir, "coverage-ledger.json", [{ status: "covered" }]);
  main(["record", dir, "stopped"]);
  assert.equal(main(["next", dir]), "continue");
});

test("自動の続きは malformed の出し直しを含めて上限ちょうどで止まる", () => {
  const dir = runDir();
  started(dir);
  for (let i = 0; i < 8; i += 1) {
    fs.writeFileSync(path.join(dir, "REPORT.md"), `v${i}`);
    main(["record", dir, i % 2 ? "malformed" : "stopped"]);
    assert.equal(main(["next", dir]), "continue", `回数 ${i}`);
    main(["record", dir, "resuming"]);
  }
  fs.writeFileSync(path.join(dir, "REPORT.md"), "last");
  main(["record", dir, "stopped"]);
  assert.equal(main(["next", dir]), "give_up reason=max_auto_resumes");
});

test("審査以外のエラーと送信の失敗は利用者に返す", () => {
  const dir = runDir();
  started(dir);
  main(["record", dir, "stopped", "usage_limit"]);
  assert.equal(main(["next", dir]), "report reason=error_kind:usage_limit");
  main(["record", dir, "stopped", "cyber_policy"]);
  main(["record", dir, "followup_failed"]);
  assert.equal(main(["next", dir]), "report reason=followup_failed");
});

test("状態不明は3回続くまで待ち直す", () => {
  const dir = runDir();
  started(dir);
  main(["record", dir, "unknown"]);
  assert.equal(main(["next", dir]), "wait");
  main(["record", dir, "unknown"]);
  main(["record", dir, "unknown"]);
  assert.equal(main(["next", dir]), "give_up reason=unknown_state");
});

test("unsupported で self_auditing になり、自動の続きはしない", () => {
  const dir = runDir();
  started(dir);
  main(["record", dir, "unsupported"]);
  assert.equal(main(["next", dir]), "none stage=self_auditing");
  assert.equal(main(["finish", dir, "done"]), "done");
});

test("supervisor.json がない・壊れていると止まる", () => {
  const dir = runDir();
  assert.throws(() => main(["next", dir]), /supervisor.json がありません/);
  fs.writeFileSync(path.join(dir, "supervisor.json"), "{");
  assert.throws(() => main(["next", dir]), /読めません/);
  assert.throws(() => main(["next", "relative/dir"]), /絶対パス/);
  writeJson(dir, "supervisor.json", { stage: "auditing", events: [] });
  assert.throws(() => main(["record", dir, "nonsense"]), /kind が正しくありません/);
});

test("エラーの種別は小文字の短い語にそろえて記録する", () => {
  const dir = runDir();
  started(dir);
  main(["record", dir, "stopped", "Cyber Policy!"]);
  assert.equal(main(["next", dir]), "report reason=error_kind:cyber_policy_");
  main(["record", dir, "human_resume"]);
  main(["record", dir, "stopped", "CYBER_POLICY"]);
  assert.equal(main(["next", dir]), "continue");
});

test("段階に合わない記録と終わり方は断る", () => {
  const dir = runDir();
  main(["init", dir]);
  assert.throws(() => main(["record", dir, "stopped"]), /段階 starting/);
  assert.throws(() => main(["finish", dir, "done"]), /段階 starting/);
  assert.throws(() => main(["attach", dir, "bad id"]), /coordinator_id/);
  assert.equal(main(["record", dir, "unsupported"]).startsWith("unsupported"), true);
  assert.throws(() => main(["record", dir, "unsupported"]), /段階 self_auditing/);
  main(["finish", dir, "done"]);
  assert.throws(() => main(["record", dir, "resuming"]), /段階 done/);
});

test("続きを頼んだあとは、それより前の出来事で判定しない", () => {
  const dir = runDir();
  started(dir);
  main(["record", dir, "followup_failed"]);
  assert.equal(main(["next", dir]), "report reason=followup_failed");
  main(["record", dir, "human_resume"]);
  assert.equal(main(["next", dir]), "wait");
  main(["record", dir, "malformed"]);
  assert.equal(main(["next", dir]), "continue");
});

test("状態不明のあと出し直しを頼めば continue に戻る", () => {
  const dir = runDir();
  started(dir);
  main(["record", dir, "unknown"]);
  assert.equal(main(["next", dir]), "wait");
  main(["record", dir, "malformed"]);
  assert.equal(main(["next", dir]), "continue");
});

test("自動の続きの累計は人による再開をまたいで数え、あきらめた理由も残す", () => {
  const dir = runDir();
  started(dir);
  for (let i = 0; i < 8; i += 1) {
    fs.writeFileSync(path.join(dir, "REPORT.md"), `v${i}`);
    main(["record", dir, "stopped", "cyber_policy"]);
    main(["record", dir, "resuming"]);
  }
  fs.writeFileSync(path.join(dir, "REPORT.md"), "x");
  main(["record", dir, "stopped", "cyber_policy"]);
  assert.equal(main(["next", dir]), "give_up reason=max_auto_resumes");
  main(["finish", dir, "gave_up", "max_auto_resumes"]);
  main(["resume", dir]);
  main(["record", dir, "resuming"]);
  main(["record", dir, "returned", "error_kind:usage_limit"]);
  const s = JSON.parse(main(["summary", dir]));
  assert.equal(s.supervisor.auto_resumes, 9);
  assert.equal(s.supervisor.human_resumes, 1);
  assert.deepEqual(s.supervisor.gave_up_reasons, ["max_auto_resumes"]);
  assert.deepEqual(s.supervisor.returned_reasons, ["error_kind:usage_limit"]);
});

test("summary は読めない成果物の件数を null にし、空の配列の 0 件と分ける", () => {
  const dir = runDir();
  let s = JSON.parse(main(["summary", dir]));
  assert.deepEqual(s.files, { run_metadata: "missing", coverage_ledger: "missing", findings: "missing" });
  assert.equal(s.counts, null);
  assert.equal(s.ledger, null);
  fs.writeFileSync(path.join(dir, "findings.json"), "{");
  writeJson(dir, "coverage-ledger.json", { not: "array" });
  writeJson(dir, "run-metadata.json", null);
  s = JSON.parse(main(["summary", dir]));
  assert.deepEqual(s.files, { run_metadata: "unreadable", coverage_ledger: "unreadable", findings: "unreadable" });
  assert.equal(s.counts, null);
  writeJson(dir, "findings.json", []);
  writeJson(dir, "coverage-ledger.json", []);
  writeJson(dir, "run-metadata.json", { run_status: "incomplete", incomplete_reason: "validation_budget_exhausted" });
  s = JSON.parse(main(["summary", dir]));
  assert.deepEqual(s.counts, { confirmed: 0, needs_validation: 0, rejected: 0, other: 0, unverified: 0 });
  assert.equal(s.incomplete_reason, "validation_budget_exhausted");
});

test("check は run-metadata.json が null や配列でも mismatch を返す", () => {
  const dir = runDir();
  writeJson(dir, "run-metadata.json", null);
  assert.equal(main(["check", dir, "complete"]), "mismatch reason=run_metadata_unreadable");
  writeJson(dir, "run-metadata.json", []);
  assert.equal(main(["check", dir, "incomplete"]), "mismatch reason=run_metadata_unreadable");
});

test("check は run_status と issue_sync.status の両方を照合する", () => {
  const dir = runDir();
  assert.equal(main(["check", dir, "complete"]), "mismatch reason=run_metadata_unreadable");
  writeJson(dir, "run-metadata.json", { run_status: "in_progress", issue_sync: { status: "complete" } });
  assert.equal(main(["check", dir, "complete"]), "mismatch reason=run_status:in_progress");
  writeJson(dir, "run-metadata.json", { run_status: "incomplete", issue_sync: { status: "pending" } });
  assert.equal(main(["check", dir, "incomplete"]), "mismatch reason=issue_sync:pending");
  writeJson(dir, "run-metadata.json", { run_status: "incomplete", issue_sync: { status: "partial" } });
  assert.equal(main(["check", dir, "incomplete"]), "ok");
  assert.equal(main(["check", dir, "complete"]), "mismatch reason=run_status:incomplete");
});

test("summary は件数と URL だけを出し、未検証は fingerprint の重複を除いて数える", () => {
  const dir = runDir();
  started(dir);
  writeJson(dir, "run-metadata.json", {
    run_status: "incomplete",
    source_ref: { commit: "a".repeat(40) },
    issue_sync: {
      status: "complete",
      summary_url: "https://github.com/o/r/issues/9",
      individual_counts: { created: 1, note: "文章" },
      individuals: [{ url: "https://github.com/o/r/issues/10", result: "created", autofix_added: true, reason: null }],
    },
  });
  writeJson(dir, "coverage-ledger.json", [
    { status: "candidate", result_fingerprints: ["fp-a", "fp-b"] },
    { status: "candidate", result_fingerprints: ["fp-b", "fp-c"] },
    { status: "covered" },
    { status: "weird" },
  ]);
  writeJson(dir, "findings.json", [
    { verdict: "confirmed", fingerprint: "fp-a", description: "攻撃の詳細" },
    { verdict: "rejected", fingerprint: "fp-x" },
  ]);
  main(["record", dir, "stopped", "cyber_policy"]);
  const out = main(["summary", dir]);
  assert.doesNotMatch(out, /攻撃の詳細/);
  const s = JSON.parse(out);
  assert.equal(s.source_sha, "a".repeat(40));
  assert.deepEqual(s.counts, { confirmed: 1, needs_validation: 0, rejected: 1, other: 0, unverified: 2 });
  assert.equal(s.ledger.candidate, 2);
  assert.equal(s.ledger.other, 1);
  assert.equal(s.issue_sync.summary_url, "https://github.com/o/r/issues/9");
  assert.equal(s.issue_sync.individuals[0].autofix_added, true);
  assert.deepEqual(s.issue_sync.individual_counts, { created: 1 });
  assert.equal(s.files.findings, "ok");
  assert.equal(s.supervisor.stops, 1);
  assert.deepEqual(s.supervisor.error_kinds, ["cyber_policy"]);
});

test("監督役の再開の記録は、記録済みの停止の判定を隠さない", () => {
  const dir = runDir();
  started(dir);
  main(["record", dir, "stopped", "cyber_policy"]);
  main(["record", dir, "supervisor_resume"]);
  assert.equal(main(["next", dir]), "continue");
  const s = JSON.parse(main(["summary", dir]));
  assert.equal(s.supervisor.supervisor_resumes, 1);
  assert.equal(s.supervisor.stops, 1);
});

test("run_dir の食い違いは report になり、理由を残せる", () => {
  const dir = runDir();
  started(dir);
  main(["record", dir, "run_dir_mismatch"]);
  assert.equal(main(["next", dir]), "report reason=run_dir_mismatch");
  main(["record", dir, "returned", "run_dir_mismatch"]);
  assert.deepEqual(JSON.parse(main(["summary", dir])).supervisor.returned_reasons, ["run_dir_mismatch"]);
});
