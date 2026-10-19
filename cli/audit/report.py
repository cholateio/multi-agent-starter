"""Audit findings and their redaction (output side lives here too — Task 3.8c)."""
import re
from dataclasses import dataclass

SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "INFO", "UNKNOWN")
RANK = {s: i for i, s in enumerate(SEVERITIES)}

TOKEN_RE = re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}"
                      r"|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_.-]+)")


@dataclass
class Finding:
    repo: str
    check: str
    severity: str
    path: str | None = None
    line: int | None = None
    snippet: str = ""
    fix: str = ""


def redact(text: str, privacy=None) -> str:
    """Literal values → <name>, configured usernames in paths → <user>, token-shaped
    strings → ***. Applied to every snippet derived from file content."""
    out = text or ""
    if privacy is not None:
        for lit in sorted(privacy.literals, key=lambda l: -len(l.value)):
            out = re.sub(re.escape(lit.value), f"<{lit.name}>", out, flags=re.IGNORECASE)
        for i, e in enumerate(privacy.emails):
            out = re.sub(re.escape(e), "<email>", out, flags=re.IGNORECASE)
        for u in privacy.usernames:
            out = re.sub(rf"(/home/|/mnt/[a-z]/Users/|[A-Za-z]:\\\\Users\\\\){re.escape(u)}(?=[/\\\\]|$)",
                         r"\1<user>", out, flags=re.IGNORECASE)
    # every home-path user segment, configured or not (review O4): /home/<x>, /Users/<x>,
    # /mnt/<d>/Users/<x>, C:\Users\<x> — the report is meant to be shareable
    out = HOME_SEG_RE.sub(lambda m: m.group(1) + "<user>", out)
    out = TOKEN_RE.sub("***", out)
    return out


HOME_SEG_RE = re.compile(r"(/home/|(?:/mnt/[a-z])?/Users/|[A-Za-z]:\\+Users\\+)(?!<user>)[^/\\\s:\"'<>]+",
                         re.IGNORECASE)


def max_severity(findings) -> str | None:
    ranked = [f.severity for f in findings if f.severity in ("CRITICAL", "HIGH", "MEDIUM", "LOW")]
    return min(ranked, key=lambda s: RANK[s]) if ranked else None


# ------------------------------------------------------------------ output (Task 3.8c)
import datetime as _dt
import html as _html
import json as _json
import os as _os
import shutil as _shutil
import subprocess as _subprocess
from dataclasses import asdict as _asdict
from pathlib import Path as _Path

COUNTED = ("CRITICAL", "HIGH", "MEDIUM", "LOW")


def key(f) -> tuple:
    return (f.repo, f.check, f.path, f.snippet)


def apply_baseline(findings, baseline_path) -> list:
    data = _json.loads(_Path(baseline_path).read_text())
    known = {(d.get("repo"), d.get("check"), d.get("path"), d.get("snippet")) for d in data.get("findings", [])}
    return [f for f in findings if key(f) not in known]


def exit_code(findings) -> int:
    return 2 if any(f.severity in ("CRITICAL", "HIGH") for f in findings) else 0


def _sorted(findings):
    return sorted(findings, key=lambda f: (RANK.get(f.severity, 9), f.check, f.path or "", f.line or 0))


def table(repos: list[tuple[str, str]], findings, verbose=False) -> str:
    rows = [("repo", "visibility", "max", "C/H/M/L", "top finding")]
    by_repo: dict[str, list] = {}
    for f in findings:
        by_repo.setdefault(f.repo, []).append(f)
    for name, vis in repos:
        fs = by_repo.get(name, [])
        counted = [f for f in fs if f.severity in COUNTED]
        mx = max_severity(fs) or "ok"
        cnt = "/".join(str(sum(1 for f in counted if f.severity == s)) for s in COUNTED)
        top = _sorted(counted)[0] if counted else None
        rows.append((name, vis, mx, cnt, f"{top.check} {top.snippet}"[:70] if top else "-"))
    w = [max(len(r[i]) for r in rows) for i in range(4)]
    lines = []
    for i, r in enumerate(rows):
        lines.append("  ".join(r[j].ljust(w[j]) for j in range(4)) + "  " + r[4])
        if i == 0:
            lines.append("  ".join("-" * w[j] for j in range(4)) + "  " + "-" * 11)
        if verbose and i > 0:
            for f in _sorted(by_repo.get(r[0], [])):
                loc = f"{f.path}:{f.line}" if f.path and f.line else (f.path or "-")
                lines.append(f"    {f.severity:<8} {f.check:<4} {loc}  {f.snippet}")
                if f.fix:
                    lines.append(f"             fix: {f.fix}")
    tot = {s: sum(1 for f in findings if f.severity == s) for s in SEVERITIES}
    lines.append("")
    lines.append(f"{len(repos)} repos — {tot['CRITICAL']} CRITICAL, {tot['HIGH']} HIGH, {tot['MEDIUM']} MEDIUM, "
                 f"{tot['LOW']} LOW, {tot['INFO']} INFO; {tot['UNKNOWN']} UNKNOWN (gh / tool unavailable; not counted)")
    return "\n".join(lines)


