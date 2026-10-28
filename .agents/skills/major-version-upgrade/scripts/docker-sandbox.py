#!/usr/bin/env python3
"""既存のローカルDockerから、更新用の隔離設定とexecutorを準備する。Python 3.9以降。"""

import sys

if not (sys.flags.isolated and sys.flags.no_site):
    print("信頼済みのPythonを -I -S 付きで起動してください。", file=sys.stderr)
    sys.exit(1)

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import selectors
import shutil
import signal
import stat
import subprocess
import tarfile
import tempfile
import time
import uuid


LIMITS = {
    "cpus": 1, "memory_bytes": 2 * 1024 ** 3, "scratch_bytes": 1024 ** 3,
    "pids": 128, "file_bytes": 64 * 1024 ** 2, "wall_seconds": 900,
    "output_bytes": 128 * 1024 ** 2, "output_files": 5000,
}
MAX_TAR = LIMITS["output_bytes"] + 8 * 1024 ** 2
MAX_LOG = 2 * 1024 ** 2
HOST_ENV = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
DOCKER_DISCOVERY_PATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/Applications/Docker.app/Contents/Resources/bin"
WORKER_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
IMAGE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._:/-]*@sha256:[0-9a-f]{64}\Z")
IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}\Z")
ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")

# このコードは読み取り専用のtoolchainで動く。対象workerの出力はscratch内だけへ出す。
# stdoutはtar専用とし、worker自身のstdout/stderrは容量制限付きtmpfs内へ保存する。
BOOTSTRAP = r'''
set -eu
umask 077
for tool in cp chmod mkdir env tar cat; do command -v "$tool" >/dev/null; done
mkdir -p /scratch/project /scratch/output /scratch/home /scratch/tmp /scratch/cache
cp -R /candidate/. /scratch/project/
chmod -R u+rwX /scratch/project
cd /scratch/project
set +e
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 HOME=/scratch/home TMPDIR=/scratch/tmp XDG_CACHE_HOME=/scratch/cache \
  CANDIDATE=/scratch/project OUTPUT=/scratch/output INPUTS=/inputs \
  /bin/sh -eu /worker > /scratch/output/worker.log 2>&1
status=$?
set -e
printf '%s\n' "$status" > /scratch/output/exit-code
tar -C /scratch/output -cf - .
exit "$status"
'''

# 自己診断は対象コードを実行しない。設定の宣言と実際のkernelの境界を突き合わせる。
PROBE_WORKER = r'''
set -eu
test -z "${SANDBOX_PROBE_SECRET+x}"
test ! -e /var/run/docker.sock
test ! -e /run/docker.sock
if (printf changed > /candidate/probe-input) 2>/dev/null; then exit 81; fi
if (printf changed > /worker) 2>/dev/null; then exit 82; fi
if (printf changed > /sandbox-root-write) 2>/dev/null; then exit 83; fi
printf scratch > /scratch/probe-write
cat > /scratch/probe-exec <<'PROBE_SCRIPT'
#!/bin/sh
set -eu
printf 'probe-exec-ok\n' > "$OUTPUT/probe-exec.txt"
PROBE_SCRIPT
chmod 0700 /scratch/probe-exec
/scratch/probe-exec
cat /proc/mounts > "$OUTPUT/mounts.txt"
cat /proc/self/status > "$OUTPUT/status.txt"
: > "$OUTPUT/network.txt"
for interface in /sys/class/net/*; do
  test -d "$interface" || continue
  flags=$(cat "$interface/flags")
  printf '%s %s\n' "${interface##*/}" "$flags" >> "$OUTPUT/network.txt"
done
cat /proc/net/route > "$OUTPUT/routes-v4.txt"
cat /proc/net/ipv6_route > "$OUTPUT/routes-v6.txt"
if test -f /sys/fs/cgroup/memory.max; then
  for name in memory.max memory.swap.max pids.max cpu.max; do
    cat "/sys/fs/cgroup/$name" > "$OUTPUT/$name"
  done
else
  cat /sys/fs/cgroup/memory/memory.limit_in_bytes > "$OUTPUT/memory.max"
  cat /sys/fs/cgroup/memory/memory.memsw.limit_in_bytes > "$OUTPUT/memory.memsw"
  cat /sys/fs/cgroup/pids/pids.max > "$OUTPUT/pids.max"
  cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us > "$OUTPUT/cpu.quota"
  cat /sys/fs/cgroup/cpu/cpu.cfs_period_us > "$OUTPUT/cpu.period"
fi
printf 'probe-ok\n' > "$OUTPUT/probe.txt"
'''


