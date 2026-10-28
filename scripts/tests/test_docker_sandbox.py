#!/usr/bin/env python3
"""隔離準備・実行の境界を外部取得や実 Docker なしで検証する。

実行: python3 -I -S -m unittest discover -s scripts/tests -p 'test_docker_sandbox.py' -v
Docker の代役は固定の JSON/tar を返す信頼済み fixture。対象コードは実行しない。
"""

import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[2]
SKILLS = REPO / ".agents" / "skills"
MINOR = "minor-version-upgrade"
IMAGE = "docker.io/library/node@sha256:" + "a" * 64
IMAGE_ID = "sha256:" + "b" * 64
TEMP_ROOT = str(Path(tempfile.gettempdir()).resolve())


def tar_bytes(entries):
    """(path, bytes[, type, linkname]) の USTAR を作る。展開・実行はしない。"""
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for entry in entries:
            name, content = entry[:2]
            member = tarfile.TarInfo(name)
            member.mode = 0o600
            member.type = entry[2] if len(entry) > 2 else tarfile.REGTYPE
            member.linkname = entry[3] if len(entry) > 3 else ""
            member.size = len(content) if member.isreg() else 0
            archive.addfile(member, io.BytesIO(content) if member.isreg() else None)
    return stream.getvalue()


def probe_entries(network=b"lo 0x9\n", routes_v4=None, routes_v6=b"",
                  scratch_options=b"rw,nosuid,nodev,size=1048576k"):
    if routes_v4 is None:
        routes_v4 = b"Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n"
    return [
        ("probe.txt", b"probe-ok\n"),
        ("probe-exec.txt", b"probe-exec-ok\n"),
        ("network.txt", network),
        ("routes-v4.txt", routes_v4),
        ("routes-v6.txt", routes_v6),
        ("status.txt", b"CapEff:\t0000000000000000\nNoNewPrivs:\t1\n"),
        ("mounts.txt", b"/dev/root / ext4 ro,relatime 0 0\n"
                       b"candidate /candidate none ro,relatime 0 0\n"
                       b"worker /worker none ro,relatime 0 0\n"
                       b"tmpfs /scratch tmpfs " + scratch_options + b" 0 0\n"),
        ("memory.max", b"2147483648\n"),
        ("memory.swap.max", b"0\n"),
        ("pids.max", b"128\n"),
        ("cpu.max", b"100000 100000\n"),
        ("worker.log", b""),
        ("exit-code", b"0\n"),
    ]


def probe_tar(**kwargs):
    return tar_bytes(probe_entries(**kwargs))


