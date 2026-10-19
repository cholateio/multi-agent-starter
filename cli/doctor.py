"""kit doctor [--install]: is this machine's kit install complete and sane?

Every check prints `OK|WARN|FAIL <label> — <detail>`; any FAIL → exit 1.
--install fetches the pinned gitleaks / osv-scanner, verifying sha256 before
anything lands in the bin dir (a mismatch deletes the download and aborts).
"""
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from cli import kittoml, paths, privacy

MIN_CLAUDE = (2, 1, 277)
PLUGIN_ID = "kit@multi-agent-kit"
RULES_BYTES_CAP = 20480
SEGMENT_CHARS_CAP = 9500
SEGMENTS = {"core": ["kit-workflow", "kit-delegation"],
            "judgment": ["kit-judgment", "kit-evolution", "project-manifest"]}


@dataclass(frozen=True)
class ToolPin:
    name: str
    version: str
    url: str
    sha256: str                      # of the downloaded file (archive or raw binary)
    archive: str                     # "tar.gz" | "raw"
    member: str | None               # file inside the archive
    member_sha256: str | None = None  # of the extracted binary (cross-check)

    @property
    def binary_sha256(self) -> str:
        """sha256 of the installed binary — what config.toml <name>_sha256 records (review R4-1)."""
        return self.member_sha256 if self.archive == "tar.gz" else self.sha256


TOOL_PINS: dict[str, ToolPin] = {
    # sha256 from gitleaks_8.30.1_checksums.txt, fetched 2026-10-19; member_sha256 = the
    # extracted binary, cross-checked against an independently obtained copy
    "gitleaks": ToolPin(
        "gitleaks", "8.30.1",
        "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz",
        "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb", "tar.gz", "gitleaks",
        "88f91962aa2f93ac6ab281d553b9e125f5197bbbce38f9f2437f7299c32e5509"),
    # sha256 from osv-scanner_SHA256SUMS, fetched 2026-10-19
    "osv-scanner": ToolPin(
        "osv-scanner", "2.7.0",
        "https://github.com/google/osv-scanner/releases/download/v2.7.0/osv-scanner_linux_amd64",
        "160c6253e2922e9e0a6a9771c5c4c40a4b3c6090b34a3cdd5e80c96cc2e4218b", "raw", None),
}
VERSION_CMDS = {"gitleaks": ["version"], "osv-scanner": ["--version"]}


class PinMismatch(Exception):
    pass


def _sha256(path: Path) -> str:
    return paths.sha256_file(path)


def _download(url: str, dest: Path) -> None:
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url, timeout=120) as r, tmp.open("wb") as f:  # noqa: S310 (pinned URLs)
        shutil.copyfileobj(r, f)
    os.replace(tmp, dest)


def install_tool(pin: ToolPin, dest_dir: Path) -> Path:
    """Download (or reuse the cached download), verify sha256, install dest_dir/<name> mode 755."""
    dl_dir = paths.cache_dir() / "downloads"
    dl_dir.mkdir(parents=True, exist_ok=True)
    dl = dl_dir / pin.url.rstrip("/").rsplit("/", 1)[-1]
    if dl.exists() and _sha256(dl) != pin.sha256:
        dl.unlink()                                   # stale / tampered cache: fetch again
    if not dl.exists():
        _download(pin.url, dl)
    actual = _sha256(dl)
    if actual != pin.sha256:
        dl.unlink(missing_ok=True)
        raise PinMismatch(f"{pin.name} {pin.version}: sha256 mismatch for {pin.url} — "
                          f"expected {pin.sha256[:12]}…, got {actual[:12]}… (download deleted)")
    dest_dir = Path(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest_dir) as td:
        staged = Path(td) / pin.name
        if pin.archive == "tar.gz":
            with tarfile.open(dl, "r:gz") as tf:
                m = tf.getmember(pin.member)
                if not m.isfile():
                    raise PinMismatch(f"{pin.name}: archive member {pin.member} is not a regular file")
                with tf.extractfile(m) as src, staged.open("wb") as out:
                    shutil.copyfileobj(src, out)
        else:
            shutil.copyfile(dl, staged)
        if pin.member_sha256:
            got = _sha256(staged)
            if got != pin.member_sha256:
                raise PinMismatch(f"{pin.name} {pin.version}: extracted binary sha256 mismatch — "
                                  f"expected {pin.member_sha256[:12]}…, got {got[:12]}…")
        staged.chmod(0o755)
        final = dest_dir / pin.name
        os.replace(staged, final)
    return final


