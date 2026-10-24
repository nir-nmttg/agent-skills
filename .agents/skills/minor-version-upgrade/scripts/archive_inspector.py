"""配布物を展開・実行せず、上限付きで静的検査する（Python 3.9 以降）。

兆候はレビュー対象であり、安全性の判定ではない。未対応形式や構造の曖昧さは
InspectionError で停止する。圧縮物・通常ファイル・全展開量をそれぞれ制限し、
tar の拡張ヘッダーも逐次処理する。検査対象のコードや YAML は実行しない。
"""

import binascii
import gzip
import io
import json
import lzma
import ntpath
import os
from pathlib import Path
import posixpath
import re
import stat
import struct
import tarfile
import unicodedata
import zipfile
import zlib


MAX_ARTIFACT_BYTES = 128 * 1024 * 1024
MAX_UNPACKED_BYTES = 128 * 1024 * 1024
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_MEMBERS = 10000
MAX_SIGNALS = 20000
MAX_PATH_CHARS = 4096
MAX_TAR_BYTES = MAX_UNPACKED_BYTES + MAX_MEMBERS * 1024 + 1024
LZMA_MEMORY_BYTES = 64 * 1024 * 1024
CHUNK_BYTES = 64 * 1024


class InspectionError(ValueError):
    """完全に検査できなかった配布物を採用しないための例外。"""


_LIFECYCLE_SCRIPTS = frozenset((
    "preinstall", "install", "postinstall", "prepare", "preprepare",
    "postprepare", "prepack", "postpack", "prepublish", "prepublishOnly",
    "publish", "postpublish", "dependencies",
))
_STATIC_PATTERNS = (
    ("process-execution", re.compile(
        rb"\b(?:subprocess|Popen|os\.system|child_process|spawn|Open3|"
        rb"Kernel\.system|IO\.popen|Process\.spawn)\b")),
    ("network-access", re.compile(
        rb"https?://|\b(?:socket|curl|wget)\b|fetch\s*\(|requests\.|"
        rb"urllib\.|Net::HTTP", re.IGNORECASE)),
    ("secret-environment-access", re.compile(
        rb"process\.env|os\.environ|ENV\s*\[|\.ssh\b|\.aws\b|"
        rb"\.npmrc\b|\.pypirc\b|id_rsa|AWS_(?:SECRET|ACCESS)|"
        rb"(?:TOKEN|PASSWORD|SECRET)_", re.IGNORECASE)),
    ("dynamic-code-loading", re.compile(
        rb"\b(?:eval|exec|compile|Function|pickle\.loads|marshal\.loads)"
        rb"\s*\(|\b(?:b64decode|atob)\s*\(")),
)
_NATIVE_SUFFIX = re.compile(
    r"\.(?:so(?:\.[0-9]+)*|node|dll|dylib|pyd|exe|com|a|o|lib|wasm)$",
    re.IGNORECASE,
)


def _safe_path(name):
    if not isinstance(name, str) or not name or len(name) > MAX_PATH_CHARS:
        raise InspectionError("配布物のパスが空、または長さの上限を超えています")
    if any(unicodedata.category(char) in ("Cc", "Cf", "Cs") for char in name):
        raise InspectionError("配布物のパスに制御文字が含まれています")
    if "\\" in name or ":" in name or name.startswith("/") or ntpath.splitdrive(name)[0]:
        raise InspectionError("配布物に絶対パス・Windows パス・バックスラッシュがあります")
    if ".." in name.split("/"):
        raise InspectionError("配布物に親ディレクトリへ移動するパスがあります")
    # Windows/macOS の大文字小文字・Unicode 正規化による衝突も拒否する。
    normalized = unicodedata.normalize("NFC", posixpath.normpath(name)).casefold()
    if normalized.startswith("/") or normalized in ("", ".."):
        raise InspectionError("配布物のパスを安全に正規化できません")
    if any(part.endswith((" ", ".")) for part in normalized.split("/") if part != "."):
        raise InspectionError("配布物に末尾の空白・ドットによる曖昧なパスがあります")
    reserved = {"con", "prn", "aux", "nul"}
    reserved.update("com" + str(number) for number in range(1, 10))
    reserved.update("lpt" + str(number) for number in range(1, 10))
    if any(part.split(".", 1)[0] in reserved for part in normalized.split("/")):
        raise InspectionError("配布物に Windows の予約デバイス名があります")
    return normalized


