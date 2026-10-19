"""kit guard status | bypass "<reason>" (design §7.4).

bypass is USER-only: it refuses to run without a terminal on stdin, so an agent's
non-interactive shell cannot arm one (the tool-breaker hook also denies the
command text for the model). The bypass file lives in the state dir:
    <state_dir>/guard/bypass-<repo-id>  {"expires": <epoch>, "reason": "...", "repo": "..."}
repo-id = sha1(`git rev-parse --show-toplevel`)[:12] — plugin/guard/lib-guard.sh
computes the same id. The next guard run that would BLOCK in that repo consumes
it (single use) and logs it to audit.jsonl; a clean run leaves it alone.
"""
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

from cli import paths, privacy

BYPASS_SECONDS = 600


def _git(*args, cwd=None) -> str | None:
    try:
        r = subprocess.run(["git", *args], capture_output=True, text=True, cwd=cwd)
    except OSError:
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def repo_key() -> str | None:
    """The string the bash guard hashes: toplevel, else the absolute git dir (bare)."""
    return _git("rev-parse", "--show-toplevel") or _git("rev-parse", "--absolute-git-dir")


def repo_id(key: str) -> str:
    return hashlib.sha1(key.encode()).hexdigest()[:12]


def guard_dir() -> Path:
    return paths.state_dir() / "guard"


def bypass_path(key: str) -> Path:
    return guard_dir() / f"bypass-{repo_id(key)}"


def _audit(entry: dict) -> None:
    d = guard_dir()
    d.mkdir(parents=True, exist_ok=True)
    with (d / "audit.jsonl").open("a", encoding="utf-8") as f:
        # compact separators: the bash guard matches these fields textually
        f.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n")


def bypass(reason: str | None) -> int:
    reason = (reason or "").strip()
    if not reason:
        print('usage: kit guard bypass "<reason>"   (the reason is required and logged)', file=sys.stderr)
        return 2
    if not sys.stdin.isatty():
        print("kit guard bypass is USER-only: run it yourself in a terminal. No TTY here — "
              "an agent or script cannot arm a guard bypass.", file=sys.stderr)
        return 1
    key = repo_key()
    if not key:
        print("kit guard bypass: not inside a git repository", file=sys.stderr)
        return 1
    d = guard_dir()
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    p = bypass_path(key)
    expires = int(time.time()) + BYPASS_SECONDS
    p.write_text(json.dumps({"expires": expires, "reason": reason, "repo": key}) + "\n", encoding="utf-8")
    os.chmod(p, 0o600)
    _audit({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "repo": key, "hook": "kit guard",
            "rule": "", "path": "", "action": "bypass-armed", "reason": reason, "expires": expires})
    print(f"kit guard: bypass armed for {key} — the next BLOCKED commit or push there goes through once "
          f"(expires in {BYPASS_SECONDS // 60} min; commit and push each need their own). Logged to {d / 'audit.jsonl'}")
    return 0


def _bypass_state(key: str) -> str:
    p = bypass_path(key)
    if not p.is_file():
        return "none"
    try:
        exp = int(json.loads(p.read_text()).get("expires", 0))
    except (OSError, ValueError, TypeError):
        return "unreadable (will be ignored)"
    left = exp - int(time.time())
    return f"active — {left}s left" if left > 0 else "expired (removed on next guard run)"


def status() -> int:
    cfg_dir = paths.config_dir()
    hooks_dir = cfg_dir / "git-hooks"
    want = str(hooks_dir)
    glob = _git("config", "--global", "--get", "core.hooksPath") or ""
    ok = glob and Path(os.path.expanduser(glob)) == hooks_dir
    print(f"hooksPath: {glob or 'unset'}" + ("" if ok else f"   (NOT the kit shims {want} — run: kit setup)"))
    from cli.setup_cmd import HOOKS
    missing = [h for h in HOOKS if not os.access(hooks_dir / h, os.X_OK)]
    print("shims: " + (f"missing {', '.join(missing)}" if missing else f"{len(HOOKS)} in {want}"))
    gl = paths.find_tool("gitleaks")   # the guard's resolver: tools_dir, then a recorded gitleaks_path (never PATH)
    print(f"gitleaks: {gl or 'MISSING — commits warn, pushes are blocked (kit doctor --install)'}")
    pp = paths.privacy_path()
    if pp.is_file():
        mode = stat.S_IMODE(pp.stat().st_mode)
        try:
            prv = privacy.load_privacy(pp)
            counts = f"{len(prv.usernames)} usernames, {len(prv.emails)} emails, {len(prv.literals)} literals"
        except Exception as e:  # noqa: BLE001 — reported
            counts = f"unparseable ({type(e).__name__}) — run: kit doctor"
        print(f"privacy: {pp} ({counts}; mode {mode:o})")
    else:
        print(f"privacy: {pp} MISSING — personal literals (R4/R5) not checked (kit setup)")
    key = repo_key()
    if not key:
        print("repo: (not in a git repository)")
        return 0
    print(f"repo: {key}")
    top = _git("rev-parse", "--show-toplevel")
    kt = Path(top) / "kit.toml" if top else None
    if kt and kt.is_file():
        from cli import kittoml
        try:
            k = kittoml.parse_kit_toml(kt)
            vis = k.visibility if k.visibility in ("public", "private") else f"{k.visibility!r} → treated as public"
            print(f"kit.toml: visibility: {vis}; allow_literals: {', '.join(k.allow_literals) or '-'}; "
                  f"allow_paths: {', '.join(k.allow_paths) or '-'}")
        except Exception as e:  # noqa: BLE001
            print(f"kit.toml: unparseable ({type(e).__name__}) — guard treats the repo as public")
    else:
        print("kit.toml: none — generic layer only (R1, R2 .env*, R3–R8; public-only literals treated as public)")
    local = _git("config", "--local", "--get", "core.hooksPath")
    if local:
        print(f"local hooksPath: {local} — OVERRIDDEN: the global kit guard does NOT run in this repo "
              f"(git config --local --unset core.hooksPath; chain your hooks from .git/hooks instead)")
    print(f"bypass: {_bypass_state(key)}")
    if top:   # refresh the local-only file snapshot (plugin/guard/localfiles.sh; review F3)
        try:
            r = subprocess.run(["bash", str(paths.plugin_dir() / "guard" / "localfiles.sh"), "snapshot", "--report"],
                               cwd=top, capture_output=True, text=True, timeout=60)
            note = r.stderr.strip()
        except (OSError, subprocess.TimeoutExpired):
            note = "snapshot failed"
        store = paths.state_dir() / "localfiles" / repo_id(top) / "files"
        if store.is_dir():
            print(f"local-only files: snapshot in {store}" + (f" — {note}" if note else ""))
    return 0


def run(args) -> int:
    if args.action == "bypass":
        return bypass(args.reason)
    return status()
