#!/usr/bin/env python3
"""ファイルを列挙し、内容確認後の改名計画を安全に適用する。Python 3.9 以上。"""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import stat
import sys
import unicodedata


MAX_NAME_BYTES = 240
FINGERPRINT_KEYS = ("device", "inode", "size", "mtime_ns")


class PlanError(Exception):
    pass


def emit(value):
    print(json.dumps(value, ensure_ascii=True), flush=True)


def fingerprint(info):
    return {
        "device": info.st_dev,
        "inode": info.st_ino,
        "size": info.st_size,
        "mtime_ns": info.st_mtime_ns,
    }


def directory_root(value):
    path = Path(value)
    if not path.is_absolute():
        raise PlanError("対象フォルダには絶対パスを指定してください。")
    try:
        path = path.resolve(strict=True)
    except (OSError, RuntimeError, ValueError) as exc:
        raise PlanError("対象フォルダを確認できません: {}".format(exc)) from exc
    if not path.is_dir():
        raise PlanError("対象パスはフォルダではありません。")
    return path


def directory_flags():
    if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
        raise PlanError("この環境は symlink を避けるディレクトリ操作に対応していません。")
    return os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def relative_name(parts):
    return "/".join(parts)


def inventory(root):
    files = []
    skipped = []
    root_fd = os.open(str(root), directory_flags())
    try:
        with os.scandir(root_fd) as entries:
            names = sorted(entry.name for entry in entries)
        for name in names:
            if name.startswith("."):
                skipped.append({"source": name, "reason": "隠しファイル・隠しフォルダは対象外です。"})
                continue
            try:
                info = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    skipped.append({"source": name, "reason": "symlink は追跡しません。"})
                elif stat.S_ISREG(info.st_mode):
                    files.append({"source": name, "fingerprint": fingerprint(info), "target": None, "reason": ""})
                elif stat.S_ISDIR(info.st_mode):
                    skipped.append({"source": name, "reason": "直下のファイルのみが対象のため、サブフォルダ内は除外しました。"})
                else:
                    skipped.append({"source": name, "reason": "通常ファイルではありません。"})
            except OSError as exc:
                skipped.append({"source": name, "reason": "確認できません: {}".format(exc)})
    finally:
        os.close(root_fd)
    files.sort(key=lambda item: item["source"])
    skipped.sort(key=lambda item: item["source"])
    return {"root": str(root), "recursive": False, "files": files, "skipped": skipped}


def source_parts(value):
    if not isinstance(value, str) or not value or "\x00" in value:
        raise PlanError("source は空でない相対パスにしてください。")
    parts = tuple(value.split("/"))
    if any(part in ("", ".", "..") for part in parts) or Path(value).is_absolute():
        raise PlanError("source に絶対パス、空の要素、.、.. は使えません: {!r}".format(value))
    if len(parts) != 1:
        raise PlanError("対象は指定フォルダの直下のファイルだけです: {!r}".format(value))
    if value.startswith("."):
        raise PlanError("隠しファイルは対象外です: {!r}".format(value))
    return parts


def validate_fingerprint(value, source):
    if not isinstance(value, dict) or any(type(value.get(key)) is not int for key in FINGERPRINT_KEYS):
        raise PlanError("fingerprint が不正です: {!r}".format(source))
    if any(value[key] < 0 for key in ("device", "inode", "size")):
        raise PlanError("fingerprint が不正です: {!r}".format(source))
    return {key: value[key] for key in FINGERPRINT_KEYS}


def extension(name):
    suffix = Path(name).suffix
    if suffix.lower() in (".gz", ".bz2", ".xz", ".zst", ".br"):
        previous = Path(name[:-len(suffix)]).suffix
        if previous:
            return previous + suffix
    return suffix