class _Budget:
    def __init__(self):
        self.members = 0
        self.unpacked_bytes = 0
        self.signals = []
        self.signal_keys = set()

    def member(self, size):
        if not isinstance(size, int) or size < 0 or size > MAX_FILE_BYTES:
            raise InspectionError("配布物の単一ファイルが 16 MiB の上限を超えています")
        self.members += 1
        self.unpacked_bytes += size
        if self.members > MAX_MEMBERS or self.unpacked_bytes > MAX_UNPACKED_BYTES:
            raise InspectionError("配布物が 10000 件または全展開量 128 MiB の上限を超えています")

    def signal(self, path, kind):
        key = (path, kind)
        if key in self.signal_keys:
            return
        if len(self.signals) >= MAX_SIGNALS:
            raise InspectionError("静的検査の兆候が 20000 件の保持上限を超えています")
        self.signal_keys.add(key)
        self.signals.append({"path": path, "kind": kind})


class _Paths:
    def __init__(self):
        self.entries = {}
        self.implicit_directories = set()

    def add(self, name, directory):
        normalized = _safe_path(name)
        if normalized == "." and not directory:
            raise InspectionError("配布物のルートを通常ファイルとして扱うパスがあります")
        if normalized in self.entries:
            raise InspectionError("配布物に正規化後の重複パスがあります")
        if not directory and normalized in self.implicit_directories:
            raise InspectionError("配布物に通常ファイルとディレクトリの衝突があります")
        parts = normalized.split("/")
        for index in range(1, len(parts)):
            parent = "/".join(parts[:index])
            if parent in self.entries and not self.entries[parent]:
                raise InspectionError("配布物に通常ファイルを親にするパスがあります")
            self.implicit_directories.add(parent)
        self.entries[normalized] = directory


def _read_artifact(path):
    # 非通常ファイルは open 前後とも拒否し、最終要素の symlink を追わない。
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode):
        raise InspectionError("検査対象は symlink・特殊ファイルではない通常ファイルが必要です")
    if before.st_size <= 0 or before.st_size > MAX_ARTIFACT_BYTES:
        raise InspectionError("配布物が空、または圧縮済みサイズ 128 MiB の上限を超えています")
    if not hasattr(os, "O_NOFOLLOW"):
        raise InspectionError("この環境では symlink を追わない安全な読取りを利用できません")
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if not stat.S_ISREG(opened.st_mode) or _identity(before) != _identity(opened):
            raise InspectionError("検査対象が読取り前に変更されています")
        chunks = []
        size = 0
        while True:
            chunk = stream.read(min(CHUNK_BYTES, MAX_ARTIFACT_BYTES - size + 1))
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_ARTIFACT_BYTES:
                raise InspectionError("配布物の読取りが 128 MiB の上限を超えています")
            chunks.append(chunk)
        after = os.fstat(stream.fileno())
        if _identity(opened) != _identity(after) or size != opened.st_size:
            raise InspectionError("検査対象が読取り中に変更されています")
    if _identity(after) != _identity(os.lstat(path)):
        raise InspectionError("検査対象のパスが読取り中に置き換わっています")
    return b"".join(chunks)


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def _decompress(data, kind, limit):
    chunks = []
    size = 0
    if kind == "gzip":
        with gzip.GzipFile(fileobj=io.BytesIO(data), mode="rb") as stream:
            while True:
                chunk = stream.read(min(CHUNK_BYTES, limit - size + 1))
                if not chunk:
                    break
                size += len(chunk)
                if size > limit:
                    raise InspectionError("gzip の展開量が検査上限を超えています")
                chunks.append(chunk)
    elif kind == "xz":
        decoder = lzma.LZMADecompressor(format=lzma.FORMAT_XZ, memlimit=LZMA_MEMORY_BYTES)
        cursor = 0
        while not decoder.eof:
            if decoder.needs_input:
                piece = data[cursor:cursor + CHUNK_BYTES]
                cursor += len(piece)
                if not piece:
                    raise InspectionError("xz のデータが途中で切れています")
            else:
                piece = b""
            chunk = decoder.decompress(piece, max_length=min(CHUNK_BYTES, limit - size + 1))
            size += len(chunk)
            if size > limit:
                raise InspectionError("xz の展開量が検査上限を超えています")
            chunks.append(chunk)
        if decoder.unused_data or cursor != len(data):
            raise InspectionError("xz の連結ストリーム・末尾データは未対応です")
    else:
        raise InspectionError("未対応の圧縮形式です")
    return b"".join(chunks)


