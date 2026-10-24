#!/usr/bin/env python3
"""供給網ゲートの拒否・固定・一度限り実行を外部取得なしで検証する。

実行: python3 -I -S -m unittest discover -s scripts/tests -p 'test_supply_chain_gate.py' -v
executor は marker を書くだけの信頼済み fixture。隔離機能自体は検証しない。
"""

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[2]
SKILLS = REPO / ".agents" / "skills"
MINOR = "minor-version-upgrade"
MAJOR = "major-version-upgrade"
TEMP_ROOT = str(Path(tempfile.gettempdir()).resolve())
REVIEWS = ("coverage", "sources", "artifacts", "advisories", "authenticity", "isolation", "compatibility")


def timestamp(delta=timedelta()):
    return (datetime.now(timezone.utc) + delta).isoformat(timespec="seconds").replace("+00:00", "Z")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def tar_bytes(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, content in entries:
            info = tarfile.TarInfo(name)
            info.size = len(content)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(content))
    return stream.getvalue()


def zip_bytes(entries):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in entries:
            archive.writestr(name, content)
    return stream.getvalue()


def gem_bytes(entries):
    return tar_bytes([
        ("metadata.gz", gzip.compress(b"---\nname: demo\nversion: 1.1.0\n")),
        ("data.tar.gz", gzip.compress(tar_bytes(entries))),
    ])


def npm_report(finding=False):
    vulnerabilities = {}
    counts = dict.fromkeys(("info", "low", "moderate", "high", "critical", "total"), 0)
    if finding:
        vulnerabilities["demo"] = {
            "name": "demo", "severity": "high", "isDirect": True,
            "via": [{"source": 1, "name": "demo", "dependency": "demo", "title": "fixture advisory",
                     "url": "https://example.invalid/advisory", "severity": "high", "range": "<2.0.0"}],
            "effects": [], "range": "<2.0.0", "nodes": ["node_modules/demo"], "fixAvailable": False,
        }
        counts["high"] = counts["total"] = 1
    return {
        "auditReportVersion": 2, "vulnerabilities": vulnerabilities,
        "metadata": {"vulnerabilities": counts,
                     "dependencies": {"prod": 1, "dev": 0, "optional": 0, "peer": 0, "peerOptional": 0, "total": 1}},
    }


def pip_report(name="demo", version="1.1.0"):
    return {"dependencies": [{"name": name, "version": version, "vulns": []}], "fixes": []}


def bundler_report():
    return {"version": "0.9.2", "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S %z"), "results": []}