def to_json(repos, findings, version) -> str:
    return _json.dumps({"generated": _dt.datetime.now().astimezone().isoformat(timespec="seconds"),
                        "kit": version, "repos": [{"name": n, "visibility": v} for n, v in repos],
                        "findings": [_asdict(f) for f in findings]}, ensure_ascii=False, indent=2)


HTML_CSS = """
:root{--bg:#fbfbfa;--fg:#1d1d1f;--mut:#6b6b70;--line:#e3e3e0;--crit:#b3261e;--high:#c4510c;--med:#8a6d00;--low:#3d6b9e;--info:#5f6b6b}
@media (prefers-color-scheme:dark){:root{--bg:#161618;--fg:#e9e9ea;--mut:#9a9aa0;--line:#2c2c30;--crit:#ff8a80;--high:#ffab70;--med:#e6c65c;--low:#8cb4e6;--info:#a3b0b0}}
body{background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;padding:24px 16px}
main{max-width:1100px;margin:0 auto}h1{font-size:20px;margin:0 0 4px}p.meta{color:var(--mut);margin:0 0 16px}
table{border-collapse:collapse;width:100%;margin:0 0 24px}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-weight:600;color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
td.sev{font-weight:600;white-space:nowrap}.CRITICAL{color:var(--crit)}.HIGH{color:var(--high)}.MEDIUM{color:var(--med)}.LOW{color:var(--low)}.INFO,.UNKNOWN{color:var(--info)}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}.fix{color:var(--mut);font-size:12px}
.wrap{overflow-x:auto}label{margin-right:12px;color:var(--mut)}
"""


def to_html(repos, findings, version) -> str:
    e = _html.escape
    by_repo: dict[str, list] = {}
    for f in findings:
        by_repo.setdefault(f.repo, []).append(f)
    summary = "".join(
        f"<tr><td>{e(n)}</td><td>{e(v)}</td><td class='sev {e(max_severity(by_repo.get(n, [])) or 'ok')}'>"
        f"{e(max_severity(by_repo.get(n, [])) or 'ok')}</td><td>"
        + "/".join(str(sum(1 for f in by_repo.get(n, []) if f.severity == s)) for s in COUNTED) + "</td></tr>"
        for n, v in repos)
    rows = "".join(
        f"<tr data-check=\"{e(f.check)}\" data-sev=\"{e(f.severity)}\"><td class='sev {e(f.severity)}'>{e(f.severity)}</td>"
        f"<td>{e(f.repo)}</td><td>{e(f.check)}</td><td><code>{e((f.path or '-') + (f':{f.line}' if f.line else ''))}</code></td>"
        f"<td>{e(f.snippet)}<div class='fix'>{e(f.fix)}</div></td></tr>"
        for f in _sorted(findings))
    boxes = "".join(f"<label><input type='checkbox' data-f='{s}' checked> {s}</label>" for s in SEVERITIES)
    js = ("document.querySelectorAll('input[data-f]').forEach(b=>b.addEventListener('change',()=>{"
          "const on=new Set([...document.querySelectorAll('input[data-f]:checked')].map(x=>x.dataset.f));"
          "document.querySelectorAll('tr[data-sev]').forEach(r=>{r.style.display=on.has(r.dataset.sev)?'':'none'})}))")
    gen = _dt.datetime.now().strftime("%Y-%m-%d %H:%M")
    return ("<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' "
            "content='width=device-width,initial-scale=1'><title>Kit Fleet Audit</title>"
            f"<style>{HTML_CSS}</style></head><body><main><h1>Kit fleet audit</h1>"
            f"<p class='meta'>kit {e(version)} · generated {e(gen)} · {len(repos)} repos · {len(findings)} findings</p>"
            "<div class='wrap'><table><thead><tr><th>repo</th><th>visibility</th><th>max</th><th>C/H/M/L</th></tr></thead>"
            f"<tbody>{summary}</tbody></table></div><p>{boxes}</p>"
            "<div class='wrap'><table><thead><tr><th>severity</th><th>repo</th><th>check</th><th>where</th><th>finding</th></tr></thead>"
            f"<tbody>{rows}</tbody></table></div></main><script>{js}</script></body></html>\n")


def open_in_browser(path) -> None:
    """Copied from bin/proj _open_in_browser (D16: no import across tools)."""
    if _os.environ.get("KIT_NO_OPEN"):
        return
    exe = _shutil.which("explorer.exe")
    if exe is None:
        return
    try:
        r = _subprocess.run(["wslpath", "-w", str(path)], capture_output=True, text=True, timeout=5)
        win = r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, _subprocess.TimeoutExpired):
        win = ""
    if not win:
        return
    try:
        _subprocess.run([exe, win], timeout=10)
    except (OSError, _subprocess.TimeoutExpired):
        pass
