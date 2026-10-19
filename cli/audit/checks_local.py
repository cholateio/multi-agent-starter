"""Local audit checks (design §8): A1 A2 A2x A3 A4 A5 A10 A11 A12 A13 A15 A16 A17.
Every check is `a<N>(t, ctx) -> list[Finding]`; snippets never carry literal values."""
import json
import re
import subprocess
import tempfile
import unicodedata
from pathlib import Path

from cli import gitutil, paths
from cli.audit.report import Finding, redact

LOCKFILES = {"pnpm-lock.yaml", "package-lock.json", "yarn.lock", "uv.lock", "poetry.lock", "Cargo.lock",
             "go.sum", "requirements.txt", "Pipfile.lock", "Gemfile.lock", "composer.lock"}
SKIP_TEXT = LOCKFILES | {"go.sum"}
ALLOW_MARK = "kit-privacy: allow"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
USES_RE = re.compile(r"^\s*-?\s*uses:\s*['\"]?([^@\s'\"#]+)@([^\s'\"#]+)")
A5_RES = [
    ("local path", re.compile(r"/home/[a-z_][a-z0-9_-]*/")),
    ("local path", re.compile(r"/mnt/c/Users/[^/\s]+")),
    ("local path", re.compile(r"[A-Za-z]:\\\\?Users\\\\?[^\\\s]+")),
    ("email", re.compile(r"(?<![\w.+-])(?!git@)(?!no-?reply@)[A-Za-z0-9._%+-]+@"
                         r"(?!users\.noreply\.github\.com\b|example\.(?:com|org|net)\b)[A-Za-z0-9.-]+\.[a-z]{2,}\b")),
]
A5_CAP = 50


def _sev(ctx, public, private):
    return public if ctx.visibility == "public" else private


def _allowed_path(path: str, ctx) -> bool:
    import fnmatch
    pats = getattr(ctx.kittoml, "allow_paths", []) if ctx.kittoml else []
    return any(fnmatch.fnmatchcase(path, p) for p in pats)


def _tracked(t) -> list[str]:
    try:
        return gitutil.tracked_files(t.path)
    except gitutil.GitError:
        return []


# ------------------------------------------------------------------ A1 gitleaks
def a1(t, ctx):
    exe = ctx.tools.get("gitleaks")
    if not exe:
        return [Finding(t.name, "A1", "UNKNOWN", None, None, "gitleaks not available", "kit doctor --install")]
    with tempfile.TemporaryDirectory() as td:
        rep = Path(td) / "r.json"
        cmd = [str(exe), "git", str(t.path), "--redact", "--no-banner", "--report-format", "json",
               "--report-path", str(rep), "--exit-code", "1", "--log-level", "error"]
        cfg = paths.plugin_dir() / "guard" / "gitleaks.toml"
        if cfg.is_file():
            cmd += ["--config", str(cfg)]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, cwd=str(t.path), timeout=600)
        except (OSError, subprocess.TimeoutExpired) as e:
            return [Finding(t.name, "A1", "UNKNOWN", None, None, f"gitleaks failed: {e}", "")]
        if r.returncode not in (0, 1):
            return [Finding(t.name, "A1", "UNKNOWN", None, None, f"gitleaks exited {r.returncode}", "")]
        try:
            items = json.loads(rep.read_text() or "[]") if rep.exists() else []
        except ValueError:
            return [Finding(t.name, "A1", "UNKNOWN", None, None, "gitleaks report unreadable", "")]
    out = []
    for it in items:
        out.append(Finding(t.name, "A1", _sev(ctx, "CRITICAL", "HIGH"), it.get("File"), it.get("StartLine"),
                           redact(f"{it.get('RuleID', 'secret')} in commit {str(it.get('Commit', ''))[:7]}",
                                  ctx.privacy),
                           "rotate the secret, then history rewrite (design §12.6)"))
    return out