def validate_target(value, source):
    if value is None:
        return
    if not isinstance(value, str) or not value:
        raise PlanError("target はファイル名または null にしてください: {!r}".format(source))
    if any(char in '/\\<>:"|?*' or unicodedata.category(char) in ("Cc", "Cs") for char in value):
        raise PlanError("target に区切り文字、制御文字、使用できない記号があります: {!r}".format(source))
    if value.startswith(".") or value.endswith(".") or value[-1].isspace():
        raise PlanError("target の先頭の .、末尾の空白や . は使えません: {!r}".format(source))
    if len(value.encode("utf-8")) > MAX_NAME_BYTES:
        raise PlanError("target は UTF-8 で 240 byte 以下にしてください: {!r}".format(source))
    suffix = extension(source)
    if extension(value) != suffix:
        raise PlanError("target は元の拡張子を大文字・小文字も含めて維持してください: {!r}".format(source))
    stem = value[:-len(suffix)] if suffix else value
    match = re.fullmatch(r"([0-9]{4}-[0-9]{2}-[0-9]{2})_(.+)", stem)
    if match is None or not match.group(2).strip():
        raise PlanError("target は YYYY-MM-DD_名称 と元の拡張子で指定してください: {!r}".format(source))
    try:
        datetime.date.fromisoformat(match.group(1))
    except ValueError as exc:
        raise PlanError("target の日付が実在しません: {!r}".format(source)) from exc


class Directories:
    """root から symlink を通らずに開いた親ディレクトリを保持する。"""

    def __init__(self, root):
        self.handles = {(): os.open(str(root), directory_flags())}

    def get(self, parts):
        if parts not in self.handles:
            parent = self.get(parts[:-1])
            self.handles[parts] = os.open(parts[-1], directory_flags(), dir_fd=parent)
        return self.handles[parts]

    def close(self):
        for handle in self.handles.values():
            os.close(handle)


def verify_source(item, parent_fd):
    info = os.stat(item["parts"][-1], dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode):
        raise PlanError("通常ファイルではありません: {!r}".format(item["source"]))
    if fingerprint(info) != item["fingerprint"]:
        raise PlanError("列挙後にファイルが変わりました。再度列挙してください: {!r}".format(item["source"]))


def name_key(value):
    return unicodedata.normalize("NFC", value.casefold())


def already_named(source_name, target):
    source_name = name_key(source_name)
    target = name_key(target)
    if source_name == target:
        return True
    suffix = extension(target)
    stem = target[:-len(suffix)] if suffix else target
    match = re.fullmatch(re.escape(stem) + r"_([0-9]{2,})" + re.escape(suffix), source_name)
    return match is not None and int(match.group(1)) >= 2 and match.group(1) == format(int(match.group(1)), "02d")


def allocate(items, directories):
    occupied = {}
    for item in items:
        parent = item["parts"][:-1]
        if parent not in occupied:
            parent_fd = directories.get(parent)
            with os.scandir(parent_fd) as entries:
                occupied[parent] = {name_key(entry.name) for entry in entries}
        target = item["requested_target"]
        if target is None:
            item["status"] = "pending"
            item["target"] = None
            continue
        if already_named(item["parts"][-1], target):
            item["status"] = "unchanged"
            item["target"] = item["source"]
            continue
        suffix = extension(target)
        stem = target[:-len(suffix)] if suffix else target
        candidate = target
        number = 2
        while name_key(candidate) in occupied[parent]:
            candidate = "{}_{:02d}{}".format(stem, number, suffix)
            number += 1
        if len(candidate.encode("utf-8")) > MAX_NAME_BYTES:
            raise PlanError("衝突回避の連番を付けると 240 byte を超えます。target を短くしてください: {!r}".format(item["source"]))
        occupied[parent].add(name_key(candidate))
        item["status"] = "planned"
        item["target"] = relative_name(parent + (candidate,))