def load_sandbox():
    path = SKILLS / MINOR / "scripts" / "docker-sandbox.py"
    spec = importlib.util.spec_from_file_location("docker_sandbox_minor", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeDocker:
    """CLI の制御情報はファイルで固定し、呼出し時の秘密環境を要求しない。"""

    def __init__(self, root):
        self.root = root
        self.config_path = root / "fake-docker.json"
        self.log_path = root / "docker-calls.jsonl"
        self.tar_path = root / "docker-output.tar"
        self.path = root / "docker-fixture"
        self.config = {
            "endpoint": "unix:///tmp/agent-skills-test-docker.sock",
            "image_id": IMAGE_ID,
            "image": IMAGE,
            "repo_digests": [IMAGE],
            "volumes": None,
            "run_exit": 0,
            "image_missing": False,
            "run_sleep": 0,
            "rm_exit": 0,
            "list_exit": 0,
            "remaining_names": "",
        }
        self.tar_path.write_bytes(probe_tar())
        self.flush()
        self.path.write_text(
            "#!" + sys.executable + " -IS\n"
            "import json, os, pathlib, sys, time\n"
            "root = pathlib.Path(" + repr(str(root)) + ")\n"
            "config = json.loads((root / 'fake-docker.json').read_text())\n"
            "argv = sys.argv[1:]\n"
            "with (root / 'docker-calls.jsonl').open('a') as log:\n"
            "    log.write(json.dumps({'argv': argv, 'environment': dict(os.environ), 'pid':os.getpid()}) + '\\n')\n"
            "while argv and argv[0] in ('--config', '--host', '--context'):\n"
            "    argv = argv[2:]\n"
            "if argv[:2] == ['context', 'inspect']:\n"
            "    print(json.dumps(config['endpoint']))\n"
            "elif argv[:2] == ['context', 'show']:\n"
            "    print('fixture-context')\n"
            "elif argv and argv[0] == 'info':\n"
            "    print(json.dumps({'OSType':'linux', 'CgroupVersion':'2', 'CgroupDriver':'cgroupfs',\n"
            "                      'MemoryLimit':True, 'SwapLimit':True, 'CpuCfsQuota':True, 'PidsLimit':True,\n"
            "                      'SecurityOptions':['name=seccomp,profile=builtin', 'name=cgroupns']}))\n"
            "elif argv[:2] == ['image', 'inspect']:\n"
            "    if config['image_missing']:\n"
            "        raise SystemExit(1)\n"
            "    print(json.dumps([{'Id':config['image_id'], 'RepoDigests':config['repo_digests'],\n"
            "                       'Os':'linux', 'Architecture':'arm64',\n"
            "                       'Config':{'Volumes':config['volumes'],\n"
            "                                 'Env':['PATH=/usr/local/bin:/usr/bin:/bin', 'IMAGE_SECRET=sentinel'],\n"
            "                                 'Entrypoint':['/untrusted-image-entrypoint'], 'User':'0'}}]))\n"
            "elif argv and argv[0] == 'pull':\n"
            "    config['image_missing'] = False\n"
            "    (root / 'fake-docker.json').write_text(json.dumps(config))\n"
            "elif argv and argv[0] == 'run':\n"
            "    time.sleep(config['run_sleep'])\n"
            "    sys.stdout.buffer.write((root / 'docker-output.tar').read_bytes())\n"
            "    raise SystemExit(config['run_exit'])\n"
            "elif argv[:2] == ['rm', '--force']:\n"
            "    raise SystemExit(config['rm_exit'])\n"
            "elif argv[:2] == ['container', 'ls']:\n"
            "    print(config['remaining_names'], end='')\n"
            "    raise SystemExit(config['list_exit'])\n"
            "elif argv[:2] == ['container', 'inspect']:\n"
            "    raise SystemExit(1)\n"
            "else:\n"
            "    print('unsupported fixture command', file=sys.stderr)\n"
            "    raise SystemExit(2)\n",
            encoding="utf-8",
        )
        self.path.chmod(0o700)

    def flush(self):
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")

    def records(self):
        if not self.log_path.exists():
            return []
        return [json.loads(line) for line in self.log_path.read_text(encoding="utf-8").splitlines()]

    def commands(self):
        commands = []
        for record in self.records():
            argv = list(record["argv"])
            while argv and argv[0] in ("--config", "--host", "--context"):
                argv = argv[2:]
            commands.append(argv)
        return commands


class SandboxFixture:
    def __init__(self, testcase):
        self.testcase = testcase
        self.cli = SKILLS / MINOR / "scripts" / "docker-sandbox.py"
        self.temporary = tempfile.TemporaryDirectory(prefix="docker-sandbox-test-", dir=TEMP_ROOT)
        self.root = Path(self.temporary.name)
        self.docker = FakeDocker(self.root)
        artifact_root = REPO / "artifacts" / MINOR
        artifact_root.mkdir(parents=True, exist_ok=True)
        self.run_temporary = tempfile.TemporaryDirectory(prefix="sandbox-test-", dir=str(artifact_root))
        self.run = Path(self.run_temporary.name)
        (self.run / "executor").mkdir()
        self.worker_name = "executor/worker.sh"
        self.worker = self.run / self.worker_name
        self.worker.write_text("#!/bin/sh\nprintf 'fixture result\\n' > \"$OUTPUT/result.txt\"\n", encoding="utf-8")
        self.candidate = self.root / "candidate"
        self.candidate.mkdir()
        (self.candidate / "package.json").write_text('{"name":"fixture"}\n', encoding="utf-8")
        self.output = self.root / "output"
        self.output.mkdir(mode=0o700)
        testcase.addCleanup(self.temporary.cleanup)
        testcase.addCleanup(self.run_temporary.cleanup)

    def command(self, *arguments, env=None):
        environment = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
        if env:
            environment.update(env)
        return subprocess.run(
            [sys.executable, "-I", "-S", str(self.cli), *map(str, arguments)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15, env=environment,
        )

    def prepare(self, image=IMAGE, **kwargs):
        return self.command("prepare", "--run", self.run, "--image", image,
                            "--worker", self.worker_name, "--docker", self.docker.path,
                            "--context", "fixture-context", **kwargs)

    def assert_ok(self, result):
        self.testcase.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def execute(self, *extra, **kwargs):
        return self.command("execute", "--config", self.run / "sandbox" / "config.json",
                            "--candidate", self.candidate, "--worker", self.worker,
                            "--output", self.output, *extra, **kwargs)

    def ready(self):
        self.assert_ok(self.prepare())
        self.docker.log_path.unlink()
        self.docker.tar_path.write_bytes(tar_bytes([
            ("result.txt", b"fixture result\n"), ("worker.log", b"fixture log\n"), ("exit-code", b"0\n"),
        ]))


class PreparationRejectionTests(unittest.TestCase):
    def test_mutable_image_does_not_start_docker(self):
        fixture = SandboxFixture(self)
        result = fixture.prepare(image="docker.io/library/node:24")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(fixture.docker.records(), [])
        self.assertFalse((fixture.run / "sandbox" / "executor").exists())

    def test_remote_daemon_does_not_receive_candidate_or_run_commands(self):
        fixture = SandboxFixture(self)
        fixture.docker.config["endpoint"] = "tcp://untrusted.example.invalid:2375"
        fixture.docker.flush()
        result = fixture.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(command[:2] == ["context", "inspect"] for command in fixture.docker.commands()))
        self.assertFalse((fixture.run / "sandbox" / "executor").exists())

    def test_image_declared_volume_cannot_create_unbounded_writable_storage(self):
        fixture = SandboxFixture(self)
        fixture.docker.config["volumes"] = {"/data": {}}
        fixture.docker.flush()
        result = fixture.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(command[0] == "run" for command in fixture.docker.commands()))

    def test_writable_docker_cli_is_rejected_before_context_discovery(self):
        for mode in (0o720, 0o702):
            with self.subTest(mode=oct(mode)):
                fixture = SandboxFixture(self)
                fixture.docker.path.chmod(mode)
                result = fixture.prepare()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(fixture.docker.records(), [])
                self.assertFalse((fixture.run / "sandbox" / "executor").exists())
        self.assertFalse((fixture.run / "sandbox" / "executor").exists())