def parse_claude_version(text: str):
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", text or "")
    return tuple(int(x) for x in m.groups()) if m else None


def check_min_version(v) -> bool:
    return v is not None and tuple(v) >= MIN_CLAUDE


def platform_ok() -> tuple[bool, str]:
    """The pinned downloads are linux x86-64 binaries (review O1)."""
    plat, mach = sys.platform, platform.machine().lower()
    return plat.startswith("linux") and mach in ("x86_64", "amd64"), f"{plat}/{mach}"


def tool_version(name: str, exe: str | None = None) -> str | None:
    exe = exe or paths.find_tool(name)
    if not exe:
        return None
    try:
        r = subprocess.run([exe, *VERSION_CMDS.get(name, ["--version"])], capture_output=True,
                           text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r"(\d+\.\d+\.\d+)", r.stdout + r.stderr)
    return m.group(1) if m else ""


class Report:
    def __init__(self):
        self.lines: list[tuple[str, str, str]] = []

    def add(self, level: str, label: str, detail: str):
        self.lines.append((level, label, detail))
        print(f"{level} {label} — {detail}")

    @property
    def failed(self) -> bool:
        return any(l[0] == "FAIL" for l in self.lines)


def _git_global(key: str) -> str:
    try:
        r = subprocess.run(["git", "config", "--global", "--get", key], capture_output=True, text=True,
                           timeout=10)
        return r.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def rules_budget(plugin_dir: Path) -> tuple[bool, str]:
    rules = plugin_dir / "rules"
    files = [p for p in rules.glob("*.md") if p.name != "subagent-digest.md"]
    if not files:
        return False, f"no rules found under {rules}"
    total = sum(len(p.read_bytes()) for p in files)
    segs = {}
    for seg, names in SEGMENTS.items():
        segs[seg] = sum(len((rules / f"{n}.md").read_text(encoding="utf-8")) for n in names
                        if (rules / f"{n}.md").is_file())
    ok = total <= RULES_BYTES_CAP and all(v <= SEGMENT_CHARS_CAP for v in segs.values())
    return ok, (f"{total}B / {RULES_BYTES_CAP}B; " +
                ", ".join(f"{k} {v} / {SEGMENT_CHARS_CAP} chars" for k, v in segs.items()))