class SandboxError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise SandboxError(message)


def text(value, maximum=2000):
    require(type(value) is str and 0 < len(value) <= maximum
            and not any(ord(c) < 32 or ord(c) == 127 for c in value),
            "文字列の型・長さ・制御文字を確認してください。")
    return value


def relative(value):
    text(value)
    parts = value.split("/")
    require(not PurePosixPath(value).is_absolute() and "\\" not in value and ":" not in value
            and all(part not in ("", ".", "..") for part in parts), "RUN内の相対パスを指定してください。")
    return Path(*parts)


def real_directory(value, private=False):
    path = Path(value).absolute()
    require(path == path.resolve() and path.is_dir() and not path.is_symlink(),
            "実体ディレクトリを指定してください。")
    if private:
        require(path.stat().st_uid == os.getuid() and not path.stat().st_mode & 0o077,
                "実行記録・出力先は所有者だけがアクセスできるディレクトリにしてください。")
    return path


def read_file(path, maximum=8 * 1024 ** 2):
    path = Path(path)
    require(path == path.resolve(), "ファイル入力のsymlinkは使えません。")
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= maximum,
                "通常ファイルと入力容量の上限を確認してください。")
        data = source.read(maximum + 1)
        after = os.fstat(source.fileno())
        require(len(data) == info.st_size and len(data) <= maximum
                and (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
                == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
                "読み取り中に入力が変更されたか、容量の上限を超えました。")
        return data


def digest_file(path):
    result = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "JSONに重複キーがあります。")
        result[key] = value
    return result


def parse_json(data):
    def invalid(_value):
        raise SandboxError("JSONに非対応の数値があります。")
    return json.loads(data.decode("utf-8"), object_pairs_hook=unique_pairs,
                      parse_constant=invalid, parse_float=invalid)


def write_exclusive(path, data, mode=0o600):
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "wb") as output:
        output.write(data)
    path.chmod(mode)


def json_bytes(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, indent=2).encode("ascii") + b"\n"


def run_bounded(argv, env, timeout, max_stdout=8 * 1024 ** 2, max_stderr=MAX_LOG):
    """CLIの両pipeを同時に読み、出力量と実時間を上限内に保つ。"""
    process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, shell=False, start_new_session=True)
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": max_stdout, "stderr": max_stderr}
    deadline = time.monotonic() + timeout
    completed = False
    try:
        with selectors.DefaultSelector() as selector:
            for name in buffers:
                stream = getattr(process, name)
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                require(remaining > 0, "隔離処理が制限時間を超えました。")
                for key, _event in selector.select(min(remaining, 0.2)):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        selector.unregister(key.fileobj)
                        continue
                    target = buffers[key.data]
                    require(len(target) + len(block) <= limits[key.data], "隔離処理の出力量が上限を超えました。")
                    target.extend(block)
            remaining = deadline - time.monotonic()
            require(remaining > 0, "隔離処理が制限時間を超えました。")
            code = process.wait(timeout=remaining)
            completed = True
            return subprocess.CompletedProcess(argv, code, bytes(buffers["stdout"]), bytes(buffers["stderr"]))
    finally:
        if not completed or process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        process.stdout.close()
        process.stderr.close()


def docker_prefix(config, directory):
    return [config["docker"], "--config", str(directory), "--host", config["endpoint"]]


def endpoint(value):
    text(value)
    require(value.startswith("unix:///") and "?" not in value and "#" not in value,
            "自動準備はローカルのunix socketを使うDockerだけに対応しています。")
    path = Path(value[len("unix://"):])
    require(path.is_absolute() and "," not in str(path), "Docker socketのパスを確認してください。")
    return "unix://" + str(path.resolve())


def normalize_image_reference(value):
    """Docker Hubのfamiliar formと完全修飾名だけを同じ参照へ揃える。"""
    require(IMAGE.fullmatch(text(value)) is not None, "imageのrepository digest形式を確認できません。")
    name, digest = value.rsplit("@", 1)
    parts = name.split("/")
    # repository:tag@digestのtagはdigestで指定した実体の照合には使わない。
    parts[-1] = parts[-1].split(":", 1)[0]
    first = parts[0]
    if len(parts) > 1 and ("." in first or ":" in first or first == "localhost"):
        registry, repository = first.lower(), "/".join(parts[1:])
    else:
        registry, repository = "docker.io", "/".join(parts)
    if registry == "index.docker.io":
        registry = "docker.io"
    if registry == "docker.io" and "/" not in repository:
        repository = "library/" + repository
    return registry, repository, digest