def load_plan(path):
    try:
        with open(path, "r", encoding="utf-8") as stream:
            plan = json.load(stream)
    except (OSError, ValueError, UnicodeError) as exc:
        raise PlanError("計画ファイルを読めません: {}".format(exc)) from exc
    if not isinstance(plan, dict) or not isinstance(plan.get("root"), str) or not isinstance(plan.get("files"), list):
        raise PlanError("計画には root と files 配列が必要です。")
    if plan.get("recursive", False) is not False:
        raise PlanError("再帰的な計画は適用できません。直下のみで列挙し直してください。")
    root = directory_root(plan["root"])
    items = []
    seen = set()
    for row, entry in enumerate(plan["files"], 1):
        if not isinstance(entry, dict) or any(key not in entry for key in ("source", "fingerprint", "target", "reason")):
            raise PlanError("files の {} 行目には source/fingerprint/target/reason が必要です。".format(row))
        parts = source_parts(entry["source"])
        source = relative_name(parts)
        if source in seen:
            raise PlanError("source が重複しています: {!r}".format(source))
        seen.add(source)
        expected = validate_fingerprint(entry["fingerprint"], source)
        validate_target(entry["target"], source)
        if not isinstance(entry["reason"], str):
            raise PlanError("reason は文字列にしてください: {!r}".format(source))
        items.append({"source": source, "parts": parts, "fingerprint": expected, "requested_target": entry["target"], "reason": entry["reason"]})
    return root, items


def apply_one(item, parent_fd):
    """上書きしない hard link を作り、両側を確認してから元の名前を削除する。"""
    verify_source(item, parent_fd)
    source_name = item["parts"][-1]
    target_name = item["target"].split("/")[-1]
    os.link(source_name, target_name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd, follow_symlinks=False)
    # link 後の失敗では作成先を残す。元の内容を失う rollback はしない。
    try:
        linked = os.stat(target_name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(linked.st_mode) or fingerprint(linked) != item["fingerprint"]:
            raise PlanError("作成先の同一性を確認できません。作成先を残しました。")
        verify_source(item, parent_fd)
        os.unlink(source_name, dir_fd=parent_fd)
    except (OSError, PlanError) as exc:
        raise PlanError("改名を完了できません。作成先を残しました: {}".format(exc)) from exc


def apply_plan(path, execute):
    mode = "apply" if execute else "dry-run"
    counts = {"planned": 0, "renamed": 0, "unchanged": 0, "pending": 0, "error": 0}
    root = None
    directories = None
    try:
        root, items = load_plan(path)
        directories = Directories(root)
        # 全行・全 source・全割当を検証し終えるまで変更しない。
        for item in items:
            verify_source(item, directories.get(item["parts"][:-1]))
        allocate(items, directories)
    except (OSError, PlanError, RecursionError) as exc:
        if directories is not None:
            directories.close()
        counts["error"] = 1
        emit({"type": "error", "status": "error", "reason": "事前検証に失敗しました。変更はありません: {}".format(exc)})
        emit({"type": "summary", "root": str(root) if root else None, "mode": mode, "counts": counts})
        return 1
    try:
        for item in items:
            result = {"type": "file", "source": item["source"], "target": item["target"], "status": item["status"], "reason": item["reason"]}
            if execute and item["status"] == "planned":
                try:
                    apply_one(item, directories.get(item["parts"][:-1]))
                    result["status"] = "renamed"
                except (OSError, PlanError, NotImplementedError) as exc:
                    result["status"] = "error"
                    result["reason"] = "適用に失敗しました: {}".format(exc)
            counts[result["status"]] += 1
            emit(result)
    finally:
        directories.close()
    emit({"type": "summary", "root": str(root), "mode": mode, "counts": counts})
    return 1 if counts["error"] else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("inventory", help="直下の通常ファイルを列挙する。隠しファイルと全サブフォルダは対象外。")
    listing.add_argument("directory", metavar="ABS_DIR", help="対象フォルダの絶対パス。")
    applying = commands.add_parser("apply", help="計画を検証し、既定では改名予定のみ表示する。")
    applying.add_argument("plan", metavar="PLAN", help="inventory を基に編集した JSON 計画。")
    applying.add_argument("--apply", action="store_true", help="実際に改名する。")
    args = parser.parse_args()
    if args.command == "apply":
        return apply_plan(args.plan, args.apply)
    try:
        emit(inventory(directory_root(args.directory)))
    except (OSError, PlanError, RecursionError) as exc:
        print("エラー: {}".format(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