def _no_duplicate_json(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InspectionError("package.json に重複したキーがあります")
        result[key] = value
    return result


def _scan(data, name, budget, executable=False):
    basename = posixpath.basename(name).lower()
    if executable:
        budget.signal(name, "executable-mode")
    if _NATIVE_SUFFIX.search(name) or data[:4] in (b"\x7fELF", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe") or data[:2] == b"MZ":
        budget.signal(name, "native-executable")
    if basename.endswith(".gemspec") or basename in ("extconf.rb", "rakefile"):
        budget.signal(name, "ruby-build-code")
    if basename.endswith((".pth", "._pth", ".start")) or basename in ("sitecustomize.py", "usercustomize.py"):
        budget.signal(name, "python-startup-code")
    if basename in ("setup.py", "setup.cfg", "pyproject.toml"):
        budget.signal(name, "python-build-definition")
    if basename.endswith((".zip", ".whl", ".gem", ".tar", ".tar.gz", ".tgz", ".tar.xz")):
        budget.signal(name, "nested-archive-review")
    if basename == "package.json":
        metadata = json.loads(data.decode("utf-8-sig"), object_pairs_hook=_no_duplicate_json)
        if not isinstance(metadata, dict):
            raise InspectionError("package.json が JSON オブジェクトではありません")
        scripts = metadata.get("scripts", {})
        if not isinstance(scripts, dict):
            raise InspectionError("package.json の scripts を検査できません")
        for script in sorted(_LIFECYCLE_SCRIPTS.intersection(scripts)):
            budget.signal(name, "node-lifecycle-script:" + script)
        if metadata.get("bin"):
            budget.signal(name, "node-bin-entry")
    if basename in ("metadata", "metadata.yaml") and re.search(rb"(?m)^\s*(?:extensions|executables):", data):
        budget.signal(name, "ruby-metadata-execution")
    if data.startswith(b"#!"):
        budget.signal(name, "script-entrypoint")
    for kind, pattern in _STATIC_PATTERNS:
        if pattern.search(data):
            budget.signal(name, kind)


def _pax(data):
    result = {}
    cursor = 0
    records = 0
    while cursor < len(data):
        space = data.find(b" ", cursor, min(len(data), cursor + 24))
        if space < 0 or not data[cursor:space].isdigit():
            raise InspectionError("PAX ヘッダーの長さを検査できません")
        length = int(data[cursor:space])
        end = cursor + length
        if length < 5 or end > len(data) or data[end - 1:end] != b"\n":
            raise InspectionError("PAX ヘッダーが破損しています")
        key, separator, value = data[space + 1:end - 1].partition(b"=")
        if not separator or not key:
            raise InspectionError("PAX ヘッダーのキーを検査できません")
        key = key.decode("utf-8")
        value = value.decode("utf-8")
        if key in result:
            raise InspectionError("PAX ヘッダーに重複したキーがあります")
        if key.startswith("GNU.sparse") or key in ("SCHILY.realsize", "SCHILY.filetype"):
            raise InspectionError("sparse・特殊ファイルの PAX 拡張は検査対象外です")
        if key == "hdrcharset" and value != "ISO-IR 10646 2000 UTF-8":
            raise InspectionError("UTF-8 以外の PAX パスは検査対象外です")
        if key in ("path", "linkpath"):
            _safe_path(value)
        result[key] = value
        cursor = end
        records += 1
        if records > MAX_MEMBERS:
            raise InspectionError("PAX ヘッダーのレコード数が検査上限を超えています")
    return result


def _tar(data, budget, prefix="", gem=False):
    if len(data) > MAX_TAR_BYTES or len(data) % 512:
        raise InspectionError("tar のサイズが検査上限を超えているか、ブロックが破損しています")
    cursor = 0
    paths = _Paths()
    global_pax = {}
    pending_pax = {}
    longname = None
    pending_extension = False
    gem_parts = {}
    terminated = False
    while cursor < len(data):
        block = data[cursor:cursor + 512]
        cursor += 512
        if block == b"\0" * 512:
            if pending_extension or data[cursor:cursor + 512] != b"\0" * 512 or any(data[cursor:]):
                raise InspectionError("tar の終端・拡張ヘッダー・末尾データを検査できません")
            terminated = True
            break
        info = tarfile.TarInfo.frombuf(block, "utf-8", "strict")
        _safe_path(info.name)
        if info.size < 0 or info.size > MAX_FILE_BYTES:
            raise InspectionError("tar の単一ファイルが 16 MiB の上限を超えています")
        extension = info.type in (tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.GNUTYPE_LONGNAME)
        if not extension and info.type not in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE):
            raise InspectionError("tar にリンク・device・FIFO・sparse・未対応形式があります")
        pax = dict(global_pax)
        pax.update(pending_pax)
        size = info.size
        if not extension and "size" in pax:
            if not re.fullmatch(r"[0-9]{1,12}", pax["size"]):
                raise InspectionError("PAX のファイルサイズを検査できません")
            size = int(pax["size"])
        budget.member(size)
        end = cursor + size
        padded_end = cursor + ((size + 511) // 512) * 512
        if padded_end > len(data):
            raise InspectionError("tar のファイル内容が途中で切れています")
        payload = data[cursor:end]
        if any(data[end:padded_end]):
            raise InspectionError("tar のパディングに未検査のデータがあります")
        cursor = padded_end
        if extension:
            if info.type == tarfile.GNUTYPE_LONGNAME:
                if longname is not None:
                    raise InspectionError("GNU longname ヘッダーが重複しています")
                longname = payload.rstrip(b"\0").decode("utf-8")
                _safe_path(longname)
            else:
                fields = _pax(payload)
                if info.type == tarfile.XGLTYPE:
                    global_pax.update(fields)
                else:
                    if set(fields).intersection(pending_pax):
                        raise InspectionError("PAX 拡張ヘッダーが重複しています")
                    pending_pax.update(fields)
            pending_extension = True
            continue
        name = pax.get("path", longname if longname is not None else info.name)
        if "linkpath" in pax or info.linkname:
            raise InspectionError("tar にリンク先を指定するヘッダーがあります")
        directory = info.type == tarfile.DIRTYPE
        if directory and size:
            raise InspectionError("tar のディレクトリに未検査の内容があります")
        paths.add(name, directory)
        display = prefix + name
        if not directory:
            _scan(payload, display, budget, executable=bool(info.mode & 0o111))
            if gem:
                gem_parts[name] = payload
        pending_pax = {}
        longname = None
        pending_extension = False
    if not terminated:
        raise InspectionError("tar の正常な終端を確認できません")
    if gem:
        if "data.tar.gz" not in gem_parts or "metadata.gz" not in gem_parts:
            raise InspectionError("gem に必須の data.tar.gz・metadata.gz がありません")
        _tar(_decompress(gem_parts["data.tar.gz"], "gzip", MAX_TAR_BYTES),
             budget, prefix="data.tar.gz!/")
        metadata = _decompress(gem_parts["metadata.gz"], "gzip", MAX_FILE_BYTES)
        # YAML オブジェクトの構築・Ruby タグの評価は一切行わない。
        metadata.decode("utf-8")
        budget.member(len(metadata))
        _scan(metadata, "metadata.gz!/metadata", budget)
        if "checksums.yaml.gz" in gem_parts:
            checksums = _decompress(gem_parts["checksums.yaml.gz"], "gzip", MAX_FILE_BYTES)
            checksums.decode("utf-8")
            budget.member(len(checksums))
            _scan(checksums, "checksums.yaml.gz!/checksums.yaml", budget)


def _zip_extra(data):
    cursor = 0
    while cursor < len(data):
        if len(data) - cursor < 4:
            raise InspectionError("ZIP の extra ヘッダーが破損しています")
        kind, length = struct.unpack_from("<HH", data, cursor)
        cursor += 4
        if cursor + length > len(data):
            raise InspectionError("ZIP の extra ヘッダーが途中で切れています")
        if kind in (0x0001, 0x7075, 0x000D, 0x756E):
            raise InspectionError("ZIP64・別パス・Unix 特殊情報の ZIP 拡張は未対応です")
        cursor += length


def _zip_preflight(data):
    # ZipFile が全 central directory を構築する前に実際の件数を制限する。
    end = data.rfind(b"PK\x05\x06", max(0, len(data) - 65557))
    if end < 0 or len(data) - end < 22:
        raise InspectionError("ZIP の終端を確認できません")
    values = struct.unpack_from("<4s4H2LH", data, end)
    _, disk, central_disk, disk_count, count, central_size, central_start, comment_size = values
    if end + 22 + comment_size != len(data) or disk or central_disk or disk_count != count:
        raise InspectionError("ZIP の分割構成・末尾データ・終端情報は検査できません")
    if count == 65535 or central_size == 0xffffffff or central_start == 0xffffffff:
        raise InspectionError("ZIP64 は検査対象外です")
    if count > MAX_MEMBERS or central_start + central_size != end:
        raise InspectionError("ZIP の件数が上限を超えるか、central directory が破損しています")
    cursor = central_start
    actual = 0
    intervals = []
    payloads = {}
    while cursor < end:
        if end - cursor < 46:
            raise InspectionError("ZIP の central directory が途中で切れています")
        fields = struct.unpack_from("<4s6H3L5H2L", data, cursor)
        signature, _, _, flags, method, _, _, crc, packed, unpacked, nlen, xlen, clen, member_disk, _, _, local = fields
        next_cursor = cursor + 46 + nlen + xlen + clen
        if signature != b"PK\x01\x02" or next_cursor > end or member_disk:
            raise InspectionError("ZIP の central directory が破損しています")
        actual += 1
        if actual > MAX_MEMBERS or packed == 0xffffffff or unpacked > MAX_FILE_BYTES:
            raise InspectionError("ZIP の件数・ファイルサイズが上限を超えるか、ZIP64 形式です")
        if flags & (0x0001 | 0x0040 | 0x2000) or method not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise InspectionError("ZIP の暗号化・未対応の圧縮方式は検査できません")
        raw_name = data[cursor + 46:cursor + 46 + nlen]
        _zip_extra(data[cursor + 46 + nlen:cursor + 46 + nlen + xlen])
        if local + 30 > central_start or data[local:local + 4] != b"PK\x03\x04":
            raise InspectionError("ZIP の local ヘッダーが破損しています")
        local_fields = struct.unpack_from("<4s5H3L2H", data, local)
        _, _, local_flags, local_method, _, _, local_crc, local_packed, local_unpacked, local_nlen, local_xlen = local_fields
        start = local + 30 + local_nlen + local_xlen
        stop = start + packed
        payload_stop = stop
        if stop > central_start or flags != local_flags or method != local_method:
            raise InspectionError("ZIP の local/central ヘッダーが一致しません")
        if data[local + 30:local + 30 + local_nlen] != raw_name:
            raise InspectionError("ZIP の local/central パスが一致しません")
        _zip_extra(data[local + 30 + local_nlen:start])
        if flags & 8:
            if data[stop:stop + 4] == b"PK\x07\x08":
                stop += 4
            if stop + 12 > central_start or struct.unpack_from("<3L", data, stop) != (crc, packed, unpacked):
                raise InspectionError("ZIP の data descriptor が破損しています")
            stop += 12
            if local_crc not in (0, crc) or local_packed not in (0, packed) or local_unpacked not in (0, unpacked):
                raise InspectionError("ZIP の local サイズ・CRC が一致しません")
        elif (local_crc, local_packed, local_unpacked) != (crc, packed, unpacked):
            raise InspectionError("ZIP の local サイズ・CRC が一致しません")
        intervals.append((local, stop))
        payloads[local] = (start, payload_stop, method, unpacked, crc)
        cursor = next_cursor
    if actual != count:
        raise InspectionError("ZIP の宣言件数と実際の件数が一致しません")
    previous = 0
    for start, stop in sorted(intervals):
        if start != previous:
            raise InspectionError("ZIP のメンバーが重複するか、未検査の領域があります")
        previous = stop
    if previous != central_start:
        raise InspectionError("ZIP の central directory 前に未検査の領域があります")
    return payloads


def _zip_payload(data, method, expected, crc):
    if method == zipfile.ZIP_STORED:
        payload = data
    else:
        # ZipExtFile は宣言サイズで読取りを終えるため、圧縮ストリーム自体の
        # 正常な終端と余剰出力も独立して確認する。
        decoder = zlib.decompressobj(-zlib.MAX_WBITS)
        chunks = []
        cursor = 0
        size = 0
        while not decoder.eof:
            if decoder.unconsumed_tail:
                piece = decoder.unconsumed_tail
            else:
                piece = data[cursor:cursor + CHUNK_BYTES]
                cursor += len(piece)
                if not piece:
                    raise InspectionError("ZIP の圧縮ストリームが途中で切れています")
            chunk = decoder.decompress(piece, min(CHUNK_BYTES, expected - size + 1))
            size += len(chunk)
            if size > expected or size > MAX_FILE_BYTES:
                raise InspectionError("ZIP の実際の展開量が宣言・検査上限を超えています")
            chunks.append(chunk)
        if decoder.unused_data or cursor != len(data):
            raise InspectionError("ZIP の圧縮ストリームに余剰データがあります")
        payload = b"".join(chunks)
    if len(payload) != expected or (binascii.crc32(payload) & 0xffffffff) != crc:
        raise InspectionError("ZIP の実際の展開量・CRC が宣言値と一致しません")
    return payload


def _zip(data, budget):
    payloads = _zip_preflight(data)
    paths = _Paths()
    with zipfile.ZipFile(io.BytesIO(data), "r") as archive:
        for info in archive.infolist():
            name = info.orig_filename
            _safe_path(name)
            directory = info.is_dir()
            unix_mode = info.external_attr >> 16
            file_type = stat.S_IFMT(unix_mode)
            if file_type not in (0, stat.S_IFREG, stat.S_IFDIR) or info.external_attr & 8:
                raise InspectionError("ZIP に symlink・device・FIFO・特殊ファイルがあります")
            if file_type == stat.S_IFDIR and not directory:
                raise InspectionError("ZIP のディレクトリ属性とパスが一致しません")
            if info.external_attr & 0x10 and not directory:
                raise InspectionError("ZIP の DOS ディレクトリ属性とパスが一致しません")
            if directory and (info.file_size or file_type == stat.S_IFREG):
                raise InspectionError("ZIP のディレクトリに通常ファイルの内容・属性があります")
            paths.add(name, directory)
            budget.member(info.file_size)
            start, stop, method, expected, crc = payloads[info.header_offset]
            payload = _zip_payload(data[start:stop], method, expected, crc)
            if not directory:
                _scan(payload, name, budget, executable=bool(unix_mode & 0o111))


def inspect_artifact(path: Path) -> dict:
    """通常ファイルの配布物を検査し、全件検査時だけ集計と兆候を返す。

    対応形式は gem、whl/zip、tar、tar.gz/tgz、tar.xz。暗号化 ZIP、ZIP64、
    sparse、リンク、連結 xz、曖昧なパス等は未対応として停止する。
    members/unpacked_bytes は gem の外側・内側・展開した metadata を合算する。
    """
    try:
        path = Path(path)
        name = path.name.lower()
        if name.endswith(".gem"):
            kind = "gem"
        elif name.endswith((".whl", ".zip")):
            kind = "wheel" if name.endswith(".whl") else "zip"
        elif name.endswith((".tar.gz", ".tgz")):
            kind = "tar.gz"
        elif name.endswith(".tar.xz"):
            kind = "tar.xz"
        elif name.endswith(".tar"):
            kind = "tar"
        else:
            raise InspectionError("配布物の形式は未対応です（gem/whl/zip/tar/tar.gz/tgz/tar.xz）")
        data = _read_artifact(path)
        budget = _Budget()
        if kind in ("wheel", "zip"):
            _zip(data, budget)
        else:
            if kind == "tar.gz":
                data = _decompress(data, "gzip", MAX_TAR_BYTES)
            elif kind == "tar.xz":
                data = _decompress(data, "xz", MAX_TAR_BYTES)
            _tar(data, budget, gem=(kind == "gem"))
        return {"format": kind, "members": budget.members,
                "unpacked_bytes": budget.unpacked_bytes, "signals": budget.signals}
    except InspectionError:
        raise
    except (OSError, EOFError, ValueError, OverflowError, RecursionError,
            tarfile.TarError, zipfile.BadZipFile, lzma.LZMAError, zlib.error,
            struct.error) as error:
        # 例外の本文には未検証のパス・配布物由来文字列を流さない。
        raise InspectionError("配布物が破損しているか、完全な静的検査を実行できません（" +
                              type(error).__name__ + "）") from None