class PreparationTests(unittest.TestCase):
    def test_prepare_creates_optional_executor_config_and_probe_evidence(self):
        fixture = SandboxFixture(self)
        prepared = fixture.prepare()
        fixture.assert_ok(prepared)
        result = json.loads(prepared.stdout)
        config = json.loads((fixture.run / "sandbox/config.json").read_text())
        evidence = json.loads((fixture.run / "evidence/isolation-setup.json").read_text())
        self.assertEqual(config["image"], IMAGE)
        self.assertEqual(config["image_id"], IMAGE_ID)
        self.assertNotIn(str(fixture.run), json.dumps(config))
        self.assertEqual(result["status"], "prepared")
        self.assertEqual(result["config"], str(fixture.run / "sandbox/config.json"))
        self.assertEqual(result["evidence"], str(fixture.run / "evidence/isolation-setup.json"))
        executor = Path(result["executor"])
        self.assertEqual(executor, fixture.run / "sandbox/executor")
        self.assertTrue(executor.is_file())
        self.assertTrue(os.access(executor, os.X_OK))
        self.assertEqual(executor, executor.resolve())
        self.assertNotIn("execution", result)
        self.assertFalse((fixture.run / "sandbox/execution.json").exists())
        self.assertTrue(evidence)
        self.assertFalse((fixture.run / "gate-state.json").exists())


    def test_prepare_does_not_forward_parent_credentials_to_docker(self):
        fixture = SandboxFixture(self)
        fixture.assert_ok(fixture.prepare(env={"TEST_PARENT_SECRET": "sentinel-private-value",
                                               "SSH_AUTH_SOCK": "/private/ssh-agent-fixture.sock"}))
        for record in fixture.docker.records():
            self.assertNotIn("TEST_PARENT_SECRET", record["environment"])
            self.assertNotIn("SSH_AUTH_SOCK", record["environment"])
            self.assertNotIn("sentinel-private-value", json.dumps(record))

    def test_default_docker_discovery_ignores_a_parent_path_wrapper(self):
        fixture = SandboxFixture(self)
        sandbox = load_sandbox()
        trusted_bin = fixture.root / "reviewed-tools"
        trusted_bin.mkdir()
        trusted_docker = trusted_bin / "docker"
        shutil.copyfile(fixture.docker.path, trusted_docker)
        trusted_docker.chmod(0o700)
        untrusted_bin = fixture.root / "project" / "bin"
        untrusted_bin.mkdir(parents=True)
        wrapper = untrusted_bin / "docker"
        wrapper_marker = fixture.root / "wrapper-ran"
        wrapper.write_text(
            "#!" + sys.executable + " -IS\nfrom pathlib import Path\nPath("
            + repr(str(wrapper_marker)) + ").write_text('unexpected wrapper execution')\n"
            "raise SystemExit(91)\n", encoding="utf-8")
        wrapper.chmod(0o700)
        args = argparse.Namespace(run=str(fixture.run), image=IMAGE, worker=fixture.worker_name,
                                  docker=None, context="fixture-context", no_pull=True)
        actual_run = sandbox.run_bounded
        invoked_executables = []

        def run_only_fixture(argv, *arguments, **kwargs):
            # 回帰時にも、このマシンの本物Dockerを起動させない。
            self.assertIn(argv[0], (str(trusted_docker), str(wrapper)))
            invoked_executables.append(argv[0])
            return actual_run(argv, *arguments, **kwargs)

        with mock.patch.object(sandbox, "DOCKER_DISCOVERY_PATH", str(trusted_bin)), \
                mock.patch.dict(os.environ, {"PATH": str(untrusted_bin)}), \
                mock.patch.object(sandbox, "run_bounded", side_effect=run_only_fixture), \
                mock.patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(sandbox.prepare(args), 0)
        config = json.loads((fixture.run / "sandbox" / "config.json").read_text())
        self.assertEqual(config["docker"], str(trusted_docker))
        self.assertTrue(invoked_executables)
        self.assertEqual(set(invoked_executables), {str(trusted_docker)})
        self.assertFalse(wrapper_marker.exists())

    def test_prepare_pulls_only_digest_when_missing(self):
        fixture = SandboxFixture(self)
        fixture.docker.config["image_missing"] = True
        fixture.docker.flush()
        fixture.assert_ok(fixture.prepare())
        pulls = [command for command in fixture.docker.commands() if command[0] == "pull"]
        self.assertEqual(pulls, [["pull", IMAGE]])

    def test_familiar_docker_hub_digest_works_during_prepare_and_execute(self):
        fixture = SandboxFixture(self)
        fixture.docker.config["repo_digests"] = ["node@sha256:" + "a" * 64]
        fixture.docker.flush()
        fixture.ready()
        fixture.assert_ok(fixture.execute())
        self.assertTrue(any(command[0] == "run" for command in fixture.docker.commands()))

    def test_failed_probe_does_not_publish_an_executor(self):
        fixture = SandboxFixture(self)
        fixture.docker.tar_path.write_bytes(tar_bytes([("probe.txt", b"not verified\n"), ("exit-code", b"0\n")]))
        result = fixture.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((fixture.run / "sandbox" / "executor").exists())
        self.assertFalse((fixture.run / "sandbox" / "execution.json").exists())
        commands = fixture.docker.commands()
        self.assertTrue(any(command[0] == "run" for command in commands))
        self.assertTrue(any(command[:2] == ["rm", "--force"] for command in commands))