class Fixture:
    """実際の CLI の入出力を使い、production の判定関数は呼び出さない。"""

    def __init__(self, testcase, skill=MINOR):
        self.testcase = testcase
        self.skill = skill
        self.cli = SKILLS / skill / "scripts" / "supply-chain.py"
        self.temporary = tempfile.TemporaryDirectory(prefix="supply-gate-test-", dir=TEMP_ROOT)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        self.candidate = self.root / "candidate"
        for root, version in ((self.project, "1.0.0"), (self.candidate, "1.1.0")):
            (root / "app").mkdir(parents=True)
            self.json(root / "app" / "package.json", {"name": "fixture-app", "version": version})
            self.json(root / "app" / "package-lock.json", {"lockfileVersion": 3, "fixture": version})
            (root / "app" / "index.js").write_text("module.exports = 1;\n", encoding="utf-8")
        # 実行記録の保存先制約も実際のCLIで検証する。
        artifact_root = REPO / "artifacts" / skill
        artifact_root.mkdir(parents=True, exist_ok=True)
        self.run_temporary = tempfile.TemporaryDirectory(prefix="gate-test-", dir=str(artifact_root))
        self.run_dir = Path(self.run_temporary.name)
        self.run_dir.chmod(0o700)
        self.marker = self.root / "invocations.jsonl"
        self.launcher = self.root / "trusted-test-executor"
        # あくまで信頼済みの launcher。実プロジェクトのコードやshellは実行しない。
        self.launcher.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, pathlib, sys\n"
            "record = {'argv': sys.argv[2:], 'cwd': os.getcwd(), 'environment': dict(os.environ)}\n"
            "with open(sys.argv[1], 'a', encoding='utf-8') as output:\n"
            "    output.write(json.dumps(record) + '\\n')\n"
            "raise SystemExit(int(sys.argv[3]))\n", encoding="utf-8")
        self.launcher.chmod(0o700)
        self.inventory = {
            "before": [self.package("1.0.0")],
            "after": [self.package("1.1.0")],
        }
        self.artifact = "packages/demo-1.1.0.tgz"
        self.artifact_bytes = gzip.compress(tar_bytes([("package/package.json", b'{"name":"demo","version":"1.1.0"}'),
                                                      ("package/index.js", b"module.exports = 1;\n")]))
        self.audit = npm_report()
        self.plan = {
            "schema_version": 1, "unit": "demo", "files": ["app/package.json", "app/package-lock.json"],
            "inventory": "inventory.json",
            "candidates": [{"id": "node:demo", "published_at": timestamp(-timedelta(days=10)),
                            "stability": "stable", "compatibility": "compatible",
                            "artifacts": [{"path": self.artifact, "sha256": sha256(self.artifact_bytes)}]}],
            "audits": [{"ecosystem": "node", "component": "app", "format": "npm-v2", "path": "audit.json",
                        "exit_code": 0, "checked_at": timestamp()}],
            "execution": {"argv": [str(self.launcher), str(self.marker), "approved-argument", "0"],
                          "config": "isolation.json", "mechanism": "os-sandbox"},
        }
        self.flush()

    @staticmethod
    def package(version, ecosystem="node", kind="direct", name="demo"):
        return {"id": ecosystem + ":" + name, "component": "app", "ecosystem": ecosystem,
                "kind": kind, "name": name, "version": version, "source": "https://example.invalid/registry"}

    @staticmethod
    def json(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")

    def flush(self):
        self.json(self.run_dir / "plan.json", self.plan)
        self.json(self.run_dir / "inventory.json", self.inventory)
        self.json(self.run_dir / "audit.json", self.audit)
        self.json(self.run_dir / "isolation.json", {"fixture": "already reviewed trusted test launcher"})
        artifact_path = self.run_dir / self.artifact
        artifact_path.parent.mkdir(parents=True, exist_ok=True)
        artifact_path.write_bytes(self.artifact_bytes)

    def command(self, action, *arguments):
        return subprocess.run([sys.executable, "-I", "-S", str(self.cli), action,
                               "--run", str(self.run_dir)] + list(arguments),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=20)

    def init(self):
        return self.command("init", "--project", str(self.project), "--candidate", str(self.candidate),
                            "--plan", str(self.run_dir / "plan.json"))

    def require_ok(self, result):
        self.testcase.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def approve(self, except_checks=()):
        for check in REVIEWS:
            if check not in except_checks:
                evidence = "evidence/" + check + ".txt"
                path = self.run_dir / evidence
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("reviewed fixture inputs for " + check + "\n", encoding="utf-8")
                self.require_ok(self.command("review", "--check", check, "--status", "pass", "--evidence", evidence,
                                             "--note", "fixtureの証拠と対象範囲を確認"))

    def ready(self):
        self.flush()
        self.require_ok(self.init())
        self.approve()

    def state(self):
        return json.loads((self.run_dir / "gate-state.json").read_text(encoding="utf-8"))

    def write_state(self, state):
        self.json(self.run_dir / "gate-state.json", state)

    def invocations(self):
        if not self.marker.exists():
            return []
        return [json.loads(line) for line in self.marker.read_text(encoding="utf-8").splitlines()]

    def blocked(self, action="run"):
        result = self.command(action)
        self.testcase.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.testcase.assertFalse(self.marker.exists(), "拒否すべき入力でexecutorが起動した")
        return result

    def runtime(self, ecosystem, before, after):
        self.inventory = {"before": [self.package(before, ecosystem, "runtime", ecosystem)],
                          "after": [self.package(after, ecosystem, "runtime", ecosystem)]}
        self.plan["candidates"][0]["id"] = ecosystem + ":" + ecosystem
        self.plan["audits"] = []

    def close(self):
        self.run_temporary.cleanup()
        self.temporary.cleanup()


class GateTests(unittest.TestCase):
    @contextmanager
    def fixture(self, skill=MINOR):
        fixture = Fixture(self, skill)
        try:
            yield fixture
        finally:
            fixture.close()

    def test_approved_plan_runs_exact_argv_once_and_check_never_executes(self):
        for skill in (MINOR, MAJOR):
            with self.subTest(skill=skill), self.fixture(skill) as f:
                f.ready()
                f.require_ok(f.command("check"))
                self.assertFalse(f.marker.exists())
                f.require_ok(f.command("run"))
                calls = f.invocations()
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0]["argv"], ["approved-argument", "0"])
                self.assertEqual(calls[0]["cwd"], str(f.candidate))
                self.assertNotIn("HOME", calls[0]["environment"])
                self.assertNotIn("SSH_AUTH_SOCK", calls[0]["environment"])
                self.assertEqual(f.state()["execution_status"], "succeeded")
                self.assertEqual(f.state()["exit_code"], 0)
                self.assertNotEqual(f.command("run").returncode, 0)
                self.assertNotEqual(f.command("check").returncode, 0)
                self.assertEqual(len(f.invocations()), 1)

    def test_executor_failure_is_recorded_and_cannot_be_reused(self):
        with self.fixture() as f:
            f.plan["execution"]["argv"][-1] = "7"
            f.ready()
            self.assertNotEqual(f.command("run").returncode, 0)
            self.assertEqual(f.state()["execution_status"], "failed")
            self.assertEqual(f.state()["exit_code"], 7)
            self.assertEqual(len(f.invocations()), 1)
            self.assertNotEqual(f.command("run").returncode, 0)
            self.assertEqual(len(f.invocations()), 1)

    def test_unreadable_candidate_directory_is_not_silently_skipped(self):
        with self.fixture() as f:
            unreadable = f.candidate / "hidden"
            unreadable.mkdir()
            (unreadable / "payload.js").write_text("module.exports = 2;\n", encoding="utf-8")
            unreadable.chmod(0)
            try:
                self.assertNotEqual(f.init().returncode, 0)
                self.assertFalse(f.marker.exists())
            finally:
                unreadable.chmod(0o700)

    def test_directory_permission_change_invalidates_approval(self):
        with self.fixture() as f:
            f.ready()
            directory = f.candidate / "app"
            directory.chmod(stat.S_IMODE(directory.stat().st_mode) ^ 0o010)
            f.blocked()

    def test_copied_approval_cannot_authorize_another_run(self):
        with self.fixture() as f:
            f.ready()
            with tempfile.TemporaryDirectory(prefix="copied-gate-", dir=str(f.run_dir.parent)) as value:
                copied = Path(value)
                copied.chmod(0o700)
                shutil.copytree(f.run_dir, copied, dirs_exist_ok=True)
                result = subprocess.run([sys.executable, "-I", "-S", str(f.cli), "run", "--run", str(copied)],
                                        capture_output=True, text=True, timeout=20)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(f.marker.exists())

    def test_gate_requires_isolated_python_without_site_startup(self):
        with self.fixture() as f:
            for flags in (("-I",), ("-S",)):
                with self.subTest(flags=flags):
                    result = subprocess.run([sys.executable] + list(flags) + [str(f.cli), "check", "--run", str(f.run_dir)],
                                            capture_output=True, text=True, timeout=20)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(f.marker.exists())

    def test_missing_isolation_rejects_pythonpath_before_other_imports(self):
        with self.fixture() as f:
            payload = f.root / "untrusted-pythonpath"
            payload.mkdir()
            marker = f.root / "unexpected-startup"
            (payload / "argparse.py").write_text(
                "from pathlib import Path\nPath(" + repr(str(marker)) + ").write_text('unexpected import')\n",
                encoding="utf-8")
            result = subprocess.run([sys.executable, "-S", str(f.cli), "check", "--run", str(f.run_dir)],
                                    env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(payload)},
                                    capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertFalse(f.marker.exists())

    def test_all_unknown_and_each_missing_review_blocks_execution(self):
        with self.fixture() as f:
            f.require_ok(f.init())
            self.assertEqual({review["status"] for review in f.state()["reviews"].values()}, {"unknown"})
            f.blocked()
        for missing in REVIEWS:
            with self.subTest(missing=missing), self.fixture() as f:
                f.require_ok(f.init())
                f.approve(except_checks=(missing,))
                f.blocked()

    def test_fail_unknown_skip_and_removed_review_block_execution(self):
        for status in ("fail", "unknown", "skip", "removed"):
            with self.subTest(status=status), self.fixture() as f:
                f.ready()
                if status in ("fail", "unknown"):
                    f.require_ok(f.command("review", "--check", "sources", "--status", status, "--note", "保留"))
                else:
                    state = f.state()
                    if status == "removed":
                        del state["reviews"]["sources"]
                    else:
                        state["reviews"]["sources"]["status"] = status
                    f.write_state(state)
                f.blocked()

    def test_cli_rejects_skip_missing_and_empty_evidence(self):
        with self.fixture() as f:
            f.require_ok(f.init())
            for extra in (("--status", "skip"), ("--status", "pass"),
                          ("--status", "pass", "--evidence", "empty.txt")):
                with self.subTest(extra=extra):
                    (f.run_dir / "empty.txt").write_bytes(b"")
                    result = f.command("review", "--check", "sources", "--note", "fixture", *extra)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(f.marker.exists())
            f.blocked()

    def test_tampered_empty_missing_or_symlink_review_evidence_blocks(self):
        for mutation in ("changed", "empty", "missing", "symlink"):
            with self.subTest(mutation=mutation), self.fixture() as f:
                f.ready()
                evidence = f.run_dir / "evidence" / "sources.txt"
                if mutation == "changed":
                    evidence.write_text("modified evidence", encoding="utf-8")
                elif mutation == "empty":
                    evidence.write_bytes(b"")
                else:
                    contents = evidence.read_bytes()
                    evidence.unlink()
                    if mutation == "symlink":
                        target = f.root / "copied-evidence.txt"
                        target.write_bytes(contents)
                        evidence.symlink_to(target)
                f.blocked()

    def test_stale_future_or_wrong_binding_reviews_block(self):
        for mutation in ("stale", "future", "binding"):
            with self.subTest(mutation=mutation), self.fixture() as f:
                f.ready()
                state = f.state()
                review = state["reviews"]["sources"]
                if mutation == "binding":
                    review["binding"] = "0" * 64
                else:
                    review["checked_at"] = timestamp(timedelta(hours=-25 if mutation == "stale" else 1))
                f.write_state(state)
                f.blocked()

    def test_release_age_unknown_and_future_fail_closed(self):
        for published in (None, timestamp(-timedelta(days=6)), timestamp(timedelta(days=1))):
            with self.subTest(published=published), self.fixture() as f:
                f.plan["candidates"][0]["published_at"] = published
                f.ready()
                f.blocked()

    def test_unknown_prerelease_and_migration_do_not_enter_minor_batch(self):
        mutations = (("stability", "unknown"), ("stability", "prerelease"),
                     ("compatibility", "unknown"), ("compatibility", "migration"))
        for field, value in mutations:
            with self.subTest(field=field, value=value), self.fixture() as f:
                f.plan["candidates"][0][field] = value
                f.ready()
                f.blocked()

    def test_expected_digest_mismatch_blocks_even_with_pass_reviews(self):
        with self.fixture() as f:
            f.plan["candidates"][0]["artifacts"][0]["sha256"] = "0" * 64
            f.ready()
            f.blocked()

    def test_missing_duplicate_and_extra_candidates_fail_initialization(self):
        for mutation in ("missing", "duplicate", "extra"):
            with self.subTest(mutation=mutation), self.fixture() as f:
                if mutation == "missing":
                    f.inventory["after"].append(f.package("2.1.0", kind="transitive", name="indirect"))
                elif mutation == "duplicate":
                    f.plan["candidates"].append(dict(f.plan["candidates"][0]))
                else:
                    f.plan["candidates"][0]["id"] = "node:untracked"
                f.flush()
                self.assertNotEqual(f.init().returncode, 0)
                self.assertFalse(f.marker.exists())

    def test_removed_inventory_dependency_requires_reviewed_coverage(self):
        # 削除の認識をcoverage reviewに固定し、承認後のinventory差替えを拒否する。
        with self.fixture() as f:
            f.inventory["before"].append(f.package("1.0.0", kind="transitive", name="removed"))
            f.ready()
            f.inventory["before"].pop()
            f.json(f.run_dir / "inventory.json", f.inventory)
            f.blocked()

    def test_any_bound_input_change_prevents_execution(self):
        for mutation in ("project-manifest", "candidate-manifest", "source", "inventory-source", "plan", "argv",
                         "executor", "config", "audit", "artifact"):
            with self.subTest(mutation=mutation), self.fixture() as f:
                f.ready()
                if mutation == "project-manifest":
                    (f.project / "app" / "package.json").write_text("{}\n", encoding="utf-8")
                elif mutation == "candidate-manifest":
                    (f.candidate / "app" / "package.json").write_text("{}\n", encoding="utf-8")
                elif mutation == "source":
                    (f.candidate / "app" / "index.js").write_text("module.exports = 2;\n", encoding="utf-8")
                elif mutation == "inventory-source":
                    f.inventory["after"][0]["source"] = "https://other.invalid/registry"
                    f.json(f.run_dir / "inventory.json", f.inventory)
                elif mutation in ("plan", "argv"):
                    if mutation == "plan":
                        f.plan["unit"] = "different-unit"
                    else:
                        f.plan["execution"]["argv"].append("unapproved-argument")
                    f.json(f.run_dir / "plan.json", f.plan)
                elif mutation == "executor":
                    with f.launcher.open("a", encoding="utf-8") as stream:
                        stream.write("# changed launcher\n")
                elif mutation == "config":
                    f.json(f.run_dir / "isolation.json", {"fixture": "different isolation policy"})
                elif mutation == "audit":
                    f.json(f.run_dir / "audit.json", npm_report(finding=True))
                else:
                    (f.run_dir / f.artifact).write_bytes(b"changed distribution")
                f.blocked()

    def test_symlink_hardlink_and_fifo_inputs_are_not_read_or_executed(self):
        for mutation in ("manifest-symlink", "source-symlink", "source-directory-symlink", "source-hardlink", "source-fifo",
                         "artifact-symlink", "artifact-fifo", "audit-symlink", "config-symlink", "executor-symlink"):
            with self.subTest(mutation=mutation), self.fixture() as f:
                if mutation.startswith("manifest"):
                    target = f.candidate / "app" / "package.json"
                elif mutation.startswith("source-directory"):
                    target = f.candidate / "linked-directory"
                    target.symlink_to(f.project / "app", target_is_directory=True)
                    self.assertNotEqual(f.init().returncode, 0)
                    self.assertFalse(f.marker.exists())
                    continue
                elif mutation.startswith("source"):
                    target = f.candidate / "app" / "index.js"
                elif mutation.startswith("artifact"):
                    target = f.run_dir / f.artifact
                elif mutation.startswith("audit"):
                    target = f.run_dir / "audit.json"
                elif mutation.startswith("config"):
                    target = f.run_dir / "isolation.json"
                else:
                    target = f.launcher
                copy = f.root / "trusted-copy"
                copy.write_bytes(target.read_bytes())
                copy.chmod(0o700)
                target.unlink()
                if mutation.endswith("fifo"):
                    os.mkfifo(str(target), 0o600)
                elif mutation.endswith("hardlink"):
                    os.link(str(copy), str(target))
                else:
                    target.symlink_to(copy)
                self.assertNotEqual(f.init().returncode, 0)
                self.assertFalse(f.marker.exists())

    def test_broken_archive_zip_traversal_and_gem_inner_traversal_block(self):
        archives = (("packages/broken.tgz", b"not a gzip archive"),
                    ("packages/traversal.whl", zip_bytes([("../outside.py", b"fixture")])),
                    ("packages/traversal.gem", gem_bytes([("../outside.rb", b"fixture")])) )
        for path, data in archives:
            with self.subTest(path=path), self.fixture() as f:
                f.artifact = path
                f.artifact_bytes = data
                f.plan["candidates"][0]["artifacts"] = [{"path": path, "sha256": sha256(data)}]
                f.ready()
                f.blocked()
                self.assertFalse((f.root / "outside.py").exists())
                self.assertFalse((f.root / "outside.rb").exists())

    def test_audit_failure_findings_and_invalid_reports_block(self):
        for mutation in ("exit", "finding", "error", "skipped", "unsupported", "old-schema", "stale", "future", "missing"):
            with self.subTest(mutation=mutation), self.fixture() as f:
                audit = f.plan["audits"][0]
                if mutation == "exit":
                    audit["exit_code"] = 1
                elif mutation == "finding":
                    f.audit = npm_report(finding=True)
                elif mutation == "error":
                    f.audit = {"error": {"code": "OFFLINE", "summary": "fixture"}}
                elif mutation == "skipped":
                    f.audit["skipped"] = ["demo"]
                elif mutation == "unsupported":
                    audit["format"] = "unrecognized-audit"
                elif mutation == "old-schema":
                    f.audit["auditReportVersion"] = 1
                elif mutation in ("stale", "future"):
                    audit["checked_at"] = timestamp(timedelta(hours=-25 if mutation == "stale" else 1))
                else:
                    f.plan["audits"] = []
                f.flush()
                initialized = f.init()
                if initialized.returncode == 0:
                    f.approve()
                    f.blocked()
                else:
                    self.assertIn(mutation, ("unsupported", "missing"))
                    self.assertFalse(f.marker.exists())

    def test_python_audit_requires_exact_normalized_name_and_version(self):
        for report_name, report_version, succeeds in (("Demo_Package", "1.1.0", True), ("demo-package", "1.0.0", False),
                                                      ("different-package", "1.1.0", False)):
            with self.subTest(name=report_name, version=report_version), self.fixture() as f:
                f.inventory = {"before": [f.package("1.0.0", "python", name="demo-package")],
                               "after": [f.package("1.1.0", "python", name="demo-package")]}
                f.plan["candidates"][0]["id"] = "python:demo-package"
                f.plan["audits"][0].update(ecosystem="python", format="pip-audit")
                f.audit = pip_report(report_name, report_version)
                f.ready()
                if succeeds:
                    f.require_ok(f.command("run"))
                    self.assertEqual(len(f.invocations()), 1)
                else:
                    f.blocked()

    def test_bundler_report_generation_time_must_also_be_fresh(self):
        for hours, succeeds in ((0, True), (-25, False), (1, False)):
            with self.subTest(hours=hours), self.fixture() as f:
                f.inventory = {"before": [f.package("1.0.0", "ruby")],
                               "after": [f.package("1.1.0", "ruby")]}
                f.plan["candidates"][0]["id"] = "ruby:demo"
                f.plan["audits"][0].update(ecosystem="ruby", format="bundler-audit")
                f.audit = bundler_report()
                f.audit["created_at"] = (datetime.now(timezone.utc) + timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M:%S %z")
                f.ready()
                if succeeds:
                    f.require_ok(f.command("run"))
                    self.assertEqual(len(f.invocations()), 1)
                else:
                    f.blocked()

    def test_minor_runtime_allows_only_ecosystem_compatible_series(self):
        cases = (("ruby", "3.3.7", "3.3.8", True), ("ruby", "3.3.7", "3.4.0", False),
                 ("python", "3.12.5", "3.12.6", True), ("python", "3.12.5", "3.13.0", False),
                 ("node", "20.10.0", "20.11.0", True), ("node", "20.10.0", "22.0.0", False),
                 ("node", "20.10.0", "20.9.0", False))
        for ecosystem, before, after, succeeds in cases:
            with self.subTest(ecosystem=ecosystem, after=after), self.fixture() as f:
                f.runtime(ecosystem, before, after)
                f.ready()
                if succeeds:
                    f.require_ok(f.command("run"))
                    self.assertEqual(len(f.invocations()), 1)
                else:
                    f.blocked()

    def test_minor_rejects_indirect_major_and_zero_minor_changes(self):
        for old, new in (("1.0.0", "2.0.0"), ("0.1.0", "0.2.0")):
            with self.subTest(old=old, new=new), self.fixture() as f:
                f.inventory["before"][0].update(version=old, kind="transitive")
                f.inventory["after"][0].update(version=new, kind="transitive")
                f.ready()
                f.blocked()

    def test_major_migration_allows_series_change_and_still_requires_classification(self):
        for compatibility in ("migration", "unknown"):
            with self.subTest(compatibility=compatibility), self.fixture(MAJOR) as f:
                f.runtime("ruby", "3.3.7", "3.4.0")
                f.plan["candidates"][0]["compatibility"] = compatibility
                f.ready()
                if compatibility == "migration":
                    f.require_ok(f.command("run"))
                    self.assertEqual(len(f.invocations()), 1)
                else:
                    f.blocked()

    def test_major_unit_must_be_nonempty_and_fixed_after_review(self):
        with self.fixture(MAJOR) as f:
            f.plan["unit"] = ""
            f.flush()
            self.assertNotEqual(f.init().returncode, 0)
            self.assertFalse(f.marker.exists())
        with self.fixture(MAJOR) as f:
            f.ready()
            f.plan["unit"] = "unreviewed second upgrade"
            f.json(f.run_dir / "plan.json", f.plan)
            f.blocked()

    def test_in_progress_state_and_second_init_cannot_reuse_plan(self):
        with self.fixture() as f:
            f.ready()
            original = (f.run_dir / "gate-state.json").read_bytes()
            self.assertNotEqual(f.init().returncode, 0)
            self.assertEqual((f.run_dir / "gate-state.json").read_bytes(), original)
            state = f.state()
            state["execution_status"] = "running"
            f.write_state(state)
            f.blocked()

    def test_unprotected_or_external_record_directory_is_rejected(self):
        with self.fixture() as f:
            f.run_dir.chmod(0o755)
            self.assertNotEqual(f.init().returncode, 0)
            f.run_dir.chmod(0o700)
            external = f.root / "record"
            external.mkdir(mode=0o700)
            f.run_dir = external
            f.flush()
            self.assertNotEqual(f.init().returncode, 0)
            self.assertFalse(f.marker.exists())

    def test_candidate_with_real_env_or_overlapping_source_is_rejected(self):
        for mutation in ("secret-env", "overlap"):
            with self.subTest(mutation=mutation), self.fixture() as f:
                if mutation == "secret-env":
                    (f.candidate / ".env.production").write_text("DUMMY_SECRET=fixture\n", encoding="utf-8")
                else:
                    f.candidate = f.project / "app"
                self.assertNotEqual(f.init().returncode, 0)
                self.assertFalse(f.marker.exists())

    def test_host_interpreter_and_path_escaping_cannot_be_authorized(self):
        for mutation in ("host-interpreter", "artifact-traversal", "config-traversal", "duplicate-plan-key"):
            with self.subTest(mutation=mutation), self.fixture() as f:
                if mutation == "host-interpreter":
                    f.plan["execution"]["argv"][0] = "/usr/bin/python3"
                elif mutation == "artifact-traversal":
                    f.plan["candidates"][0]["artifacts"][0]["path"] = "../outside.tgz"
                elif mutation == "config-traversal":
                    f.plan["execution"]["config"] = "../outside.json"
                f.json(f.run_dir / "plan.json", f.plan)
                if mutation == "duplicate-plan-key":
                    raw = (f.run_dir / "plan.json").read_text(encoding="utf-8")
                    (f.run_dir / "plan.json").write_text('{"unit":"duplicate",' + raw[1:], encoding="utf-8")
                self.assertNotEqual(f.init().returncode, 0)
                self.assertFalse(f.marker.exists())


def load_helper(name):
    path = SKILLS / MINOR / "scripts" / (name + ".py")
    spec = importlib.util.spec_from_file_location("gate_test_" + name, str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.archive = load_helper("archive_inspector")
        cls.audit = load_helper("audit_report")

    @contextmanager
    def temporary(self, name, data):
        with tempfile.TemporaryDirectory(prefix="gate-helper-test-", dir=TEMP_ROOT) as directory:
            path = Path(directory) / name
            path.write_bytes(data)
            yield path

    def test_three_ecosystem_archives_report_execution_signals_without_extracting(self):
        cases = (
            ("demo.tgz", gzip.compress(tar_bytes([
                ("package/package.json", b'{"scripts":{"postinstall":"node hook.js"}}'),
                ("package/hook.js", b"process.env.TOKEN; fetch('https://example.invalid');"),
            ])), {"node-lifecycle-script:postinstall", "secret-environment-access", "network-access"}),
            ("demo.whl", zip_bytes([("demo.pth", b"import demo\n"), ("demo/build.py", b"import subprocess\n")]),
             {"python-startup-code", "process-execution"}),
            ("demo.gem", gem_bytes([("ext/demo/extconf.rb", b"require 'mkmf'\n")]), {"ruby-build-code"}),
        )
        for name, data, expected in cases:
            with self.subTest(name=name), self.temporary(name, data) as path:
                report = self.archive.inspect_artifact(path)
                self.assertGreater(report["members"], 0)
                self.assertGreater(report["unpacked_bytes"], 0)
                self.assertTrue(expected <= {signal["kind"] for signal in report["signals"]})
                self.assertEqual(list(path.parent.iterdir()), [path], "静的検査で配布物を展開した")

    def test_archive_rejects_unsafe_paths_duplicates_special_entries_and_corruption(self):
        cases = [
            ("demo.whl", zip_bytes([("../escape.py", b"x")])),
            ("demo.whl", zip_bytes([("A.py", b"x"), ("a.py", b"y")])),
            ("demo.whl", zip_bytes([("file", b"x"), ("file/child", b"y")])),
            ("demo.whl", b"PK\x03\x04truncated"),
            ("demo.tgz", b"invalid gzip"),
            ("demo.tar", tar_bytes([("../escape.rb", b"x")])),
            ("demo.gem", gem_bytes([("../escape.rb", b"x")])),
            ("demo.gem", tar_bytes([("metadata.gz", gzip.compress(b"---\n"))])),
            ("demo.bin", b"unsupported artifact"),
        ]
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            info = tarfile.TarInfo("link")
            info.type = tarfile.SYMTYPE
            info.linkname = "target"
            archive.addfile(info)
        cases.append(("demo.tar", stream.getvalue()))
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            info = zipfile.ZipInfo("link")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, "target")
        cases.append(("demo.whl", stream.getvalue()))
        for name, data in cases:
            with self.subTest(name=name, digest=sha256(data)), self.temporary(name, data) as path:
                with self.assertRaises(self.archive.InspectionError):
                    self.archive.inspect_artifact(path)

    def test_three_audit_formats_accept_only_known_complete_structure(self):
        for format_name, report in (("npm-v2", npm_report()), ("pip-audit", pip_report()), ("bundler-audit", bundler_report())):
            with self.subTest(format=format_name), self.temporary("audit.json", json.dumps(report).encode("utf-8")) as path:
                result = self.audit.inspect_audit(path, format_name)
                self.assertEqual(result["findings"], 0)
                self.assertEqual(result["format"], format_name)

    def test_audit_vulnerability_is_counted_instead_of_ignored(self):
        report = pip_report()
        report["dependencies"][0]["vulns"] = [{"id": "PYSEC-fixture", "fix_versions": ["2.0.0"]}]
        cases = (("npm-v2", npm_report(finding=True)), ("pip-audit", report),
                 ("bundler-audit", dict(bundler_report(), results=[{"type": "insecure_source", "source": "http://example.invalid"}])))
        for format_name, report in cases:
            with self.subTest(format=format_name), self.temporary("audit.json", json.dumps(report).encode("utf-8")) as path:
                self.assertEqual(self.audit.inspect_audit(path, format_name)["findings"], 1)

    def test_audit_errors_skips_unknown_formats_empty_and_inconsistent_totals_fail(self):
        skipped = {"dependencies": [{"name": "demo", "skip_reason": "unsupported"}], "fixes": []}
        counts = npm_report()
        counts["metadata"]["vulnerabilities"]["total"] = 1
        cases = [
            ("npm-v2", b'{"error":{"code":"EOFFLINE"}}'),
            ("npm-v2", json.dumps(counts).encode("utf-8")),
            ("npm-v2", b'{"auditReportVersion":2,"auditReportVersion":2}'),
            ("pip-audit", json.dumps(skipped).encode("utf-8")),
            ("pip-audit", b'{"dependencies":[],"fixes":[]}'),
            ("pip-audit", b'{"dependencies":[],"fixes":[],"unknown":true}'),
            ("bundler-audit", json.dumps(dict(bundler_report(), results=[{"type": "error"}])).encode("utf-8")),
            ("bundler-audit", json.dumps(dict(bundler_report(), version="99.0.0")).encode("utf-8")),
            ("unknown", json.dumps(pip_report()).encode("utf-8")),
            ("pip-audit", b""), ("pip-audit", b"{broken"),
        ]
        for format_name, data in cases:
            with self.subTest(format=format_name, report=data), self.temporary("audit.json", data) as path:
                with self.assertRaises(self.audit.AuditError):
                    self.audit.inspect_audit(path, format_name)


if __name__ == "__main__":
    unittest.main()