def run_checks() -> Report:
    rep = Report()
    cfg_dir = paths.config_dir()

    # claude
    exe = shutil.which("claude")
    if not exe:
        rep.add("FAIL", "claude", "not on PATH (need Claude Code >= %d.%d.%d)" % MIN_CLAUDE)
    else:
        try:
            out = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=20).stdout
        except (OSError, subprocess.TimeoutExpired):
            out = ""
        v = parse_claude_version(out)
        if check_min_version(v):
            rep.add("OK", "claude", ".".join(map(str, v)))
        else:
            rep.add("FAIL", "claude", f"version {out.strip() or 'unknown'} < %d.%d.%d" % MIN_CLAUDE)

    # plugin enabled (user settings)
    settings = paths.claude_dir() / "settings.json"
    try:
        enabled = json.loads(settings.read_text()).get("enabledPlugins", {}).get(PLUGIN_ID) is True
    except (OSError, ValueError, AttributeError):
        enabled = False
    rep.add("OK" if enabled else "FAIL", "plugin",
            f"{PLUGIN_ID} enabled in {settings}" if enabled else f"{PLUGIN_ID} not enabled in {settings} — run: kit setup")

    # global hooksPath + shims
    want = str(cfg_dir / "git-hooks")
    got = _git_global("core.hooksPath")
    if got and Path(os.path.expanduser(got)) == Path(want):
        rep.add("OK", "hooksPath", got)
    else:
        rep.add("FAIL", "hooksPath", f"git config --global core.hooksPath is {got or 'unset'}, want {want} — run: kit setup")
    from cli.setup_cmd import GUARD_HOOKS, HOOKS
    missing = [h for h in HOOKS if not os.access(cfg_dir / "git-hooks" / h, os.X_OK)]
    if any(h in GUARD_HOOKS for h in missing):
        rep.add("FAIL", "shims", f"missing/not executable: {', '.join(missing)} in {want} — run: kit setup")
    elif missing:
        rep.add("WARN", "shims", f"chain-only shims missing ({', '.join(missing)}) — repo-local hooks of "
                "those names do not run — run: kit setup")
    else:
        rep.add("OK", "shims", f"pre-commit, pre-push + {len(HOOKS) - 2} chain-only in {want}")
    # the current repo: a repo-local core.hooksPath (husky-style) silently disables the global guard
    try:
        r = subprocess.run(["git", "config", "--local", "--get", "core.hooksPath"], capture_output=True, text=True)
        local_hp = r.stdout.strip() if r.returncode == 0 else ""
    except OSError:
        local_hp = ""
    if local_hp:
        rep.add("FAIL", "repo hooksPath", f"this repo sets core.hooksPath = {local_hp}: the global kit guard does NOT "
                "run here — git config --local --unset core.hooksPath (chain your hooks from .git/hooks)")

    # tools — the guard runs only a binary whose sha256 equals the recorded <name>_sha256 (R4-1)
    for name in ("gitleaks", "osv-scanner"):
        pin = TOOL_PINS[name]
        exe, state = paths.tool_state(name)
        if state == "replaced":
            rep.add("FAIL", name, f"{exe}: sha256 is not the {paths.tool_sha_key(name)} recorded in "
                    f"{paths.config_path()} — the binary was replaced; the guard treats it as missing "
                    "(pushes blocked) — run: kit doctor --install")
            continue
        if state == "unrecorded":
            rep.add("WARN", name, f"{exe} found but no {paths.tool_sha_key(name)} recorded — the guard runs "
                    "only a hash-verified binary — run: kit doctor --install")
            continue
        v = tool_version(name)
        if v is None:
            onpath = shutil.which(name)
            if onpath:
                rep.add("WARN", name, f"{onpath} is on PATH but not recorded — the guard never uses PATH tools "
                        f"(pinned {pin.version}) — run: kit doctor --install")
            else:
                rep.add("WARN", name, f"not in {paths.tools_dir()} and no {paths.tool_key(name)} recorded "
                        f"(pinned {pin.version}) — run: kit doctor --install")
        elif paths.load_config().get(paths.tool_sha_key(name)) != pin.binary_sha256:
            rep.add("WARN", name, f"{v} — sha256 recorded by hand, not the pinned {pin.version} build")
        else:
            rep.add("OK", name, f"{v} (sha256 verified)")
    for name, why in (("gh", "audit GitHub checks"), ("jq", "kit hooks are inert without jq")):
        rep.add("OK" if shutil.which(name) else "WARN", name,
                "on PATH" if shutil.which(name) else f"not on PATH ({why})")

    # config.toml
    try:
        cfg = paths.load_config()
        cerr = None
    except Exception as e:  # tomllib.TOMLDecodeError
        cfg, cerr = {}, str(e)
    if cerr:
        rep.add("FAIL", "config.toml", f"{paths.config_path()}: {cerr}")
    elif not paths.config_path().is_file():
        rep.add("FAIL", "config.toml", f"{paths.config_path()} missing — run: kit setup")
    else:
        kr = cfg.get("kit_root", "")
        if kr and (paths.expand(kr) / "plugin" / ".claude-plugin" / "plugin.json").is_file():
            rep.add("OK", "config.toml", f"kit_root = {kr}")
        else:
            rep.add("FAIL", "config.toml", f"kit_root {kr!r} has no plugin/.claude-plugin/plugin.json")

    # privacy.local.toml
    pp = paths.privacy_path()
    prv = None
    if not pp.is_file():
        rep.add("FAIL", "privacy.local.toml", f"{pp} missing — run: kit setup")
    else:
        mode = stat.S_IMODE(pp.stat().st_mode)
        errs = privacy.validate_privacy(pp)
        if mode != 0o600:
            rep.add("FAIL", "privacy.local.toml", f"mode {mode:o}, must be 600 — run: chmod 600 {pp}")
        elif errs:
            rep.add("FAIL", "privacy.local.toml", "; ".join(errs[:3]))
        else:
            prv = privacy.load_privacy(pp)
            rep.add("OK", "privacy.local.toml",
                    f"{len(prv.usernames)} usernames, {len(prv.emails)} emails, {len(prv.literals)} literals")

    # rules budget (the checkout this CLI runs from)
    ok, detail = rules_budget(paths.plugin_dir())
    rep.add("OK" if ok else "FAIL", "rules budget", detail)

    # kit.toml in cwd
    kt = Path.cwd() / "kit.toml"
    if kt.is_file():
        errs = kittoml.validate_kit_toml(kt)
        if errs:
            rep.add("FAIL", "kit.toml", "; ".join(errs[:3]))
        else:
            rep.add("OK", "kit.toml", str(kt))
            names = kittoml.parse_kit_toml(kt).allow_literals
            unknown = [n for n in names if prv is None or prv.literal_by_name(n) is None]
            if unknown:
                rep.add("WARN", "kit.toml", f"unknown literal name(s) in allow_literals: {', '.join(unknown)} "
                        "(not in privacy.local.toml; the guard ignores them)")
    return rep