class ImageReferenceTests(unittest.TestCase):
    def inspect(self, sandbox, requested, recorded):
        report = [{"Id": IMAGE_ID, "RepoDigests": [recorded], "Os": "linux",
                   "Config": {"Volumes": None, "Env": []}}]
        result = subprocess.CompletedProcess([], 0, json.dumps(report).encode("utf-8"), b"")
        with mock.patch.object(sandbox, "run_bounded", return_value=result):
            return sandbox.inspect_image(["unused-fixture-docker"], requested)

    def test_docker_hub_registry_and_official_namespace_spellings_are_equivalent(self):
        digest = "@sha256:" + "a" * 64
        pairs = (("docker.io/library/node", "node"),
                 ("node", "docker.io/library/node"),
                 ("docker.io/node", "library/node"),
                 ("index.docker.io/library/node", "docker.io/library/node"),
                 ("docker.io/acme/widget", "acme/widget"),
                 ("docker.io/library/node:24", "node"))
        sandbox = load_sandbox()
        for requested, recorded in pairs:
            with self.subTest(requested=requested, recorded=recorded):
                self.assertEqual(self.inspect(sandbox, requested + digest, recorded + digest),
                                 (IMAGE_ID, []))

    def test_same_digest_cannot_substitute_another_registry_or_repository(self):
        digest = "@sha256:" + "a" * 64
        pairs = (("docker.io/library/node", "ghcr.io/library/node"),
                 ("docker.io/library/node", "localhost/library/node"),
                 ("docker.io/library/node", "acme/node"),
                 ("docker.io/library/node", "ruby"),
                 ("ghcr.io/library/node", "node"),
                 ("ghcr.io/acme/widget", "acme/widget"))
        sandbox = load_sandbox()
        for requested, recorded in pairs:
            with self.subTest(requested=requested, recorded=recorded):
                with self.assertRaises(sandbox.SandboxError):
                    self.inspect(sandbox, requested + digest, recorded + digest)
        with self.subTest(mismatch="digest"):
            with self.assertRaises(sandbox.SandboxError):
                self.inspect(sandbox, IMAGE, "node@sha256:" + "c" * 64)
        with self.subTest(match="non-Docker-Hub registry"):
            reference = "ghcr.io/acme/widget" + digest
            self.assertEqual(self.inspect(sandbox, reference, reference), (IMAGE_ID, []))


class OutputExtractionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = load_sandbox()

    def output_directory(self):
        temporary = tempfile.TemporaryDirectory(prefix="sandbox-output-test-", dir=TEMP_ROOT)
        self.addCleanup(temporary.cleanup)
        output = Path(temporary.name) / "output"
        output.mkdir(mode=0o700)
        return output

    def test_regular_files_are_copied_without_extractall(self):
        output = self.output_directory()
        result = self.sandbox.extract_output(tar_bytes([("nested/result.txt", b"verified\n")]), output)
        self.assertEqual((output / "nested" / "result.txt").read_bytes(), b"verified\n")
        self.assertEqual(result["files"], 1)
        self.assertEqual(result["bytes"], 9)

    def test_unsafe_archive_entries_are_rejected(self):
        cases = {
            "parent": [("../escape", b"x")],
            "absolute": [("/escape", b"x")],
            "symlink": [("link", b"", tarfile.SYMTYPE, "../escape")],
            "hardlink": [("link", b"", tarfile.LNKTYPE, "../escape")],
            "fifo": [("pipe", b"", tarfile.FIFOTYPE)],
            "device": [("device", b"", tarfile.CHRTYPE)],
            "duplicate": [("result.txt", b"a"), ("result.txt", b"b")],
            "file-as-parent": [("nested", b"a"), ("nested/result.txt", b"b")],
        }
        for case, entries in cases.items():
            with self.subTest(case=case):
                output = self.output_directory()
                with self.assertRaises((self.sandbox.SandboxError, OSError)):
                    self.sandbox.extract_output(tar_bytes(entries), output)
                self.assertFalse((output.parent / "escape").exists())

    def test_existing_file_is_never_overwritten(self):
        output = self.output_directory()
        (output / "result.txt").write_bytes(b"original")
        with self.assertRaises((self.sandbox.SandboxError, OSError)):
            self.sandbox.extract_output(tar_bytes([("result.txt", b"replacement")]), output)
        self.assertEqual((output / "result.txt").read_bytes(), b"original")

    def test_declared_oversized_member_is_rejected_before_reading(self):
        output = self.output_directory()
        member = tarfile.TarInfo("huge.bin")
        member.size = 1 << 32
        data = member.tobuf(format=tarfile.USTAR_FORMAT) + b"\0" * 1024
        with self.assertRaises(self.sandbox.SandboxError):
            self.sandbox.extract_output(data, output)
        self.assertFalse((output / "huge.bin").exists())


class NetworkProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = load_sandbox()

    def probe_output(self, **kwargs):
        temporary = tempfile.TemporaryDirectory(prefix="sandbox-probe-test-", dir=TEMP_ROOT)
        self.addCleanup(temporary.cleanup)
        output = Path(temporary.name)
        for name, content in probe_entries(**kwargs):
            (output / name).write_bytes(content)
        return output

    def test_down_tunnel_interfaces_do_not_invalidate_network_none(self):
        output = self.probe_output(network=b"lo 0x9\ntunl0 0x80\nsit0 0x80\n")
        self.assertTrue(self.sandbox.validate_probe(output)["network_none"])

    def test_noexec_scratch_is_rejected_even_with_a_success_marker(self):
        output = self.probe_output(scratch_options=b"rw,nosuid,nodev,noexec,size=1048576k")
        with self.assertRaises(self.sandbox.SandboxError):
            self.sandbox.validate_probe(output)

    def test_scratch_execution_requires_its_probe_result(self):
        for content in (None, b"not verified\n"):
            with self.subTest(content=content):
                output = self.probe_output()
                marker = output / "probe-exec.txt"
                if content is None:
                    marker.unlink()
                else:
                    marker.write_bytes(content)
                with self.assertRaises((self.sandbox.SandboxError, OSError)):
                    self.sandbox.validate_probe(output)

    def test_up_nonloopback_interface_is_rejected(self):
        output = self.probe_output(network=b"lo 0x9\neth0 0x1003\n")
        with self.assertRaises(self.sandbox.SandboxError):
            self.sandbox.validate_probe(output)

    def test_external_ipv4_route_is_rejected_even_for_a_down_interface(self):
        output = self.probe_output(
            network=b"lo 0x9\neth0 0x1002\n",
            routes_v4=b"Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n"
                      b"eth0\t00000000\t010011AC\t0003\t0\t0\t0\t00000000\t0\t0\t0\n",
        )
        with self.assertRaises(self.sandbox.SandboxError):
            self.sandbox.validate_probe(output)

    def test_external_ipv6_route_is_rejected_even_for_a_down_interface(self):
        output = self.probe_output(
            network=b"lo 0x9\neth0 0x1002\n",
            routes_v6=(b"00000000000000000000000000000000 00 00000000000000000000000000000000 00 "
                       b"00000000000000000000000000000000 00000001 00000000 00000000 00000200 eth0\n"),
        )
        with self.assertRaises(self.sandbox.SandboxError):
            self.sandbox.validate_probe(output)