def inspect_image(prefix, image, allow_pull=False):
    result = run_bounded(prefix + ["image", "inspect", image], HOST_ENV, 30)
    if result.returncode and allow_pull:
        pulled = run_bounded(prefix + ["pull", image], HOST_ENV, 300)
        require(pulled.returncode == 0, "指定digestの公開imageを取得できません。通信・取得元・Dockerの状態を確認してください。")
        result = run_bounded(prefix + ["image", "inspect", image], HOST_ENV, 30)
    require(result.returncode == 0, "Dockerまたは指定imageを利用できません。daemonの起動・権限・imageの取得を確認してください。")
    images = parse_json(result.stdout)
    require(type(images) is list and len(images) == 1 and type(images[0]) is dict,
            "Docker imageの検査結果を確認できません。")
    image_data = images[0]
    require(IMAGE_ID.fullmatch(text(image_data.get("Id"))) is not None and image_data.get("Os") == "linux",
            "Linuxのimmutable image IDを確認できません。")
    digests = image_data.get("RepoDigests")
    require(type(digests) is list and normalize_image_reference(image)
            in [normalize_image_reference(value) for value in digests],
            "指定したrepository digestとimageが一致しません。")
    settings = image_data.get("Config")
    require(type(settings) is dict and not settings.get("Volumes"),
            "匿名の書込みvolumeを宣言したimageは使えません。Volumesのないimageを選んでください。")
    names = []
    for entry in settings.get("Env") or []:
        require(type(entry) is str and "=" in entry, "imageの環境変数形式を確認できません。")
        name = entry.split("=", 1)[0]
        require(ENV_NAME.fullmatch(name) is not None and name not in names,
                "imageの環境変数名が不正または重複しています。")
        names.append(name)
    return image_data["Id"], names


def validate_docker_cli(value):
    docker = Path(text(value))
    require(docker.is_absolute() and docker == docker.resolve() and docker.is_file()
            and os.access(str(docker), os.X_OK) and docker.stat().st_uid in (0, os.getuid())
            and not docker.stat().st_mode & 0o022, "Docker CLI実体の所有者・権限を確認してください。")
    return docker


def validate_config(config):
    expected = {"schema_version", "docker", "docker_sha256", "endpoint", "image", "image_id",
                "image_env_names", "uid", "gid", "limits"}
    require(type(config) is dict and set(config) == expected and config["schema_version"] == 1,
            "隔離設定の形式が未対応です。prepareで新しい設定を作ってください。")
    require(config["limits"] == LIMITS, "隔離の固定上限が変更されています。新しい設定を作ってください。")
    require(type(config["uid"]) is int and type(config["gid"]) is int
            and config["uid"] == os.getuid() and config["gid"] == os.getgid() and config["uid"] != 0,
            "root以外の現在のUID/GIDで隔離を準備してください。")
    docker = validate_docker_cli(config["docker"])
    require(re.fullmatch(r"[0-9a-f]{64}", text(config["docker_sha256"])) is not None
            and digest_file(docker) == config["docker_sha256"], "準備後にDocker CLIが変更されています。")
    require(endpoint(config["endpoint"]) == config["endpoint"], "Docker endpointが変更されています。")
    require(IMAGE.fullmatch(text(config["image"])) is not None
            and IMAGE_ID.fullmatch(text(config["image_id"])) is not None,
            "imageはrepository digestとimage IDへ固定してください。")
    names = config["image_env_names"]
    require(type(names) is list and len(names) <= 200 and len(names) == len(set(names))
            and all(type(name) is str and ENV_NAME.fullmatch(name) for name in names),
            "imageの環境変数名の記録が不正です。")
    return config


def mount(source, destination):
    source = str(source)
    require(not any(c in source for c in (",", "\n", "\r")), "mount入力に未対応の文字があります。")
    return ["--mount", "type=bind,src=" + source + ",dst=" + destination + ",readonly"]


