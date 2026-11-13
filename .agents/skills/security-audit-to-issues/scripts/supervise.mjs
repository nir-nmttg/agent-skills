#!/usr/bin/env node
// Supervisor が Coordinator の停止を見張るための記録と判定。出力は決まった語・数・ハッシュ・URL と、Coordinator が記録した保留の理由（短い文）だけにする。
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const STATE_FILE = "supervisor.json";
const MAX_AUTO_RESUMES = 8;
const MAX_NO_PROGRESS = 2;
const MAX_UNKNOWN = 3;
const STAGES = ["starting", "auditing", "self_auditing", "gave_up", "done"];
const EVENT_KINDS = ["stopped", "malformed", "unknown", "resuming", "human_resume", "followup_failed", "run_dir_mismatch", "unsupported", "returned", "supervisor_resume"];
const AUDITING_ONLY = ["stopped", "malformed", "unknown", "resuming", "human_resume", "followup_failed", "run_dir_mismatch", "returned"];
const DECISION_KINDS = ["stopped", "malformed", "unknown", "followup_failed", "run_dir_mismatch"];
const LEDGER_STATUSES = ["planned", "in_progress", "candidate", "covered", "blocked", "deferred", "not_applicable", "out_of_scope"];
const VERDICTS = ["confirmed", "needs_validation", "rejected"];
const ISSUE_SYNC_DONE = ["complete", "partial", "blocked"];
const SAFE_TOKEN = /^[a-z0-9][a-z0-9_.:-]{0,63}$/;
const REASON_TOKEN = /^[a-z0-9][a-z0-9_.:-]{0,127}$/;

class UsageError extends Error {}

function fail(message) {
  throw new UsageError(message);
}

function runDirOf(arg) {
  if (!arg || !path.isAbsolute(arg)) fail("run_dir は絶対パスで指定してください");
  const dir = path.resolve(arg);
  let st;
  try {
    st = fs.statSync(dir);
  } catch {
    fail(`run_dir がありません: ${dir}`);
  }
  if (!st.isDirectory()) fail(`run_dir がディレクトリではありません: ${dir}`);
  return dir;
}

function readJson(file) {
  try {
    return { ok: true, value: JSON.parse(fs.readFileSync(file, "utf8")) };
  } catch (error) {
    return { ok: false, missing: error.code === "ENOENT" };
  }
}

function writeJsonAtomic(file, value) {
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, { flag: "wx" });
  fs.renameSync(tmp, file);
}

function now() {
  return new Date().toISOString();
}

function loadState(dir) {
  const r = readJson(path.join(dir, STATE_FILE));
  if (!r.ok) fail(r.missing ? "supervisor.json がありません" : "supervisor.json を読めません");
  const s = r.value;
  if (!s || typeof s !== "object" || !STAGES.includes(s.stage) || !Array.isArray(s.events)) fail("supervisor.json の形が正しくありません");
  return s;
}

function saveState(dir, state) {
  writeJsonAtomic(path.join(dir, STATE_FILE), state);
}

function progress(dir) {
  const hash = createHash("sha256");
  const files = fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && e.name !== STATE_FILE && !e.name.startsWith(`${STATE_FILE}.`))
    .map((e) => e.name)
    .sort();
  for (const name of files) {
    hash.update(`${name}\0`);
    try {
      hash.update(fs.readFileSync(path.join(dir, name)));
    } catch {
      hash.update("<unreadable>");
    }
    hash.update("\0");
  }
  let agents = 0;
  try {
    agents = fs.readdirSync(path.join(dir, "agents"), { withFileTypes: true }).filter((e) => e.isDirectory()).length;
  } catch {
    agents = 0;
  }
  hash.update(`agents=${agents}`);
  return `${hash.digest("hex").slice(0, 16)}:agents=${agents}`;
}

function pushEvent(state, event) {
  state.events.push({ at: now(), ...event });
}

function cmdInit(dir) {
  const file = path.join(dir, STATE_FILE);
  if (fs.existsSync(file)) fail("supervisor.json はすでにあります");
  const state = {
    version: 1,
    run_dir: dir,
    stage: "starting",
    coordinator_id: null,
    auto_resumes: 0,
    max_auto_resumes: MAX_AUTO_RESUMES,
    consecutive_no_progress: 0,
    consecutive_unknown: 0,
    last_progress: progress(dir),
    events: [],
  };
  pushEvent(state, { kind: "init" });
  saveState(dir, state);
  return "starting";
}

