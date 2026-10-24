"""監査JSONを厳格に読み、検出数と照合可能な対象だけを返す。標準ライブラリのみ。"""

import datetime
import json
import math
import os
from pathlib import Path
import re
import stat


MAX_REPORT_BYTES = 8 * 1024 * 1024
SEVERITIES = ("info", "low", "moderate", "high", "critical")


class AuditError(ValueError):
    """監査の形式・完全性を確認できない場合。入力内容をエラーに転載しない。"""


def _require(condition, message):
    if not condition:
        raise AuditError(message)


def _object(value, required, optional=()):
    _require(type(value) is dict, "監査JSONのオブジェクト型が不正です。")
    _require(set(required) <= set(value), "監査JSONの必須項目がありません。")
    _require(set(value) <= set(required) | set(optional), "監査JSONに未対応の項目があります。")
    return value


def _array(value):
    _require(type(value) is list, "監査JSONの配列型が不正です。")
    return value


def _text(value, empty=False):
    _require(type(value) is str and (empty or bool(value)), "監査JSONの文字列型が不正です。")
    return value


def _integer(value):
    _require(type(value) is int and value >= 0, "監査JSONの非負整数が不正です。")
    return value


def _boolean(value):
    _require(type(value) is bool, "監査JSONの真偽値が不正です。")


def _strings(value):
    for item in _array(value):
        _text(item)


def _identity(name, version, ecosystem):
    patterns = {
        "pip": r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?",
        "gem": r"[A-Za-z0-9][A-Za-z0-9._-]*",
    }
    _require(type(name) is str and len(name) <= 256 and re.fullmatch(patterns[ecosystem], name),
             "監査対象のパッケージ名が不正です。")
    _require(type(version) is str and len(version) <= 256
             and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+!-]*", version),
             "監査対象の固定バージョンが不正です。")
    return {"name": name, "version": version}


def _no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, "監査JSONに重複キーがあります。")
        result[key] = value
    return result


def _nonfinite(_value):
    raise AuditError("監査JSONに非有限数があります。")


def _fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def _read_report(path):
    # 各要素をdir_fdから開き、途中のsymlink置換も追跡しない。
    _require(hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY"),
             "この環境では監査ファイルを安全に開けません。")
    parent = None
    descriptor = None
    try:
        parts = Path(os.path.abspath(os.fspath(path))).parts
        parent = os.open(parts[0], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        for part in parts[1:-1]:
            next_parent = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                  dir_fd=parent)
            os.close(parent)
            parent = next_parent
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=parent)
        before = os.fstat(descriptor)
        _require(stat.S_ISREG(before.st_mode), "監査レポートは通常ファイルに限ります。")
        _require(0 < before.st_size <= MAX_REPORT_BYTES, "監査レポートが空か8MiBを超えています。")
        chunks = []
        remaining = MAX_REPORT_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
        current = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        _require(_fingerprint(before) == _fingerprint(after) == _fingerprint(current),
                 "読取り中に監査レポートが変更されました。")
        raw = b"".join(chunks)
        _require(len(raw) == before.st_size and len(raw) <= MAX_REPORT_BYTES,
                 "監査レポートの読取りが不完全です。")
        return raw
    except (OSError, TypeError, ValueError) as error:
        if isinstance(error, AuditError):
            raise
        raise AuditError("監査レポートを安全に読み取れません。") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if parent is not None:
            os.close(parent)


def _npm_advisory(value):
    _object(value, ("source", "name", "dependency", "title", "url", "severity", "range"),
            ("cwe", "cvss"))
    _integer(value["source"])
    for key in ("name", "dependency", "title", "url", "range"):
        _text(value[key])
    _require(value["severity"] in SEVERITIES, "npm監査の重大度が未対応です。")
    if "cwe" in value:
        _strings(value["cwe"])
    if "cvss" in value:
        cvss = _object(value["cvss"], ("score", "vectorString"))
        score = cvss["score"]
        _require(type(score) in (int, float) and math.isfinite(score) and 0 <= score <= 10,
                 "npm監査のCVSSが不正です。")
        if cvss["vectorString"] is not None:
            _text(cvss["vectorString"])


def _npm(report):
    _object(report, ("auditReportVersion", "vulnerabilities", "metadata"))
    _require(type(report["auditReportVersion"]) is int and report["auditReportVersion"] == 2,
             "npm監査の形式バージョンが未対応です。")
    vulnerabilities = report["vulnerabilities"]
    _require(type(vulnerabilities) is dict, "npm監査のvulnerabilitiesが不正です。")
    counts = dict.fromkeys(SEVERITIES, 0)
    for name, vuln in vulnerabilities.items():
        _text(name)
        _object(vuln, ("name", "severity", "isDirect", "via", "effects", "range", "nodes", "fixAvailable"),
                ("fixBlockedByReleaseAge",))
        _require(vuln["name"] == name, "npm監査のパッケージ名が一致しません。")
        severity = vuln["severity"]
        _require(type(severity) is str and severity in SEVERITIES, "npm監査の重大度が未対応です。")
        counts[severity] += 1
        _boolean(vuln["isDirect"])
        _text(vuln["range"])
        _strings(vuln["effects"])
        _strings(vuln["nodes"])
        _require(bool(vuln["nodes"]), "npm監査の影響対象が空です。")
        via = _array(vuln["via"])
        _require(bool(via), "npm監査の根拠が空です。")
        for item in via:
            if type(item) is str:
                _require(item in vulnerabilities, "npm監査の依存する脆弱性がありません。")
            else:
                _npm_advisory(item)
        fix = vuln["fixAvailable"]
        if type(fix) is not bool:
            _object(fix, ("name", "version"), ("isSemVerMajor",))
            _text(fix["name"])
            _text(fix["version"])
            if "isSemVerMajor" in fix:
                _boolean(fix["isSemVerMajor"])
        if "fixBlockedByReleaseAge" in vuln:
            blocked = _object(vuln["fixBlockedByReleaseAge"], ("version", "before"))
            _text(blocked["version"])
            _text(blocked["before"])
    metadata = _object(report["metadata"], ("vulnerabilities", "dependencies"))
    totals = _object(metadata["vulnerabilities"], SEVERITIES + ("total",))
    for severity in SEVERITIES:
        _require(_integer(totals[severity]) == counts[severity], "npm監査の重大度別件数が一致しません。")
    _require(_integer(totals["total"]) == len(vulnerabilities), "npm監査の合計件数が一致しません。")
    dependencies = _object(metadata["dependencies"],
                           ("prod", "dev", "optional", "peer", "peerOptional", "total"))
    for value in dependencies.values():
        _integer(value)
    # npmのmetadataはrootや複数属性を重複計上するため属性別件数は加算しない。
    _require(dependencies["total"] > 0, "npm監査の依存対象が空です。")
    return [], len(vulnerabilities)