def container_command(prefix, config, name, candidate, worker, inputs):
    uid, gid = config["uid"], config["gid"]
    command = prefix + [
        "run", "--rm", "--name", name, "--pull", "never", "--read-only", "--network", "none",
        "--ipc", "none", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
        "--pids-limit", str(LIMITS["pids"]), "--cpus", str(LIMITS["cpus"]),
        "--memory", str(LIMITS["memory_bytes"]), "--memory-swap", str(LIMITS["memory_bytes"]),
        "--ulimit", "fsize={0}:{0}".format(LIMITS["file_bytes"]), "--ulimit", "core=0:0",
        "--log-driver", "none", "--no-healthcheck", "--user", str(uid) + ":" + str(gid),
        "--workdir", "/scratch", "--entrypoint", "/bin/sh",
        "--tmpfs", "/scratch:rw,exec,nosuid,nodev,size=" + str(LIMITS["scratch_bytes"])
        + ",uid=" + str(uid) + ",gid=" + str(gid) + ",mode=0700",
    ]
    # imageに設定されたENVを空にし、bootstrapのshellにも引き継がない。
    for variable in config["image_env_names"]:
        command += ["--env", variable + "="]
    command += ["--env", "PATH=" + WORKER_PATH, "--env", "HOME=/scratch/home",
                "--env", "TMPDIR=/scratch/tmp", "--env", "LANG=C.UTF-8"]
    command += mount(candidate, "/candidate") + mount(worker, "/worker")
    for index, path in enumerate(inputs):
        command += mount(path, "/inputs/" + str(index))
    return command + [config["image_id"], "-c", BOOTSTRAP]


def archive_name(member):
    name = member.name
    if name in (".", "./"):
        require(member.isdir(), "出力archiveのrootが不正です。")
        return None
    if name.startswith("./"):
        name = name[2:]
    if name.endswith("/"):
        name = name[:-1]
    return relative(name).as_posix()


def extract_output(data, output):
    """tarを検査後、通常ファイルだけを専用出力先へ排他的に保存する。"""
    output = real_directory(output, private=True)
    require(not any(output.iterdir()), "専用出力先は空にしてください。")
    require(len(data) <= MAX_TAR, "出力archiveの容量が上限を超えています。")
    entries = []
    names = set()
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
        for index, member in enumerate(archive):
            require(index < LIMITS["output_files"], "出力archiveの件数が上限を超えています。")
            require((member.isdir() or member.isreg()) and not member.linkname and not member.sparse,
                    "出力archiveのlink・特殊ファイルは取り出せません。")
            name = archive_name(member)
            if name is None:
                continue
            require(name not in names, "出力archiveに重複パスがあります。")
            names.add(name)
            require(0 <= member.size <= LIMITS["file_bytes"], "出力ファイルの容量が上限を超えています。")
            total += member.size
            require(total <= LIMITS["output_bytes"], "出力の合計容量が上限を超えています。")
            entries.append((name, member))
        # fileを親directoryとして使うarchiveも、書込みを始める前に拒否する。
        files = {name for name, member in entries if member.isreg()}
        require(all(not any(parent.as_posix() in files for parent in PurePosixPath(name).parents
                            if parent.as_posix() != ".") for name, _member in entries),
                "出力archiveのdirectoryとfileが衝突しています。")
        root_fd = os.open(str(output), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for name, member in entries:
                parts = name.split("/")
                descriptor = os.dup(root_fd)
                try:
                    for part in parts if member.isdir() else parts[:-1]:
                        try:
                            os.mkdir(part, 0o700, dir_fd=descriptor)
                        except FileExistsError:
                            pass
                        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                        dir_fd=descriptor)
                        os.close(descriptor)
                        descriptor = child
                    if member.isreg():
                        fd = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                     0o600, dir_fd=descriptor)
                        with os.fdopen(fd, "wb") as destination, archive.extractfile(member) as source:
                            remaining = member.size
                            while remaining:
                                block = source.read(min(remaining, 1024 * 1024))
                                require(block, "出力archiveの内容が不足しています。")
                                destination.write(block)
                                remaining -= len(block)
                finally:
                    os.close(descriptor)
        finally:
            os.close(root_fd)
    return {"files": len(files), "bytes": total}