class ExecutionTests(unittest.TestCase):
    def test_execution_enforces_limits_and_separates_host_output(self):
        fixture = SandboxFixture(self)
        fixture.ready()
        fixture.assert_ok(fixture.execute(env={"TEST_PARENT_SECRET": "sentinel-private-value"}))
        commands = fixture.docker.commands()
        run = next(command for command in commands if command[0] == "run")
        for flag in ("--read-only", "--no-healthcheck"):
            self.assertIn(flag, run)
        expected = {
            "--pull": "never", "--network": "none", "--ipc": "none", "--cap-drop": "ALL",
            "--security-opt": "no-new-privileges", "--pids-limit": "128", "--cpus": "1",
            "--memory": "2147483648", "--memory-swap": "2147483648", "--log-driver": "none",
            "--user": str(os.getuid()) + ":" + str(os.getgid()), "--entrypoint": "/bin/sh",
        }
        for flag, value in expected.items():
            with self.subTest(flag=flag):
                self.assertIn(flag, run)
                self.assertEqual(run[run.index(flag) + 1], value)
        self.assertIn(IMAGE_ID, run)
        self.assertNotIn("sentinel", " ".join(run))
        mounts = [run[index + 1] for index, item in enumerate(run) if item == "--mount"]
        self.assertTrue(mounts)
        self.assertTrue(all("readonly" in mount for mount in mounts))
        self.assertFalse(any(str(fixture.output) in mount for mount in mounts))
        self.assertFalse(any(str(fixture.run) + "," in mount for mount in mounts))
        tmpfs = run[run.index("--tmpfs") + 1]
        self.assertTrue(tmpfs.startswith("/scratch:"))
        self.assertIn("size=1073741824", tmpfs)
        tmpfs_options = tmpfs.split(":", 1)[1].split(",")
        self.assertIn("exec", tmpfs_options)
        self.assertNotIn("noexec", tmpfs_options)
        self.assertIn("env -i", " ".join(run))
        name = run[run.index("--name") + 1]
        self.assertIn(["rm", "--force", name], commands)
        self.assertEqual((fixture.output / "result.txt").read_text(), "fixture result\n")
        self.assertEqual((fixture.candidate / "package.json").read_text(), '{"name":"fixture"}\n')
        for record in fixture.docker.records():
            self.assertNotIn("TEST_PARENT_SECRET", record["environment"])

    def test_nonzero_docker_exit_still_removes_only_its_container(self):
        fixture = SandboxFixture(self)
        fixture.ready()
        fixture.docker.config["run_exit"] = 125
        fixture.docker.flush()
        result = fixture.execute()
        self.assertNotEqual(result.returncode, 0)
        commands = fixture.docker.commands()
        run = next(command for command in commands if command[0] == "run")
        name = run[run.index("--name") + 1]
        self.assertIn(["rm", "--force", name], commands)
        self.assertFalse(any(command[:2] == ["container", "prune"] for command in commands))

    def test_unknown_configuration_cannot_relax_the_sandbox(self):
        fixture = SandboxFixture(self)
        fixture.ready()
        config_path = fixture.run / "sandbox" / "config.json"
        config = json.loads(config_path.read_text())
        config["extra_docker_arguments"] = ["--privileged", "--network=host"]
        config_path.write_text(json.dumps(config))
        self.assertNotEqual(fixture.execute().returncode, 0)
        self.assertEqual(fixture.docker.records(), [])

    def test_changed_docker_binary_is_rejected_before_any_docker_call(self):
        fixture = SandboxFixture(self)
        fixture.ready()
        fixture.docker.path.write_text(fixture.docker.path.read_text() + "\n# changed fixture\n")
        self.assertNotEqual(fixture.execute().returncode, 0)
        self.assertEqual(fixture.docker.records(), [])

    def test_symlinked_input_is_rejected_before_docker_call(self):
        fixture = SandboxFixture(self)
        fixture.ready()
        target = fixture.root / "input.txt"
        target.write_text("fixture input\n")
        link = fixture.root / "linked-input.txt"
        link.symlink_to(target)
        self.assertNotEqual(fixture.execute("--input", link).returncode, 0)
        self.assertEqual(fixture.docker.records(), [])

    def test_container_is_removed_when_its_cli_times_out(self):
        fixture = SandboxFixture(self)
        fixture.ready()
        sandbox = load_sandbox()
        actual_run = sandbox.run_bounded
        timed_out_command = []

        def run_with_timeout(argv, env, timeout, **kwargs):
            if "run" in argv:
                timed_out_command.extend(argv)
                raise sandbox.SandboxError("fixture timeout")
            return actual_run(argv, env, timeout, **kwargs)

        config = json.loads((fixture.run / "sandbox" / "config.json").read_text())
        with mock.patch.object(sandbox, "run_bounded", side_effect=run_with_timeout):
            with self.assertRaises(sandbox.SandboxError):
                sandbox.execute(config, fixture.candidate, fixture.worker, fixture.output)
        name = timed_out_command[timed_out_command.index("--name") + 1]
        self.assertIn(["rm", "--force", name], fixture.docker.commands())

    def test_unsafe_export_is_rejected_and_container_removed(self):
        fixture = SandboxFixture(self)
        fixture.ready()
        fixture.docker.tar_path.write_bytes(tar_bytes([("../escape", b"x")]))
        self.assertNotEqual(fixture.execute().returncode, 0)
        self.assertEqual(list(fixture.output.iterdir()), [])
        commands = fixture.docker.commands()
        run = next(command for command in commands if command[0] == "run")
        name = run[run.index("--name") + 1]
        self.assertIn(["rm", "--force", name], commands)

    def test_failed_remove_requires_successful_empty_container_listing(self):
        for list_exit, remaining, expected_success in ((0, "", True), (1, "", False), (0, "still-running\n", False)):
            with self.subTest(list_exit=list_exit, remaining=remaining):
                fixture = SandboxFixture(self)
                fixture.ready()
                fixture.docker.config.update(rm_exit=1, list_exit=list_exit, remaining_names=remaining)
                fixture.docker.flush()
                result = fixture.execute()
                self.assertEqual(result.returncode == 0, expected_success, result.stdout + result.stderr)
                commands = fixture.docker.commands()
                run = next(command for command in commands if command[0] == "run")
                name = run[run.index("--name") + 1]
                listing = next(command for command in commands if command[:2] == ["container", "ls"])
                self.assertEqual(listing[listing.index("--filter") + 1], "name=^/" + name + "$")

    def test_sigterm_interrupts_the_cli_and_removes_its_container(self):
        fixture = SandboxFixture(self)
        fixture.ready()
        fixture.docker.config["run_sleep"] = 10
        fixture.docker.flush()
        process = subprocess.Popen(
            [sys.executable, "-I", "-S", "-B", str(fixture.cli), "execute", "--config",
             str(fixture.run / "sandbox" / "config.json"), "--candidate", str(fixture.candidate),
             "--worker", str(fixture.worker), "--output", str(fixture.output)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"},
        )
        try:
            deadline = time.monotonic() + 5
            run = None
            while time.monotonic() < deadline and process.poll() is None:
                commands = fixture.docker.commands()
                run = next((command for command in commands if command[0] == "run"), None)
                if run:
                    break
                time.sleep(0.01)
            self.assertIsNotNone(run, "実行中のfake Dockerを確認できなかった")
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0, stdout + stderr)
            name = run[run.index("--name") + 1]
            self.assertIn(["rm", "--force", name], fixture.docker.commands())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
            process.stdout.close()
            process.stderr.close()


class BoundedProcessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = load_sandbox()

    def test_large_stdout_is_rejected(self):
        with self.assertRaises(self.sandbox.SandboxError):
            self.sandbox.run_bounded(
                [sys.executable, "-I", "-S", "-c", "import sys; sys.stdout.write('x' * 8192)"],
                {"PATH": "/usr/bin:/bin"}, timeout=2, max_stdout=1024, max_stderr=1024,
            )

    def test_large_stderr_is_rejected_while_stdout_is_drained(self):
        with self.assertRaises(self.sandbox.SandboxError):
            self.sandbox.run_bounded(
                [sys.executable, "-I", "-S", "-c", "import sys; sys.stderr.write('x' * 8192)"],
                {"PATH": "/usr/bin:/bin"}, timeout=2, max_stdout=1024, max_stderr=1024,
            )

    def test_timeout_terminates_the_cli_process(self):
        with self.assertRaises(self.sandbox.SandboxError):
            self.sandbox.run_bounded(
                [sys.executable, "-I", "-S", "-c", "import time; time.sleep(5)"],
                {"PATH": "/usr/bin:/bin"}, timeout=0.05, max_stdout=1024, max_stderr=1024,
            )


class BootstrapWorkerTests(unittest.TestCase):
    def test_worker_stops_before_later_success_can_mask_a_failure(self):
        # bootstrap全体やDockerは動かさず、実際のworker起動argvだけを使って
        # 自作の無害なshell fixtureで失敗伝播を検証する。
        sandbox = load_sandbox()
        line = next(line for line in sandbox.BOOTSTRAP.splitlines() if "/worker >" in line)
        tokens = shlex.split(line)
        worker_index = tokens.index("/worker")
        self.assertEqual(tokens[0], "/bin/sh")
        for failure in ("false", ': "$UNSET_FIXTURE_VALUE"'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(
                    prefix="sandbox-worker-test-", dir=TEMP_ROOT) as temporary:
                root = Path(temporary)
                worker = root / "worker.sh"
                worker.write_text("printf 'started\\n'\n" + failure
                                  + '\nprintf "continued\\n" > "$OUTPUT/continued"\n', encoding="utf-8")
                result = subprocess.run(
                    tokens[:worker_index] + [str(worker)], cwd=str(root),
                    env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "OUTPUT": str(root)},
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=False,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, b"started\n")
                self.assertFalse((root / "continued").exists())


class GateIntegrationTests(unittest.TestCase):
    def test_optional_executor_accepts_static_gate_snapshot_without_gate_launching_it(self):
        spec = importlib.util.spec_from_file_location(
            "gate_fixture_for_docker_sandbox", Path(__file__).with_name("test_supply_chain_gate.py"))
        gate_tests = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate_tests)
        sandbox = SandboxFixture(self)
        sandbox.ready()
        gate = gate_tests.Fixture(self)
        self.addCleanup(gate.close)
        gate.ready()
        gate.require_ok(gate.command("run"))
        self.assertEqual(sandbox.docker.commands(), [])
        report = json.loads((gate.run_dir / "execution-output/static-result.json").read_text())
        self.assertFalse(report["runtime_verified"])
        snapshot = gate.run_dir / report["candidate_snapshot"]
        result = sandbox.command(
            "execute", "--config", sandbox.run / "sandbox/config.json",
            "--candidate", snapshot, "--worker", sandbox.worker, "--output", sandbox.output)
        sandbox.assert_ok(result)
        self.assertEqual((sandbox.output / "result.txt").read_text(), "fixture result\n")
        self.assertFalse(gate.marker.exists())
        commands = sandbox.docker.commands()
        run = next(command for command in commands if command[0] == "run")
        mounts = [run[index + 1] for index, item in enumerate(run) if item == "--mount"]
        self.assertTrue(any(str(snapshot) in mount for mount in mounts))
        self.assertFalse(any(str(gate.candidate) in mount or str(gate.project) in mount for mount in mounts))
        self.assertFalse(any(str(gate.run_dir) + "," in mount for mount in mounts))
        self.assertNotEqual(gate.command("run").returncode, 0)



if __name__ == "__main__":
    unittest.main()
