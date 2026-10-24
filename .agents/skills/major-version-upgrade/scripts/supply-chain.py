#!/usr/bin/env python3
"""供給網の必須検査を通過した計画だけを一度実行する。Python 3.9標準ライブラリ。"""

import sys

if not (sys.flags.isolated and sys.flags.no_site):
    print("信頼済みのPythonを -I -S 付きで起動してください。", file=sys.stderr)
    sys.exit(1)

import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
# -I -Sで起動しても、検査済みスキル自身の補助モジュールだけを参照する。
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from archive_inspector import inspect_artifact, InspectionError
from audit_report import inspect_audit, AuditError


REVIEWS = ("coverage", "sources", "artifacts", "advisories", "authenticity", "isolation", "compatibility")
ECOSYSTEMS = {"ruby", "node", "python"}
FORMATS = {"ruby": "bundler-audit", "node": "npm-v2", "python": "pip-audit"}
MAX_JSON = 8 * 1024 * 1024
MAX_FILE = 128 * 1024 * 1024
MAX_TREE = 64 * 1024 * 1024
MAX_FILES = 5000
MAX_ITEMS = 10000
MAX_CANDIDATES = 200
MAX_ARTIFACT_TOTAL = 512 * 1024 * 1024
MAX_AGE = timedelta(hours=24)
MIN_RELEASE_AGE = timedelta(days=7)
STATE = "gate-state.json"
CHILD_ENV = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}


class GateError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise GateError(message)


def object_keys(value, required, optional=()):
    require(type(value) is dict and set(required) <= set(value)
            and set(value) <= set(required) | set(optional), "JSONの必須項目または未対応項目を確認してください。")


def text_value(value, maximum=500):
    require(type(value) is str and 0 < len(value) <= maximum
            and not any(ord(c) < 32 or ord(c) == 127 for c in value), "文字列の型・長さ・制御文字が不正です。")
    return value


def relative_path(value):
    text_value(value, 2000)
    path = PurePosixPath(value)
    require(not path.is_absolute() and "\\" not in value and ":" not in value
            and all(p not in ("", ".", "..") for p in value.split("/")), "相対パスが保存先を逸脱しています。")
    return Path(*path.parts)


def safe_read(path, limit=MAX_JSON, nonempty=False):
    """各パス要素をno-followで開き、通常ファイルを上限付きで読む。"""
    require(hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY"), "安全なファイル読取りに未対応のOSです。")
    parts = Path(os.path.abspath(str(path))).parts
    parent = os.open(parts[0], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    fd = None
    try:
        for part in parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1, "通常ファイル以外・hardlinkは読めません。")
        require(before.st_size <= limit and (not nonempty or before.st_size > 0), "ファイルが空、または読取り上限を超えています。")
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(fd)
        current = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        def fingerprint(info):
            return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
                    info.st_mtime_ns, info.st_ctime_ns, info.st_nlink)
        require(fingerprint(before) == fingerprint(after) == fingerprint(current)
                and len(data) == before.st_size and len(data) <= limit, "読取り中にファイルが変更されました。")
        return bytes(data)
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path, limit=MAX_FILE):
    return digest(safe_read(path, limit))


def pairs_unique(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, "JSONに重複キーがあります。")
        value[key] = item
    return value


def reject_constant(_value):
    raise GateError("JSONに非有限数があります。")


def load_json(path):
    def bounded_integer(value):
        require(len(value) <= 20, "JSON整数が上限を超えています。")
        return int(value)
    return json.loads(safe_read(path, MAX_JSON, True).decode("utf-8"),
                      object_pairs_hook=pairs_unique, parse_constant=reject_constant,
                      parse_int=bounded_integer, parse_float=reject_constant)


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(",", ":")).encode("ascii")


def utc_time(value):
    text_value(value, 40)
    require(value.endswith("Z"), "日時はUTCのZ表記で指定してください。")
    parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    require(parsed.utcoffset() == timedelta(0), "日時のUTCを確認できません。")
    return parsed