def execute(config, candidate, worker, output, inputs=()):
    validate_config(config)
    candidate = real_directory(candidate)
    worker = Path(worker).absolute()
    read_file(worker)
    paths = [Path(path).absolute() for path in inputs]
    require(len(paths) <= 200, "追加入力が多すぎます。")
    for path in paths:
        read_file(path, 128 * 1024 ** 2)
    output = real_directory(output, private=True)
    require(not any(output.iterdir()), "専用出力先は空にしてください。")
    name = "skill-upgrade-" + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="upgrade-docker-config-") as temporary:
        prefix = docker_prefix(config, temporary)
        image_id, names = inspect_image(prefix, config["image"])
        require(image_id == config["image_id"] and names == config["image_env_names"],
                "準備後にimageの実体または環境設定が変更されています。")
        command = container_command(prefix, config, name, candidate, worker, paths)
        try:
            result = run_bounded(command, HOST_ENV, LIMITS["wall_seconds"], max_stdout=MAX_TAR)
            require(result.stdout, "隔離環境の起動またはworkerの出力取得に失敗しました。image内のsh・cp・chmod・mkdir・env・tar・catを確認してください。")
            counts = extract_output(result.stdout, output)
            status_path = output / "exit-code"
            status_text = read_file(status_path, 16).decode("ascii").strip()
            require(re.fullmatch(r"[0-9]{1,3}", status_text) is not None,
                    "workerの終了状態を確認できません。")
            worker_status = int(status_text)
            require(0 <= worker_status <= 255 and result.returncode == worker_status,
                    "workerと隔離環境の終了状態が一致しません。")
            return result.returncode, counts
        finally:
            try:
                cleaned = run_bounded(prefix + ["rm", "--force", name], HOST_ENV, 20,
                                      max_stdout=65536, max_stderr=65536)
                # --rmですでに消えた場合もある。daemon接続失敗を消失と取り違えない。
                if cleaned.returncode:
                    remaining = run_bounded(prefix + ["container", "ls", "--all", "--filter", "name=^/" + name + "$",
                                                     "--format", "{{.Names}}"], HOST_ENV, 20,
                                            max_stdout=65536, max_stderr=65536)
                    require(remaining.returncode == 0 and not remaining.stdout.strip(),
                            "専用コンテナの終了を確認できません。")
            except (OSError, SandboxError, subprocess.SubprocessError) as error:
                raise SandboxError("専用コンテナ " + name + " の終了を確認できません。Dockerの状態を確認してください。") from error