function cmdAttach(dir, coordinatorId) {
  if (!coordinatorId || coordinatorId.length > 256 || /[\s"'`]/.test(coordinatorId)) fail("coordinator_id が正しくありません");
  const state = loadState(dir);
  if (state.stage !== "starting") fail(`段階が starting ではありません: ${state.stage}`);
  state.coordinator_id = coordinatorId;
  state.stage = "auditing";
  state.last_progress = progress(dir);
  pushEvent(state, { kind: "attach" });
  saveState(dir, state);
  return "auditing";
}

function token(value) {
  const t = String(value).toLowerCase().replace(/[^a-z0-9_.:-]/g, "_").replace(/^[^a-z0-9]+/, "").slice(0, 128);
  return t || "other";
}

function cmdRecord(dir, kind, detail) {
  if (!EVENT_KINDS.includes(kind)) fail(`kind が正しくありません: ${kind}`);
  const state = loadState(dir);
  if (AUDITING_ONLY.includes(kind) && state.stage !== "auditing") fail(`段階 ${state.stage} では ${kind} を記録できません`);
  if (kind === "unsupported" && !["starting", "auditing"].includes(state.stage)) fail(`段階 ${state.stage} では unsupported を記録できません`);
  const event = { kind };
  if (detail !== undefined) event[kind === "returned" ? "reason" : "error_kind"] = token(detail);
  if (kind === "unknown") {
    state.consecutive_unknown += 1;
  } else {
    state.consecutive_unknown = 0;
  }
  if (kind === "stopped") {
    const p = progress(dir);
    state.consecutive_no_progress = p === state.last_progress ? state.consecutive_no_progress + 1 : 0;
    state.last_progress = p;
    event.progress = p;
  }
  if (kind === "resuming") state.auto_resumes += 1;
  if (kind === "human_resume") {
    state.consecutive_no_progress = 0;
    state.auto_resumes = 0;
    state.last_progress = progress(dir);
  }
  if (kind === "unsupported") state.stage = "self_auditing";
  pushEvent(state, event);
  saveState(dir, state);
  return `${kind} auto_resumes=${state.auto_resumes}/${state.max_auto_resumes} no_progress=${state.consecutive_no_progress}`;
}

function cmdNext(dir) {
  const state = loadState(dir);
  if (state.stage !== "auditing") return `none stage=${state.stage}`;
  // 最後に続きを頼んだ（resuming・human_resume）より前の出来事では判定しない
  let last;
  for (let i = state.events.length - 1; i >= 0; i -= 1) {
    const e = state.events[i];
    if (["resuming", "human_resume", "attach"].includes(e.kind)) break;
    if (DECISION_KINDS.includes(e.kind)) {
      last = e;
      break;
    }
  }
  if (!last) return "wait";
  if (["followup_failed", "run_dir_mismatch"].includes(last.kind)) return `report reason=${last.kind}`;
  if (last.kind === "stopped" && last.error_kind && last.error_kind !== "cyber_policy") return `report reason=error_kind:${last.error_kind}`;
  if (last.kind === "unknown") return state.consecutive_unknown >= MAX_UNKNOWN ? "give_up reason=unknown_state" : "wait";
  if (state.consecutive_no_progress >= MAX_NO_PROGRESS) return "give_up reason=no_progress";
  if (state.auto_resumes >= state.max_auto_resumes) return "give_up reason=max_auto_resumes";
  return "continue";
}

function runStatusOf(meta) {
  return typeof meta.run_status === "string" ? meta.run_status : null;
}

function cmdCheck(dir, status) {
  if (!["complete", "incomplete"].includes(status)) fail("status は complete か incomplete にしてください");
  const r = readJson(path.join(dir, "run-metadata.json"));
  if (!r.ok || !r.value || typeof r.value !== "object" || Array.isArray(r.value)) return "mismatch reason=run_metadata_unreadable";
  const runStatus = runStatusOf(r.value);
  const expected = status === "complete" ? ["complete", "completed"] : ["incomplete"];
  if (!expected.includes(runStatus)) return `mismatch reason=run_status:${SAFE_TOKEN.test(runStatus ?? "") ? runStatus : "other"}`;
  const syncStatus = r.value.issue_sync?.status;
  if (!ISSUE_SYNC_DONE.includes(syncStatus)) return `mismatch reason=issue_sync:${SAFE_TOKEN.test(syncStatus ?? "") ? syncStatus : "missing"}`;
  return "ok";
}

function short(value, max = 200) {
  if (typeof value !== "string") return null;
  const oneLine = value.replace(/\s+/g, " ").trim();
  return oneLine.length > max ? `${oneLine.slice(0, max)}…` : oneLine;
}

function githubUrl(value) {
  return typeof value === "string" && /^https:\/\/[^\s]+\/issues\/\d+$/.test(value) ? value : null;
}

function fileStatus(r, isValid) {
  if (r.ok) return isValid(r.value) ? "ok" : "unreadable";
  return r.missing ? "missing" : "unreadable";
}

function numbersOnly(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const out = {};
  for (const [k, v] of Object.entries(value)) if (SAFE_TOKEN.test(k) && Number.isInteger(v) && v >= 0) out[k] = v;
  return out;
}

function cmdSummary(dir) {
  const meta = readJson(path.join(dir, "run-metadata.json"));
  const ledger = readJson(path.join(dir, "coverage-ledger.json"));
  const findings = readJson(path.join(dir, "findings.json"));
  const isObject = (v) => !!v && typeof v === "object" && !Array.isArray(v);
  const files = {
    run_metadata: fileStatus(meta, isObject),
    coverage_ledger: fileStatus(ledger, Array.isArray),
    findings: fileStatus(findings, Array.isArray),
  };
  const m = files.run_metadata === "ok" ? meta.value : {};

  let ledgerCounts = null;
  const candidateFps = new Set();
  if (files.coverage_ledger === "ok") {
    ledgerCounts = Object.fromEntries([...LEDGER_STATUSES, "other"].map((s) => [s, 0]));
    for (const unit of ledger.value) {
      const s = LEDGER_STATUSES.includes(unit?.status) ? unit.status : "other";
      ledgerCounts[s] += 1;
      if (s === "candidate" && Array.isArray(unit.result_fingerprints)) {
        for (const fp of unit.result_fingerprints) if (typeof fp === "string") candidateFps.add(fp);
      }
    }
  }

  // 読めないファイルがある区分は null（不明）にし、空の配列の 0 件と分ける
  let counts = null;
  if (files.findings === "ok") {
    counts = Object.fromEntries([...VERDICTS, "other"].map((v) => [v, 0]));
    const decided = new Set();
    for (const rec of findings.value) {
      const v = VERDICTS.includes(rec?.verdict) ? rec.verdict : "other";
      counts[v] += 1;
      if (typeof rec?.fingerprint === "string") decided.add(rec.fingerprint);
    }
    counts.unverified = files.coverage_ledger === "ok" ? [...candidateFps].filter((fp) => !decided.has(fp)).length : null;
  } else if (files.coverage_ledger === "ok") {
    counts = { confirmed: null, needs_validation: null, rejected: null, other: null, unverified: candidateFps.size };
  }

  const sync = isObject(m.issue_sync) ? m.issue_sync : {};
  const individuals = Array.isArray(sync.individuals)
    ? sync.individuals.map((it) => ({
        url: githubUrl(it?.url),
        result: ["created", "updated", "unchanged", "held"].includes(it?.result) ? it.result : null,
        autofix_added: it?.autofix_added === true,
        reason: short(it?.reason),
      }))
    : null;

  const state = readJson(path.join(dir, STATE_FILE));
  const events = state.ok && Array.isArray(state.value?.events) ? state.value.events : [];
  const count = (kind) => events.filter((e) => e?.kind === kind).length;
  const reasons = (kind) => events.filter((e) => e?.kind === kind && typeof e.reason === "string").map((e) => e.reason);

  const sourceRef = typeof m.source_ref === "string" ? m.source_ref : m.source_ref?.commit;
  const artifacts = ["REPORT.md", "FINDINGS-DETAIL.md", "NEEDS-VALIDATION.md", "findings.json", "coverage-ledger.json", "run-metadata.json"]
    .map((name) => path.join(dir, name))
    .filter((p) => fs.existsSync(p));

  return JSON.stringify(
    {
      run_dir: dir,
      files,
      source_sha: typeof sourceRef === "string" && /^[0-9a-f]{40}$/.test(sourceRef) ? sourceRef : null,
      run_status: SAFE_TOKEN.test(runStatusOf(m) ?? "") ? runStatusOf(m) : null,
      incomplete_reason: REASON_TOKEN.test(m.incomplete_reason ?? "") ? m.incomplete_reason : null,
      artifacts,
      counts,
      ledger: ledgerCounts,
      issue_sync: {
        status: SAFE_TOKEN.test(sync.status ?? "") ? sync.status : null,
        summary_url: githubUrl(sync.summary_url),
        individual_counts: numbersOnly(sync.individual_counts),
        individuals,
      },
      supervisor: {
        stage: state.ok ? state.value?.stage ?? null : null,
        stops: count("stopped"),
        malformed: count("malformed"),
        auto_resumes: count("resuming"),
        human_resumes: count("human_resume"),
        supervisor_resumes: count("supervisor_resume"),
        error_kinds: [...new Set(events.map((e) => e?.error_kind).filter((k) => typeof k === "string"))],
        gave_up_reasons: reasons("finish_gave_up"),
        returned_reasons: reasons("returned"),
      },
    },
    null,
    2,
  );
}

function cmdResume(dir) {
  const state = loadState(dir);
  if (state.stage !== "gave_up") fail(`段階が gave_up ではありません: ${state.stage}`);
  state.stage = "auditing";
  state.consecutive_no_progress = 0;
  state.consecutive_unknown = 0;
  state.auto_resumes = 0;
  state.last_progress = progress(dir);
  pushEvent(state, { kind: "human_resume" });
  saveState(dir, state);
  return "auditing";
}

function cmdFinish(dir, stage, reason) {
  if (!["done", "gave_up"].includes(stage)) fail("stage は done か gave_up にしてください");
  const state = loadState(dir);
  if (!["auditing", "self_auditing"].includes(state.stage)) fail(`段階 ${state.stage} からは終えられません`);
  state.stage = stage;
  const event = { kind: `finish_${stage}` };
  if (reason !== undefined) event.reason = token(reason);
  pushEvent(state, event);
  saveState(dir, state);
  return stage;
}

function cmdState(dir) {
  const state = loadState(dir);
  return `stage=${state.stage} coordinator_id=${state.coordinator_id ?? "none"} auto_resumes=${state.auto_resumes}/${state.max_auto_resumes} no_progress=${state.consecutive_no_progress}`;
}

const COMMANDS = {
  init: (a) => cmdInit(runDirOf(a[0])),
  attach: (a) => cmdAttach(runDirOf(a[0]), a[1]),
  record: (a) => cmdRecord(runDirOf(a[0]), a[1], a[2]),
  next: (a) => cmdNext(runDirOf(a[0])),
  check: (a) => cmdCheck(runDirOf(a[0]), a[1]),
  progress: (a) => progress(runDirOf(a[0])),
  summary: (a) => cmdSummary(runDirOf(a[0])),
  resume: (a) => cmdResume(runDirOf(a[0])),
  finish: (a) => cmdFinish(runDirOf(a[0]), a[1], a[2]),
  state: (a) => cmdState(runDirOf(a[0])),
};

export function main(argv) {
  const [command, ...args] = argv;
  const fn = COMMANDS[command];
  if (!fn) fail(`使い方: supervise.mjs <${Object.keys(COMMANDS).join("|")}> <run_dir> [...]`);
  return fn(args);
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("/supervise.mjs")) {
  try {
    process.stdout.write(`${main(process.argv.slice(2))}\n`);
  } catch (error) {
    process.stderr.write(`supervise.mjs: ${error instanceof UsageError ? error.message : "予期しないエラー"}\n`);
    process.exit(error instanceof UsageError ? 2 : 1);
  }
}
