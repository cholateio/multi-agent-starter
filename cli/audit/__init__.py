"""kit audit [name…] [--verbose] [--json PATH] [--html [PATH]] [--baseline PATH]
          [--fetch-remote] [--offline DIR]                      (design §8)

Read-only against GitHub (`gh api` GETs only). Fleet exclusions come from the LOCAL
~/.config/kit/config.toml [audit].exclude — never from a tracked file.
Exit: any CRITICAL/HIGH (after --baseline filtering) → 2; execution error → 1; else 0.
"""
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

from cli import kittoml, paths, privacy
from cli.audit import checks_github, checks_local, report, scan


def _load_privacy():
    """(privacy | None, problem | None). An invalid file is still loaded leniently (bad
    entries dropped) so redaction keeps working; the problem surfaces as UNKNOWN A2."""
    p = paths.privacy_path()
    if not p.is_file():
        print(f"note: {p} missing — personal-literal checks (A2/A3) skipped", file=sys.stderr)
        return None, None
    errs = privacy.validate_privacy(p)
    try:
        prv = privacy.load_privacy(p)
    except (OSError, tomllib.TOMLDecodeError):
        return None, "privacy.local.toml unparseable — A2/A3 skipped, redaction off"
    if errs:
        return prv, f"privacy.local.toml has {len(errs)} error(s) (run kit doctor) — invalid entries ignored"
    return prv, None


def _kittoml(path: Path | None):
    if path is None or not (path / "kit.toml").is_file():
        return None
    try:
        return kittoml.parse_kit_toml(path / "kit.toml")
    except (OSError, tomllib.TOMLDecodeError):
        return None


def _status(path: Path | None):
    if path is None or not (path / "PROJECT.toml").is_file():
        return None
    try:
        with (path / "PROJECT.toml").open("rb") as f:
            return tomllib.load(f).get("status")
    except (OSError, tomllib.TOMLDecodeError):
        return None


def _fetch(t: scan.Target) -> Path | None:
    dest = paths.cache_dir() / "audit-clones" / t.name
    if (dest / ".git").exists():
        r = subprocess.run(["git", "-C", str(dest), "pull", "-q", "--ff-only"], capture_output=True)
    else:
        dest.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(["gh", "repo", "clone", t.remote, str(dest), "--", "-q"], capture_output=True)
    return dest if r.returncode == 0 and (dest / ".git").exists() else None


def run(args) -> int:
    from cli.main import KitError
    try:
        cfg = paths.load_config()
    except tomllib.TOMLDecodeError as e:
        raise KitError(f"{paths.config_path()} is malformed: {e}")
    gh = checks_github.GhClient(Path(args.offline) if args.offline else None)
    owner = cfg.get("github_owner") or (gh.login() if gh.available() else None)
    targets = scan.scan_targets(cfg, args.names or None, gh if gh.available() else None, owner)
    if not targets:
        raise KitError("no audit targets (check [audit].root / exclude in config.toml, or the names given)")
    prv, prv_problem = _load_privacy()
    tools = {"gitleaks": shutil.which("gitleaks"), "osv-scanner": shutil.which("osv-scanner")}
    findings, repos = [], []
    for t in targets:
        if t.path is None and args.fetch_remote and not args.offline and t.remote:
            t.path = _fetch(t)
        kt = _kittoml(t.path)
        gh_repo = gh.get(f"repos/{t.remote}") if t.remote else None
        vis = (str((gh_repo or {}).get("visibility", "")).lower() or t.gh_visibility
               or (kt.visibility if kt else None) or "public")
        vis = "public" if vis == "public" else "private"
        ctx = scan.AuditCtx(privacy=prv, kittoml=kt, visibility=vis, tools=tools, offline=bool(args.offline),
                            gh_repo=gh_repo, project_status=_status(t.path))
        fs = checks_github.run_github_checks(t, ctx, gh)
        if t.path is not None:
            fs += checks_local.run_local_checks(t, ctx)
        else:
            fs.append(report.Finding(t.name, "A0", "INFO", None, None, "not cloned locally — local/history checks "
                                     "skipped", "kit audit --fetch-remote"))
        if prv_problem and t.path is not None:
            fs.append(report.Finding(t.name, "A2", "UNKNOWN", None, None, prv_problem, "kit doctor"))
        for f in fs:
            f.snippet = report.redact(f.snippet, prv)
            f.fix = report.redact(f.fix, prv)
            if f.path:
                f.path = report.redact(f.path, prv)
        findings += fs
        repos.append((t.name, vis))
    shown = findings
    if args.baseline:
        shown = report.apply_baseline(findings, args.baseline)
    print(report.table(repos, shown, verbose=args.verbose))
    if args.baseline:
        n = len(shown)
        print(f"{n} new finding{'s' if n != 1 else ''} (vs baseline {args.baseline})")
    if args.json:
        Path(args.json).write_text(report.to_json(repos, findings, paths.version()), encoding="utf-8")
        print(f"json: {args.json}")
    if args.html is not None:
        out = Path(args.html) if args.html else paths.data_dir() / "audit.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(report.to_html(repos, shown, paths.version()), encoding="utf-8")
        print(f"html: {out}")
        report.open_in_browser(out)
    return report.exit_code(shown)