def validate_probe(output):
    def value(name):
        return read_file(output / name, 65536).decode("ascii").strip()
    require(value("probe.txt") == "probe-ok", "隔離環境の読取り専用入力を確認できません。")
    require(value("probe-exec.txt") == "probe-exec-ok", "scratch内のファイルを直接実行できません。")
    interfaces = {}
    for line in value("network.txt").splitlines():
        fields = line.split()
        require(len(fields) == 2 and fields[0] not in interfaces,
                "隔離環境のinterface情報を確認できません。")
        interfaces[fields[0]] = int(fields[1], 16)
    loopbacks = {name for name, flags in interfaces.items() if flags & 0x8}
    require("lo" in loopbacks and all(flags & 0x8 or not flags & 0x1 for flags in interfaces.values()),
            "loopback以外に有効なinterfaceがあり、外部通信の遮断を確認できません。")
    routes4 = value("routes-v4.txt").splitlines()
    require(routes4 and routes4[0].split() and routes4[0].split()[0] == "Iface"
            and all(len(line.split()) >= 11 and line.split()[0] in loopbacks for line in routes4[1:])
            and all(len(line.split()) >= 10 and line.split()[-1] in loopbacks
                    for line in value("routes-v6.txt").splitlines()),
            "loopback以外の経路があり、外部通信の遮断を確認できません。")
    status = dict(line.split(":", 1) for line in value("status.txt").splitlines() if ":" in line)
    require(int(status.get("CapEff", "-1").strip(), 16) == 0
            and status.get("NoNewPrivs", "").strip() == "1",
            "隔離環境の権限制限が適用されていません。")
    mounts = {}
    for line in value("mounts.txt").splitlines():
        fields = line.split()
        require(len(fields) >= 4, "隔離環境のmount情報を確認できません。")
        mounts[fields[1]] = (fields[2], fields[3].split(","))
    require(all(path in mounts and "ro" in mounts[path][1] for path in ("/", "/candidate", "/worker")),
            "入力とtoolchainの読み取り専用mountを確認できません。")
    scratch = mounts.get("/scratch")
    require(scratch is not None and scratch[0] == "tmpfs" and "noexec" not in scratch[1],
            "実行可能な容量制限付きscratchを確認できません。")
    sizes = [option[5:] for option in scratch[1] if option.startswith("size=")]
    require(len(sizes) == 1 and re.fullmatch(r"[0-9]+[kKmMgG]?", sizes[0]),
            "scratchの容量上限を確認できません。")
    size = sizes[0]
    multiplier = {"k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}
    amount = int(size[:-1]) * multiplier[size[-1].lower()] if size[-1].isalpha() else int(size)
    require(0 < amount <= LIMITS["scratch_bytes"], "scratchの容量上限が適用されていません。")
    memory = int(value("memory.max"))
    require(0 < memory <= LIMITS["memory_bytes"]
            and 0 < int(value("pids.max")) <= LIMITS["pids"],
            "Dockerのmemory・process上限が適用されていません。cgroup対応を確認してください。")
    if (output / "cpu.max").exists():
        quota, period = map(int, value("cpu.max").split())
        require(int(value("memory.swap.max")) == 0, "Dockerのswap禁止を確認できません。")
    else:
        quota, period = int(value("cpu.quota")), int(value("cpu.period"))
        require(int(value("memory.memsw")) == memory, "Dockerのswap禁止を確認できません。")
    require(period > 0 and 0 < quota <= LIMITS["cpus"] * period,
            "DockerのCPU上限が適用されていません。cgroup対応を確認してください。")
    return {"readonly_mounts": True, "network_none": True, "capabilities_dropped": True,
            "no_new_privileges": True, "scratch_bytes": amount, "memory_bytes": memory,
            "pids": int(value("pids.max")), "cpu_quota": quota, "cpu_period": period, "swap_disabled": True}


def probe(config, directory):
    with tempfile.TemporaryDirectory(prefix=".probe-", dir=str(directory)) as temporary:
        root = Path(temporary)
        candidate = root / "candidate"
        candidate.mkdir(mode=0o700)
        write_exclusive(candidate / "probe-input", b"readonly\n", 0o400)
        worker = root / "worker.sh"
        write_exclusive(worker, PROBE_WORKER.encode("ascii"), 0o400)
        candidate.chmod(0o500)
        output = root / "output"
        output.mkdir(mode=0o700)
        try:
            code, _counts = execute(config, candidate, worker, output)
            require(code == 0, "隔離環境の自己診断が失敗しました。必要なmount・cgroup・通信制御を確認してください。")
            return validate_probe(output)
        finally:
            candidate.chmod(0o700)


def prepare(args):
    run = real_directory(args.run, private=True)
    script_dir = Path(__file__).resolve().parent
    skill_name = script_dir.parent.name
    require(skill_name in ("minor-version-upgrade", "major-version-upgrade"),
            "prepareはスキル本体のscripts/docker-sandbox.pyから実行してください。")
    artifact_root = script_dir.parents[3] / "artifacts" / skill_name
    require(artifact_root == artifact_root.resolve() and artifact_root in run.parents,
            "実行記録はnew-run.shが作成した、このスキルのartifacts配下を指定してください。")
    require(os.getuid() != 0, "root以外の利用者として実行してください。")
    require(IMAGE.fullmatch(text(args.image)) is not None,
            "事前に出所を確認したimageをname@sha256:<64桁>で指定してください。可変tagは使えません。")
    worker_name = relative(args.worker)
    worker = run / worker_name
    read_file(worker)
    docker_name = args.docker or shutil.which("docker", path=DOCKER_DISCOVERY_PATH)
    require(docker_name is not None, "Docker CLIが見つかりません。既存のDocker EngineまたはDocker Desktopが必要です。")
    require(Path(docker_name).is_absolute(), "Docker CLIは絶対パスで指定してください。")
    docker = validate_docker_cli(str(Path(docker_name).resolve()))
    # contextの読取りだけは既存のuser設定を使う。実行時は空configと固定endpointへ切り替える。
    discovery_env = dict(HOST_ENV)
    discovery_env["HOME"] = str(Path.home())
    if os.environ.get("DOCKER_CONFIG"):
        discovery_env["DOCKER_CONFIG"] = os.environ["DOCKER_CONFIG"]
    if args.context is None and not os.environ.get("DOCKER_CONTEXT") and os.environ.get("DOCKER_HOST"):
        host = endpoint(os.environ["DOCKER_HOST"])
    else:
        selected_context = args.context or os.environ.get("DOCKER_CONTEXT")
        command = [str(docker), "context", "inspect", "--format", "{{json .Endpoints.docker.Host}}"]
        if selected_context:
            command.append(text(selected_context, 200))
        inspected = run_bounded(command, discovery_env, 20, max_stdout=65536)
        require(inspected.returncode == 0,
                "Docker contextを読み取れません。既存contextまたはローカルDOCKER_HOSTを確認してください。")
        host = endpoint(parse_json(inspected.stdout))
    config = {"schema_version": 1, "docker": str(docker), "docker_sha256": digest_file(docker),
              "endpoint": host, "image": args.image, "image_id": "", "image_env_names": [],
              "uid": os.getuid(), "gid": os.getgid(), "limits": dict(LIMITS)}
    with tempfile.TemporaryDirectory(prefix="upgrade-docker-config-") as temporary:
        image_id, names = inspect_image(docker_prefix(config, temporary), args.image,
                                        allow_pull=not args.no_pull)
    config["image_id"], config["image_env_names"] = image_id, names
    validate_config(config)
    sandbox = run / "sandbox"
    if not sandbox.exists():
        sandbox.mkdir(mode=0o700)
    real_directory(sandbox)
    evidence = run / "evidence"
    if not evidence.exists():
        evidence.mkdir(mode=0o700)
    real_directory(evidence)
    destinations = (sandbox / "config.json", sandbox / "executor",
                    evidence / "isolation-setup.json")
    require(all(not path.exists() and not path.is_symlink() for path in destinations),
            "既存の隔離設定は上書きしません。新しい実行記録を作ってください。")
    interpreter = str(Path(sys.executable).resolve())
    require(not any(c.isspace() for c in interpreter) and len(interpreter.encode("utf-8")) <= 240,
            "executor用の信頼済みPython実体は空白なし・240 bytes以内のパスが必要です。")
    controls = probe(config, sandbox)
    source = read_file(Path(__file__).resolve())
    body = source.split(b"\n", 1)[1] if source.startswith(b"#!") else source
    launcher = ("#!" + interpreter + " -IS\n").encode("utf-8") + body
    report = {"prepared_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
              "backend": "docker", "image": config["image"], "image_id": config["image_id"],
              "docker_sha256": config["docker_sha256"], "limits": dict(LIMITS), "probe": controls,
              "review_required": True}
    write_exclusive(sandbox / "config.json", json_bytes(config))
    write_exclusive(sandbox / "executor", launcher, 0o700)
    write_exclusive(evidence / "isolation-setup.json", json_bytes(report))
    print(json.dumps({"status": "prepared", "config": str(sandbox / "config.json"),
                      "executor": str(sandbox / "executor"),
                      "evidence": str(evidence / "isolation-setup.json"), "review_required": True},
                     ensure_ascii=True))
    return 0


def main():
    def interrupted(_signal, _frame):
        raise SandboxError("隔離処理を中断しました。専用コンテナを終了します。")
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description="既存Dockerから依存更新用の隔離を準備・実行する。")
    actions = parser.add_subparsers(dest="action", required=True)
    setup = actions.add_parser("prepare", help="設定・executorの生成と自己診断")
    setup.add_argument("--run", required=True)
    setup.add_argument("--image", required=True)
    setup.add_argument("--worker", required=True)
    setup.add_argument("--docker")
    setup.add_argument("--context")
    setup.add_argument("--no-pull", action="store_true", help="未取得のimageを自動取得しない")
    execute_parser = actions.add_parser("execute", help="固定した設定でworkerを隔離実行")
    execute_parser.add_argument("--config", required=True)
    execute_parser.add_argument("--candidate", required=True)
    execute_parser.add_argument("--worker", required=True)
    execute_parser.add_argument("--output", required=True)
    execute_parser.add_argument("--input", action="append", default=[])
    args = parser.parse_args()
    if args.action == "prepare":
        return prepare(args)
    config = parse_json(read_file(Path(args.config).absolute()))
    code, counts = execute(config, args.candidate, args.worker, args.output, args.input)
    print(json.dumps({"status": "succeeded" if code == 0 else "failed", "exit_code": code,
                      "output": counts}, ensure_ascii=True))
    return 0 if code == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SandboxError as error:
        print("隔離環境を準備・実行できません: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError, KeyError, tarfile.TarError, subprocess.SubprocessError):
        print("隔離環境を準備・実行できません: Dockerの状態・入力形式・権限・容量を確認してください。", file=sys.stderr)
        sys.exit(1)