def now_string():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def fresh(value, now):
    age = now - utc_time(value)
    require(timedelta(0) <= age <= MAX_AGE, "監査またはレビューが未来日時・24時間超です。")


def within(path, root):
    return path == root or root in path.parents


def run_directory(value):
    # new-run.shがcd -Pで作った、このスキル自身のartifacts配下だけを使う。
    base = SCRIPT_DIR.parents[3] / "artifacts" / SCRIPT_DIR.parent.name
    path = Path(value).absolute()
    require(base == base.resolve(), "artifacts保存先のsymlinkは辿れません。")
    require(path.exists() and path.is_dir() and not path.is_symlink()
            and path == path.resolve() and within(path, base.resolve()) and path != base.resolve(),
            "実行フォルダはこのスキルのartifacts配下の実体ディレクトリに限ります。")
    require(not (path.stat().st_mode & 0o077), "実行フォルダは所有者だけがアクセスできる権限にしてください。")
    return path


def atomic_write(path, value, exclusive=False):
    raw = json.dumps(value, ensure_ascii=True, sort_keys=True, indent=2).encode("ascii") + b"\n"
    if path.exists() or path.is_symlink():
        require(not exclusive, "既存の実行状態は上書きできません。新しい実行フォルダを作ってください。")
        safe_read(path, MAX_JSON, True)
    temporary = path.parent / (".gate-write-" + os.urandom(12).hex())
    fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        os.replace(str(temporary), str(path))
    finally:
        if temporary.exists():
            temporary.unlink()


@contextmanager
def locked(run):
    path = run / ".gate-lock"
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.close(fd)
    try:
        yield
    finally:
        path.unlink()


def array(value, nonempty=False):
    require(type(value) is list and len(value) <= MAX_ITEMS and (not nonempty or bool(value)), "配列が空、型が不正、または上限超過です。")
    return value


def inventory(run, filename):
    data = load_json(run / relative_path(filename))
    object_keys(data, ("before", "after"))
    sides = []
    for side in ("before", "after"):
        packages = {}
        for item in array(data[side], side == "after"):
            object_keys(item, ("id", "component", "ecosystem", "kind", "name", "version", "source"))
            for key in item:
                text_value(item[key])
            require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/@+!-]{0,199}", item["id"])
                    and item["id"] not in packages, "依存IDが重複、または不正です。")
            require(item["ecosystem"] in ECOSYSTEMS and item["kind"] in ("runtime", "direct", "transitive", "build"), "依存の系統・種類が未対応です。")
            relative_path(item["component"])
            require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+!-]{0,199}", item["version"]), "解決版が正確な版表記ではありません。")
            packages[item["id"]] = item
        sides.append(packages)
    before, after = sides
    changed = {key: item for key, item in after.items() if before.get(key) != item}
    require(bool(changed), "変更候補がありません。更新コマンドは実行しません。")
    return before, changed