def _pip(report):
    _object(report, ("dependencies", "fixes"))
    dependencies = _array(report["dependencies"])
    _require(bool(dependencies), "pip-auditの監査対象が空です。")
    # --fixによる変更済み結果は更新前の判定に使えない。
    _require(_array(report["fixes"]) == [], "pip-auditの修正実行結果は監査証跡に使えません。")
    packages = []
    seen = set()
    findings = 0
    for dependency in dependencies:
        _object(dependency, ("name", "version", "vulns"))
        identity = _identity(dependency["name"], dependency["version"], "pip")
        normalized = re.sub(r"[-_.]+", "-", identity["name"]).lower()
        _require(normalized not in seen, "pip-auditの監査対象が重複しています。")
        seen.add(normalized)
        packages.append(identity)
        identifiers = set()
        for vuln in _array(dependency["vulns"]):
            _object(vuln, ("id", "fix_versions"), ("aliases", "description"))
            identifier = _text(vuln["id"])
            _require(identifier not in identifiers, "pip-auditの脆弱性が重複しています。")
            identifiers.add(identifier)
            _strings(vuln["fix_versions"])
            if "aliases" in vuln:
                _strings(vuln["aliases"])
            if "description" in vuln:
                _text(vuln["description"], empty=True)
            findings += 1
    return packages, findings


def _bundler_advisory(advisory):
    _object(advisory,
            ("path", "id", "url", "title", "date", "description", "cvss_v2", "cvss_v3",
             "cve", "osvdb", "ghsa", "unaffected_versions", "patched_versions", "criticality"),
            ("cvss_v4",))
    for key in ("path", "id", "url", "title", "date", "description"):
        _text(advisory[key])
    for key in ("cve", "ghsa"):
        if advisory[key] is not None:
            _text(advisory[key])
    if advisory["osvdb"] is not None:
        _integer(advisory["osvdb"])
    for key in ("cvss_v2", "cvss_v3", "cvss_v4"):
        value = advisory.get(key)
        if value is not None:
            _require(type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 10,
                     "bundler-auditのCVSSが不正です。")
    _strings(advisory["unaffected_versions"])
    _strings(advisory["patched_versions"])
    _require(advisory["criticality"] in (None, "none", "low", "medium", "high", "critical"),
             "bundler-auditの重大度が未対応です。")


def _bundler(report):
    _object(report, ("version", "created_at", "results"))
    _require(type(report["version"]) is str and re.fullmatch(r"0\.(?:8|9)\.\d+", report["version"]),
             "bundler-auditのバージョンが未対応です。")
    timestamp = _text(report["created_at"])
    try:
        # Ruby Time#to_s。鮮度自体は実行記録と併せて呼出元で検証する。
        datetime.datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S %z")
    except ValueError:
        raise AuditError("bundler-auditのcreated_atが不正です。") from None
    results = _array(report["results"])
    packages = {}
    for result in results:
        _require(type(result) is dict, "bundler-auditの結果型が不正です。")
        if result.get("type") == "insecure_source":
            _object(result, ("type", "source"))
            _text(result["source"])
        elif result.get("type") == "unpatched_gem":
            _object(result, ("type", "gem", "advisory"))
            gem = _object(result["gem"], ("name", "version"))
            identity = _identity(gem["name"], gem["version"], "gem")
            packages[(identity["name"], identity["version"])] = identity
            _bundler_advisory(result["advisory"])
        else:
            raise AuditError("bundler-auditに未対応の結果・エラーがあります。")
    # resultsには正常なgemの全一覧がない。空配列は全対象監査の証明ではない。
    return list(packages.values()), len(results)


def inspect_audit(path: Path, format_name: str) -> dict:
    """対応済み監査JSONだけを検証する。0件でも安全性・対象網羅性は保証しない。"""
    readers = {"npm-v2": _npm, "pip-audit": _pip, "bundler-audit": _bundler}
    _require(type(format_name) is str and format_name in readers, "監査レポートの形式が未対応です。")
    raw = _read_report(path)
    try:
        report = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_duplicates,
                            parse_constant=_nonfinite)
        packages, findings = readers[format_name](report)
    except AuditError:
        raise
    except (ValueError, RecursionError, OverflowError, TypeError):
        raise AuditError("監査JSONが破損しているか形式が不正です。") from None
    return {"format": format_name, "packages": packages, "findings": findings}