# ------------------------------------------------------------------ A2 / A2x / A3 literals
def _literals(ctx):
    """(active, exempt): literals that apply at this visibility, split by kit.toml allow_literals."""
    if ctx.privacy is None:
        return [], []
    allow = set(getattr(ctx.kittoml, "allow_literals", []) or [])
    lits = [l for l in ctx.privacy.literals if l.tier == "always" or ctx.visibility == "public"]
    from cli.privacy import Literal
    lits += [Literal("email", e, "always") for e in ctx.privacy.emails if len(e) >= 4]
    return [l for l in lits if l.name not in allow], [l for l in lits if l.name in allow]


def a2_a3(t, ctx):
    active, exempt = _literals(ctx)
    out = [Finding(t.name, "A2x", "INFO", None, None, f"literal {l.name} allowed by kit.toml [privacy]",
                   "exception is diff-visible in kit.toml") for l in exempt]
    if not active:
        return out
    found = set()
    with tempfile.NamedTemporaryFile("w", suffix=".lits", delete=False) as tf:
        tf.write("\n".join(l.value for l in active) + "\n")
        lit_file = tf.name
    try:
        r = subprocess.run(["git", "-C", str(t.path), "grep", "-n", "-I", "-F", "-i", "-f", lit_file, "--"],
                           capture_output=True, text=True, errors="replace")
    finally:
        Path(lit_file).unlink(missing_ok=True)
    seen: dict[tuple, list] = {}
    for line in r.stdout.splitlines():
        m = re.match(r"^(.*?):(\d+):(.*)$", line)
        # literals are block-level: kit.toml allow_literals / allow_paths only, never the inline marker (O9)
        if not m or _allowed_path(m.group(1), ctx):
            continue
        low = m.group(3).lower()
        for l in active:
            if l.value.lower() in low:
                found.add(l.name)
                seen.setdefault((l.name, m.group(1)), []).append((int(m.group(2)), m.group(3)))
    for (name, path), hits in sorted(seen.items()):
        ln, text = hits[0]
        extra = f" (+{len(hits) - 1} more lines)" if len(hits) > 1 else ""
        out.append(Finding(t.name, "A2", _sev(ctx, "HIGH", "MEDIUM"), path, ln,
                           redact(text.strip(), ctx.privacy)[:160] + extra,
                           f"remove literal <{name}> (or allow it by name in kit.toml [privacy] allow_literals)"))
    # A3: literals present only in history
    hist = [l for l in active if l.name not in found]
    if hist:
        first: dict[str, str] = {}
        sha = ""
        lows = [(l, l.value.lower()) for l in hist]
        with subprocess.Popen(["git", "-C", str(t.path), "log", "--all", "-p", "--no-color", "--format=%x00%h"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace") as p:
            for line in p.stdout:
                if line.startswith("\0"):
                    sha = line[1:].strip()
                    continue
                low = line.lower()
                for l, v in lows:
                    if v in low:
                        first[l.name] = sha      # log is newest-first: keep overwriting → oldest
        for l in hist:
            if l.name in first:
                out.append(Finding(t.name, "A3", _sev(ctx, "MEDIUM", "LOW"), None, None,
                                   f"literal <{l.name}> only in history (first seen in {first[l.name]})",
                                   "history rewrite (design §12.6)"))
    return out


# ------------------------------------------------------------------ A4 forbidden tracked paths
A4_GROUPS = [
    (".claude/", lambda p: p.startswith(".claude/")),
    (".superpowers/", lambda p: p.startswith(".superpowers/")),
    ("PROJECT.toml", lambda p: p.rsplit("/", 1)[-1] == "PROJECT.toml"),
    ("docs/LESSONS.md", lambda p: p == "docs/LESSONS.md"),
    ("docs/plans/", lambda p: p.startswith("docs/plans/")),
    ("docs/superpowers/plans/", lambda p: p.startswith("docs/superpowers/plans/")),
    ("docs/decisions/", lambda p: p.startswith("docs/decisions/")),
    ("*.local.toml", lambda p: p.endswith(".local.toml")),
    ("CLAUDE.local.md", lambda p: p.rsplit("/", 1)[-1] == "CLAUDE.local.md"),
    (".env*", lambda p: env_forbidden(p.rsplit("/", 1)[-1])),
]
ENV_TEMPLATE_SUFFIXES = ("example", "sample", "template", "dist", "defaults")


def env_forbidden(base: str) -> bool:
    """Same rule as the guard (lib-guard.sh guard_env_class): `.env` and `.env.<name>`
    unless the LAST suffix marks a template; `.envrc` / `.environment` are not env files."""
    if base == ".env":
        return True
    return base.startswith(".env.") and base.rsplit(".", 1)[-1] not in ENV_TEMPLATE_SUFFIXES


def a4(t, ctx, tracked):
    out = []
    files = [p for p in tracked if not p.endswith("/.gitkeep")]
    for label, match in A4_GROUPS:
        hits = [p for p in files if match(p) and not (label == ".env*" and _allowed_path(p, ctx))]
        if hits:
            out.append(Finding(t.name, "A4", _sev(ctx, "HIGH", "MEDIUM"), hits[0], None,
                               f"{len(hits)} tracked file(s) under {label}",
                               f"git rm -r --cached {label.rstrip('*')} (kit migrate does this)"))
    return out


# ------------------------------------------------------------------ A5 generic privacy regex
def a5(t, ctx):
    r = subprocess.run(["git", "-C", str(t.path), "grep", "-n", "-I", "-E",
                        r"/home/|/mnt/c/Users/|[A-Za-z]:\\\\?Users|@[A-Za-z0-9.-]+\.[a-z]{2,}", "--"],
                       capture_output=True, text=True, errors="replace")
    out = []
    for line in r.stdout.splitlines():
        m = re.match(r"^(.*?):(\d+):(.*)$", line)
        if not m:
            continue
        path, ln, text = m.group(1), int(m.group(2)), m.group(3)
        if ALLOW_MARK in text or _allowed_path(path, ctx) or path.rsplit("/", 1)[-1] in SKIP_TEXT:
            continue
        for kind, rx in A5_RES:
            mm = rx.search(text)
            if mm:
                snippet = redact(mm.group(0), ctx.privacy)
                if kind == "email":
                    local, _, dom = snippet.partition("@")
                    snippet = (local[:1] + "***@" + dom) if dom else snippet
                out.append(Finding(t.name, "A5", _sev(ctx, "MEDIUM", "LOW"), path, ln, f"{kind}: {snippet}",
                                   "use $HOME / env vars / a noreply address, or mark the line kit-privacy: allow"))
                break
        if len(out) >= A5_CAP:
            out[-1].snippet += f" (capped at {A5_CAP})"
            break
    return out


# ------------------------------------------------------------------ A10 / A11 workflows
def a10_a11(t, ctx, tracked):
    out = []
    for wf in [p for p in tracked if re.match(r"^\.github/workflows/[^/]+\.ya?ml$", p)]:
        try:
            lines = (t.path / wf).read_text(errors="replace").splitlines()
        except OSError:
            continue
        top_perm = any(re.match(r"^permissions\s*:", l) for l in lines)
        writes = any(re.search(r"(:\s*write\b|write-all)", l) for l in lines
                     if not l.lstrip().startswith("#"))
        if not top_perm:
            out.append(Finding(t.name, "A11", "MEDIUM", wf, None, "no top-level permissions:",
                               "add `permissions: contents: read` at the top; raise per job"))
        unpinned = []
        for i, l in enumerate(lines, 1):
            m = USES_RE.match(l)
            if m and not m.group(1).startswith(("./", "docker://")) and not SHA_RE.match(m.group(2)):
                unpinned.append((i, f"{m.group(1)}@{m.group(2)}"))
        if unpinned:
            high = writes or (not top_perm and ctx.default_workflow_write is True)
            out.append(Finding(t.name, "A10", "HIGH" if high else "MEDIUM", wf, unpinned[0][0],
                               f"{len(unpinned)} unpinned: " + ", ".join(u for _, u in unpinned[:4]),
                               "pin uses: to a 40-char SHA with a # vX.Y.Z comment"))
    return out


# ------------------------------------------------------------------ A12 osv-scanner
def a12(t, ctx, tracked):
    locks = [p for p in tracked if p.rsplit("/", 1)[-1] in LOCKFILES and p.rsplit("/", 1)[-1] != "requirements.txt"]
    if not locks:
        return []
    exe = ctx.tools.get("osv-scanner")
    if not exe:
        return [Finding(t.name, "A12", "UNKNOWN", locks[0], None, "osv-scanner not available", "kit doctor --install")]
    cmd = [str(exe), "scan", "source", "--format", "json"] + [f"--lockfile={t.path / l}" for l in locks]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        data = json.loads(r.stdout or "{}")
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return [Finding(t.name, "A12", "UNKNOWN", locks[0], None, "osv-scanner failed (offline?)", "")]
    if r.returncode not in (0, 1):
        return [Finding(t.name, "A12", "UNKNOWN", locks[0], None, f"osv-scanner exited {r.returncode}", "")]
    bad = []
    for res in data.get("results", []) or []:
        for pkg in res.get("packages", []) or []:
            scores = []
            for g in pkg.get("groups", []) or []:
                try:
                    scores.append(float(g.get("max_severity") or 0))
                except ValueError:
                    pass
            if scores and max(scores) >= 7.0:
                p = pkg.get("package", {})
                bad.append(f"{p.get('name')}@{p.get('version')} ({max(scores):.1f})")
    if not bad:
        return []
    deployed = ctx.project_status in (None, "active", "idle")
    return [Finding(t.name, "A12", "HIGH" if deployed else "MEDIUM", locks[0], None,
                    f"{len(bad)} package(s) with CRITICAL/HIGH vulns: " + ", ".join(bad[:4]),
                    "upgrade the affected packages (osv-scanner scan source -r .)")]


# ------------------------------------------------------------------ A13 license
def a13(t, ctx, tracked):
    if ctx.visibility != "public":
        return []
    lic = next((p for p in ("LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING")
                if p in tracked and (t.path / p).is_file()), None)
    if lic is None or (t.path / lic).stat().st_size == 0:
        return [Finding(t.name, "A13", "MEDIUM", lic, None, "LICENSE missing" if lic is None else "LICENSE is empty",
                        "add the full license text (kit migrate lays down MIT)")]
    if ctx.gh_repo is not None and ctx.kittoml is not None:
        spdx = ((ctx.gh_repo.get("license") or {}).get("spdx_id") or "NOASSERTION")
        want = ctx.kittoml.license
        if want != "none" and spdx != want:
            return [Finding(t.name, "A13", "MEDIUM", lic, None,
                            f"GitHub detects license {spdx}, kit.toml says {want}", "use the canonical license text")]
    return []


# ------------------------------------------------------------------ A15 README
EMOJI_HEAD = re.compile(r"^#+\s*[\U0001F300-\U0001FAFF☀-➿]")
MARKERS = ("私人 repo", "私人repo", "written for future me", "寫給未來的我", "private repo")


def a15(t, ctx, tracked):
    if ctx.visibility != "public":
        return []
    readme = next((p for p in ("README.md", "README", "readme.md") if p in tracked and (t.path / p).is_file()), None)
    if readme is None:
        return [Finding(t.name, "A15", "MEDIUM", None, None, "README missing", "write README.md (kit recipe)")]
    text = (t.path / readme).read_text(errors="replace")
    lines = text.splitlines()
    out = []
    fx = "rewrite with the kit README recipe (D18 prompt from kit migrate)"
    h1 = next(((i, l) for i, l in enumerate(lines, 1) if l.startswith("# ")), None)
    if h1 and re.search(r"—|:|：| - ", h1[1][2:]):
        out.append(Finding(t.name, "A15", "LOW", readme, h1[0], "H1 is more than the project name", fx))
    low = text.lower()
    for mk in MARKERS:
        if mk.lower() in low:
            ln = next(i for i, l in enumerate(lines, 1) if mk.lower() in l.lower())
            out.append(Finding(t.name, "A15", "MEDIUM", readme, ln, f"private-notes marker: '{mk}'", fx))
            break
    if re.search(r"/home/[a-z_][a-z0-9_-]*/|/mnt/c/Users/", text):
        out.append(Finding(t.name, "A15", "MEDIUM", readme, None, "README contains a local path", fx))
    lang = getattr(ctx.kittoml, "readme_lang", "en") if ctx.kittoml else "en"
    letters = [c for c in text if c.isalpha()]
    cjk = sum(1 for c in letters if unicodedata.east_asian_width(c) in ("W", "F"))
    if lang == "en" and letters and cjk / len(letters) > 0.10:
        out.append(Finding(t.name, "A15", "LOW", readme, None, f"CJK ratio {cjk / len(letters):.0%} with readme_lang=en",
                           "English README, or readme_lang = \"zh-TW\" in kit.toml"))
    emo = next((i for i, l in enumerate(lines, 1) if EMOJI_HEAD.match(l)), None)
    if emo:
        out.append(Finding(t.name, "A15", "LOW", readme, emo, "emoji heading", fx))
    missing = [h for h in ("## Install", "## License") if not re.search(rf"^{h}\b", text, re.M)]
    if missing:
        out.append(Finding(t.name, "A15", "LOW", readme, None, "missing " + " / ".join(missing), fx))
    return out


# ------------------------------------------------------------------ A16 / A17
def a16(t, ctx):
    hp = subprocess.run(["git", "-C", str(t.path), "config", "--local", "--get", "core.hooksPath"],
                        capture_output=True, text=True).stdout.strip()
    if hp:
        return [Finding(t.name, "A16", "HIGH", ".git/config", None, f"repo-local core.hooksPath = {hp} overrides the global guard",
                        "git config --local --unset core.hooksPath (chain husky from the repo hook instead)")]
    return []


def a17(t, ctx):
    gi = t.path / ".gitignore"
    text = gi.read_text(errors="replace") if gi.is_file() else ""
    miss = []
    if "# >>> kit v5" not in text:
        miss.append("kit v5 block")
    ignored = subprocess.run(["git", "-C", str(t.path), "check-ignore", "-q", "--no-index", ".claude/settings.json"],
                             capture_output=True).returncode == 0
    if not ignored:
        miss.append(".claude/ not ignored")
    if miss:
        return [Finding(t.name, "A17", "MEDIUM", ".gitignore", None, "; ".join(miss), "kit migrate (managed block)")]
    return []


def run_local_checks(t, ctx) -> list:
    """One broken repo / file never aborts the fleet run: a crashing check becomes UNKNOWN."""
    tracked = _tracked(t)
    out = []
    for check, fn in (("A1", lambda: a1(t, ctx)), ("A2", lambda: a2_a3(t, ctx)), ("A4", lambda: a4(t, ctx, tracked)),
                      ("A5", lambda: a5(t, ctx)), ("A10", lambda: a10_a11(t, ctx, tracked)),
                      ("A12", lambda: a12(t, ctx, tracked)), ("A13", lambda: a13(t, ctx, tracked)),
                      ("A15", lambda: a15(t, ctx, tracked)), ("A16", lambda: a16(t, ctx)), ("A17", lambda: a17(t, ctx))):
        try:
            out += fn()
        except Exception as e:  # noqa: BLE001 — reported, never silent
            out.append(Finding(t.name, check, "UNKNOWN", None, None, f"check crashed: {type(e).__name__}", ""))
    return out