def _pinned_on_path(name: str, want: str, log=print) -> str | None:
    """The first <name> on PATH whose sha256 equals the pin — never one picked by its
    version output (review R4-1: a stub that prints the pinned version is not the pin).
    Every other <name> met on the way is named (ignored)."""
    seen = set()
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if not d:
            continue
        c = Path(os.path.abspath(d)) / name
        if c in seen:
            continue
        seen.add(c)
        try:
            if not (c.is_file() and os.access(c, os.X_OK)):
                continue
            if _sha256(c) == want:
                return str(c)
        except OSError:
            continue
        log(f"[note] {c} is not the pinned {name} build (sha256 differs) — ignored, not recorded")
    return None


def install_missing(bin_dir: Path, log=print) -> bool:
    """Make every pinned tool present AND hash-recorded. True = all good.

    Trust is content, never a version string (review R4-1): bin_dir/<name> counts only when
    its sha256 equals the pin; else a PATH binary with exactly the pinned sha256 is recorded
    as <name>_path; else the sha256-verified download is installed. Every route records
    <name>_sha256 = the pin, which the guard checks before each run."""
    ok = True
    supported, plat = platform_ok()
    for name, pin in TOOL_PINS.items():
        want = pin.binary_sha256
        here = bin_dir / name
        try:
            here_ok = here.is_file() and os.access(here, os.X_OK) and _sha256(here) == want
        except OSError:
            here_ok = False
        if here_ok:
            paths.set_config_value(paths.tool_sha_key(name), want)
            log(f"[skip] {name} {pin.version} already installed at {here} (sha256 verified)")
            continue
        onpath = _pinned_on_path(name, want, log)
        if onpath:
            paths.set_config_value(paths.tool_key(name), onpath)
            paths.set_config_value(paths.tool_sha_key(name), want)
            log(f"[skip] {name} {pin.version} found at {onpath} (sha256 = the pin) — recorded as "
                f"{paths.tool_key(name)} in {paths.config_path()}")
            continue
        if not supported:
            ok = False
            log(f"[FAIL] {name}: kit doctor --install only ships linux/x86_64 binaries (this is {plat}) — install "
                f"{name} {pin.version} yourself, then record it by hand in {paths.config_path()}: "
                f'{paths.tool_key(name)} = "<absolute path>" and {paths.tool_sha_key(name)} = "<its sha256>"')
            continue
        try:
            dest = install_tool(pin, bin_dir)
            paths.set_config_value(paths.tool_sha_key(name), want)
            log(f"[done] {name} {pin.version} → {dest} (sha256 verified, recorded)")
        except PinMismatch as e:
            ok = False
            log(f"[FAIL] {e}")
        except OSError as e:
            ok = False
            log(f"[FAIL] {name}: download/install failed: {e}")
    return ok


def run(args) -> int:
    rc = 0
    if args.install:
        bin_dir = paths.abs_dir(args.bin_dir) if args.bin_dir else paths.tools_dir()
        if not install_missing(bin_dir):
            rc = 1
            if args.bin_dir and bin_dir != paths.tools_dir():
                print(f"note: tools_dir stays {paths.tools_dir()} (the install into {bin_dir} did not complete)")
        elif args.bin_dir and bin_dir != paths.tools_dir():
            # only after a successful install (review R3-7): a failed one must not move the
            # guard away from a working tools_dir
            paths.set_config_value("tools_dir", str(bin_dir))   # the guard and session start read it
            print(f"note: tools_dir = {bin_dir} recorded in {paths.config_path()}")
        if str(bin_dir) not in os.environ.get("PATH", "").split(os.pathsep):
            print(f"note: {bin_dir} is not on PATH")
            os.environ["PATH"] = f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"
    print("kit doctor")
    rep = run_checks()
    n_fail = sum(1 for l in rep.lines if l[0] == "FAIL")
    n_warn = sum(1 for l in rep.lines if l[0] == "WARN")
    print(f"{n_fail} FAIL, {n_warn} WARN")
    return 1 if (rep.failed or rc) else 0