def read_plan(run, filename):
    plan = load_json(run / relative_path(filename))
    object_keys(plan, ("schema_version", "unit", "files", "inventory", "candidates", "audits", "execution"))
    require(type(plan["schema_version"]) is int and plan["schema_version"] == 1, "未対応の計画形式です。")
    text_value(plan["unit"])
    paths = [str(relative_path(p)) for p in array(plan["files"], True)]
    require(len(paths) == len(set(paths)), "監視ファイルが重複しています。")
    before, changed = inventory(run, plan["inventory"])
    seen = set()
    candidates = array(plan["candidates"], True)
    require(len(candidates) <= MAX_CANDIDATES, "候補が200件を超えています。独立した更新計画に分割してください。")
    for candidate in candidates:
        object_keys(candidate, ("id", "published_at", "stability", "compatibility", "artifacts"))
        key = text_value(candidate["id"])
        require(key in changed and key not in seen, "候補IDが変更一覧と不一致、または重複しています。")
        seen.add(key)
        require(candidate["stability"] in ("stable", "prerelease", "unknown")
                and candidate["compatibility"] in ("compatible", "migration", "unknown"), "候補の分類が未対応です。")
        if candidate["published_at"] is not None:
            utc_time(candidate["published_at"])
        artifact_paths = set()
        for artifact in array(candidate["artifacts"], True):
            object_keys(artifact, ("path", "sha256"))
            path = str(relative_path(artifact["path"]))
            require(path not in artifact_paths and re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"] or ""), "配布物のパス・SHA256が不正です。")
            artifact_paths.add(path)
    require(seen == set(changed), "直接・間接・ビルド依存の変更候補に抜けがあります。")
    audits = set()
    for audit in array(plan["audits"]):
        object_keys(audit, ("ecosystem", "component", "format", "path", "exit_code", "checked_at"))
        pair = (audit["ecosystem"], audit["component"])
        require(audit["ecosystem"] in ECOSYSTEMS and audit["format"] == FORMATS[audit["ecosystem"]]
                and pair not in audits, "監査の対応形式・範囲が不正、または重複しています。")
        audits.add(pair)
        relative_path(audit["component"])
        relative_path(audit["path"])
        require(type(audit["exit_code"]) is int, "監査の終了コードが未確認です。")
        utc_time(audit["checked_at"])
    needed = {(p["ecosystem"], p["component"]) for p in changed.values() if p["kind"] != "runtime"}
    require(needed <= audits, "変更した系統・サブプロジェクトの監査JSONが不足しています。")
    execution = plan["execution"]
    object_keys(execution, ("argv", "config", "mechanism"))
    argv = array(execution["argv"], True)
    require(len(argv) <= 100, "実行引数が多すぎます。")
    for arg in argv:
        text_value(arg, 4000)
    require(Path(argv[0]).is_absolute() and execution["mechanism"] in ("container", "vm", "os-sandbox"), "絶対パスの既存隔離executorが必要です。")
    require(Path(argv[0]).name not in ("sh", "bash", "zsh", "fish", "python", "python3", "ruby", "node", "npm", "pnpm", "yarn", "pip", "uv", "bundle"), "ホストのシェル・ランタイム・依存管理コマンドをexecutorにはできません。")
    relative_path(execution["config"])
    return plan, before, changed


def candidate_tree(root):
    result = {}
    directories = {}
    total = 0
    nodes = 0
    def walk_error(_error):
        raise GateError("候補ソースのディレクトリを完全に読めません。")
    for directory, dirs, files in os.walk(str(root), followlinks=False, onerror=walk_error):
        info = Path(directory).lstat()
        require(stat.S_ISDIR(info.st_mode) and (info.st_mode & 0o500) == 0o500,
                "候補ディレクトリの読取り・探索権限が不足しています。")
        nodes += 1
        require(nodes <= MAX_FILES, "候補ソースのファイル・ディレクトリが5000件を超えています。")
        relative = Path(directory).relative_to(root).as_posix()
        directories[relative] = {"mode": stat.S_IMODE(info.st_mode)}
        require(".git" not in dirs and ".git" not in files, "候補コピーから.gitを除いてください。")
        for name in sorted(dirs):
            path = Path(directory) / name
            require(not path.is_symlink(), "候補ソース内のsymlinkは扱えません。")
        dirs[:] = sorted(dirs)
        for name in sorted(files):
            require(not (name.startswith(".env") and name not in (".env.example", ".env.sample")), "候補ソースから.env等を除き、ダミー設定を使ってください。")
            path = Path(directory) / name
            data = safe_read(path, MAX_TREE)
            total += len(data)
            nodes += 1
            require(total <= MAX_TREE and nodes <= MAX_FILES, "候補ソースが64MiB・5000項目の上限を超えています。最小コピーを使ってください。")
            result[path.relative_to(root).as_posix()] = {"sha256": digest(data), "mode": stat.S_IMODE(path.stat().st_mode)}
    require(bool(result), "候補ソースが空です。")
    return {"files": result, "directories": directories}


def bindings(run, state):
    plan, before, changed = read_plan(run, state["plan_file"])
    project, candidate = Path(state["project"]), Path(state["candidate"])
    require(project == project.resolve() and candidate == candidate.resolve()
            and project.is_dir() and candidate.is_dir(), "プロジェクト・候補の実体が変わっています。")
    require(not within(candidate, project) and not within(project, candidate)
            and not within(run, candidate) and not within(candidate, run), "候補コピー・対象・実行記録は分離してください。")
    watched = {}
    for name in plan["files"]:
        for label, root in (("project", project), ("candidate", candidate)):
            path = root / relative_path(name)
            watched[label + ":" + name] = file_digest(path) if path.exists() or path.is_symlink() else None
    require(any(value is not None for value in watched.values()), "監視するmanifest・lockfile・設定がありません。")
    artifacts = {}
    artifact_total = 0
    for entry in plan["candidates"]:
        for artifact in entry["artifacts"]:
            path = run / relative_path(artifact["path"])
            artifact_total += path.stat().st_size
            require(artifact_total <= MAX_ARTIFACT_TOTAL, "配布物の合計が512MiBを超えています。計画を分割してください。")
            artifacts[artifact["path"]] = file_digest(path)
    audits = {a["path"]: file_digest(run / relative_path(a["path"]), MAX_JSON) for a in plan["audits"]}
    executor = Path(plan["execution"]["argv"][0])
    require(os.access(str(executor), os.X_OK) and not within(executor, candidate), "隔離executorが実行不能、または候補コード内にあります。")
    require(not (executor.stat().st_mode & 0o022), "隔離executorのgroup/other書込み権限を除いてください。")
    bound = {"run": str(run), "skill": SCRIPT_DIR.parent.name,
             "plan": plan, "inventory_sha256": file_digest(run / relative_path(plan["inventory"]), MAX_JSON),
             "project": str(project), "candidate": str(candidate), "watched": watched,
             "candidate_tree": candidate_tree(candidate), "artifacts": artifacts, "audits": audits,
             "executor_sha256": file_digest(executor), "executor_mode": stat.S_IMODE(executor.stat().st_mode),
             "config_sha256": digest(safe_read(run / relative_path(plan["execution"]["config"]), MAX_JSON, True)),
             "tools": {name: file_digest(SCRIPT_DIR / name) for name in ("supply-chain.py", "archive_inspector.py", "audit_report.py")},
             "environment": CHILD_ENV}
    return digest(canonical(bound)), plan, before, changed


def load_state(run):
    state = load_json(run / STATE)
    object_keys(state, ("schema_version", "plan_file", "project", "candidate", "binding", "created_at", "reviews", "execution_status"), ("exit_code",))
    require(type(state["schema_version"]) is int and state["schema_version"] == 1
            and type(state["reviews"]) is dict and set(state["reviews"]) == set(REVIEWS), "実行状態の形式・必須レビューが不正です。")
    require(state["execution_status"] in ("not_started", "running", "succeeded", "failed"), "実行状態が未対応です。")
    for review in state["reviews"].values():
        object_keys(review, ("status",), ("evidence", "sha256", "checked_at", "binding", "note"))
        require(review["status"] in ("pass", "fail", "unknown"), "未対応のレビュー状態です。skipは使えません。")
    return state


def assert_binding(run, state):
    current = bindings(run, state)
    require(current[0] == state["binding"], "計画・ソース・設定・配布物・監査・executorが変更されています。新しい実行で再確認してください。")
    return current


def compatible_runtime(old, new, ecosystem):
    if old is None:
        return False
    a = re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", old)
    b = re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", new)
    if not a or not b:
        return False
    x, y = tuple(map(int, a.groups())), tuple(map(int, b.groups()))
    return x < y and (x[0] == y[0] if ecosystem == "node" else x[:2] == y[:2])


def checks(run, state):
    binding, plan, before, changed = assert_binding(run, state)
    require(state["execution_status"] == "not_started", "実行済み・失敗・実行中の計画は再利用できません。")
    now = datetime.now(timezone.utc)
    signals = []
    for item in plan["candidates"]:
        package = changed[item["id"]]
        require(item["stability"] == "stable" and item["published_at"] is not None, "安定版・公開日時が未確認です。")
        require(now - utc_time(item["published_at"]) >= MIN_RELEASE_AGE, "公開から7日未満、または未来日時です。")
        if SCRIPT_DIR.parent.name == "minor-version-upgrade":
            require(item["compatibility"] == "compatible", "互換性未確認・個別移行の候補は一括更新できません。")
            previous = before.get(item["id"])
            if package["kind"] == "runtime":
                require(compatible_runtime(previous["version"] if previous else None, package["version"], package["ecosystem"]), "ランタイムの系列変更を一括更新できません。")
            elif previous:
                old = re.fullmatch(r"([0-9]+)\.([0-9]+)\.([0-9]+)", previous["version"])
                new = re.fullmatch(r"([0-9]+)\.([0-9]+)\.([0-9]+)", package["version"])
                if old and new:
                    x, y = tuple(map(int, old.groups())), tuple(map(int, new.groups()))
                    require(x < y and x[0] == y[0] and (x[0] != 0 or x[1] == y[1]), "依存のmajor・0.xのminor変更・同版・downgradeを一括更新できません。")
        else:
            require(item["compatibility"] != "unknown", "個別移行の分類が未確認です。")
        require(not re.search(r"alpha|beta|preview|dev|rc[0-9]*", package["version"], re.I), "prereleaseの疑いがある版は採用できません。")
        for artifact in item["artifacts"]:
            path = run / relative_path(artifact["path"])
            require(file_digest(path) == artifact["sha256"], "配布物のSHA256が期待値と一致しません。")
            report = inspect_artifact(path)
            signals.append({"id": item["id"], "path": artifact["path"], "inspection": report})
            require(sum(len(item["inspection"]["signals"]) for item in signals) <= 20000, "静的検査の兆候合計が20000件を超えています。計画を分割してください。")
    for audit in plan["audits"]:
        require(audit["exit_code"] == 0, "監査コマンドが失敗、または未確認です。")
        fresh(audit["checked_at"], now)
        report = inspect_audit(run / relative_path(audit["path"]), audit["format"])
        require(report["findings"] == 0, "監査で問題が検出されています。対象を解消・分離してください。")
        if audit["format"] == "bundler-audit":
            metadata = load_json(run / relative_path(audit["path"]))
            generated = datetime.strptime(metadata["created_at"], "%Y-%m-%d %H:%M:%S %z").astimezone(timezone.utc)
            require(timedelta(0) <= now - generated <= MAX_AGE, "bundler-auditの生成日時が未来、または24時間超です。")
        if audit["ecosystem"] == "python":
            normalize = lambda name: re.sub(r"[-_.]+", "-", name).lower()
            covered = {(normalize(p["name"]), p["version"]) for p in report["packages"]}
            required = {(normalize(p["name"]), p["version"]) for p in changed.values()
                        if p["ecosystem"] == "python" and p["component"] == audit["component"] and p["kind"] != "runtime"}
            require(required <= covered, "Python監査の対象版に抜けがあります。")
    # 未確認レビューで停止する場合も、先に静的検査の根拠を保存する。
    # 同じ入力では同じ内容にし、このファイルを参照する証拠を無効化しない。
    atomic_write(run / "automated-checks.json", {"binding": binding, "artifacts": signals})
    for name in REVIEWS:
        review = state["reviews"][name]
        require(review["status"] == "pass", "必須レビューが失敗・未確認です: " + name)
        object_keys(review, ("status", "evidence", "sha256", "checked_at", "binding", "note"))
        require(review["binding"] == binding, "レビューが別の実行計画に対するものです。")
        fresh(review["checked_at"], now)
        text_value(review["note"], 2000)
        evidence = safe_read(run / relative_path(review["evidence"]), MAX_JSON, True)
        require(digest(evidence) == review["sha256"], "レビュー証拠が変更されています。")
    return plan, signals


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    init = sub.add_parser("init", help="計画と入力を固定し、全レビューをunknownにする")
    for key in ("run", "project", "candidate", "plan"):
        init.add_argument("--" + key, required=True)
    review = sub.add_parser("review", help="証拠付きのレビュー結果を記録する")
    review.add_argument("--run", required=True)
    review.add_argument("--check", choices=REVIEWS, required=True)
    review.add_argument("--status", choices=("pass", "fail", "unknown"), required=True)
    review.add_argument("--evidence")
    review.add_argument("--note", required=True)
    for action in ("check", "run"):
        command = sub.add_parser(action)
        command.add_argument("--run", required=True)
    args = parser.parse_args()
    run = run_directory(args.run)
    with locked(run):
        if args.action == "init":
            plan_path = Path(args.plan).absolute()
            require(within(plan_path, run) and plan_path != run, "計画JSONは実行フォルダ内に保存してください。")
            state = {"schema_version": 1, "plan_file": plan_path.relative_to(run).as_posix(),
                     "project": str(Path(args.project).resolve(strict=True)),
                     "candidate": str(Path(args.candidate).resolve(strict=True)),
                     "binding": "", "created_at": now_string(),
                     "reviews": {name: {"status": "unknown"} for name in REVIEWS}, "execution_status": "not_started"}
            state["binding"] = bindings(run, state)[0]
            atomic_write(run / STATE, state, exclusive=True)
            print(json.dumps({"status": "blocked", "required_reviews": list(REVIEWS)}, ensure_ascii=True))
            return 0
        state = load_state(run)
        if args.action == "review":
            assert_binding(run, state)
            require(state["execution_status"] == "not_started", "実行後のレビューは変更できません。")
            text_value(args.note, 2000)
            entry = {"status": args.status, "note": args.note, "binding": state["binding"], "checked_at": now_string()}
            if args.status == "pass":
                require(args.evidence is not None, "passには非空の証拠ファイルが必要です。")
            if args.evidence is not None:
                entry["evidence"] = relative_path(args.evidence).as_posix()
                entry["sha256"] = digest(safe_read(run / relative_path(args.evidence), MAX_JSON, True))
            state["reviews"][args.check] = entry
            atomic_write(run / STATE, state)
            print(json.dumps({"check": args.check, "status": args.status}, ensure_ascii=True))
            return 0
        plan, signals = checks(run, state)
        if args.action == "check":
            print(json.dumps({"status": "passed", "binding": state["binding"]}, ensure_ascii=True))
            return 0
        # 直前にも同一入力を確認。runは失敗を含め一度だけ。任意のhost shellは使わない。
        checks(run, state)
        state["execution_status"] = "running"
        atomic_write(run / STATE, state)
        try:
            result = subprocess.run(plan["execution"]["argv"], cwd=state["candidate"], env=dict(CHILD_ENV),
                                    shell=False, check=False, timeout=1800)
            code = result.returncode
        except (OSError, subprocess.SubprocessError):
            code = 1
        state["execution_status"] = "succeeded" if code == 0 else "failed"
        state["exit_code"] = code
        atomic_write(run / STATE, state)
        print(json.dumps({"status": state["execution_status"], "exit_code": code}, ensure_ascii=True))
        return 0 if code == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GateError as error:
        # GateErrorの文面はこのスクリプトの固定文と固定チェック名だけ。
        print("更新を停止しました: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (InspectionError, AuditError, OSError, UnicodeError, ValueError, TypeError, KeyError, OverflowError, RecursionError):
        # 証拠や監査レポートの秘密値・外部入力を例外に転載しない。
        print("更新を停止しました。必須項目・証拠・鮮度・入力の整合を確認してください。", file=sys.stderr)
        sys.exit(1)
