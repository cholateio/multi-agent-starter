"""kit init <dir> [--private] [--license MIT|CC-BY-4.0|none] [--lang en|zh-TW]

Lays down the v5 project skeleton, never clobbering an existing file; a fresh
(non-git) directory gets `git init -b main` + one bootstrap commit. Templates
that are missing are reported as `skip (template missing)`.
"""
import datetime
import shutil
import subprocess
from pathlib import Path

from cli import gitutil, kittoml, paths

BLOCK_START = "# >>> kit v5"
BLOCK_END = "# <<< kit v5 <<<"

BOOTSTRAP_PROMPT = (
    "Read AGENTS.md and replace every [placeholder]: project goal (one sentence), stack "
    "(with a copy-pasteable test command), file layout, constraints and conventions. Mirror every "
    "path-type constraint into kit.toml [protected] (one entry per line). Then rewrite README.md "
    "following the kit README recipe and put developer notes in docs/DEVELOPMENT.md. These files "
    "are tracked and may be public: no local absolute paths, costs, account ids or personal data. "
    "Show me the diff before committing."
)


def gitignore_block() -> str:
    tpl = (paths.templates_dir() / "gitignore").read_text(encoding="utf-8")
    start = tpl.index(BLOCK_START)
    end = tpl.index(BLOCK_END) + len(BLOCK_END)
    return tpl[start:end] + "\n"


def with_gitignore_block(text: str) -> str:
    """Return `text` with the managed kit block inserted (appended) or refreshed in place."""
    block = gitignore_block()
    if BLOCK_START in text and BLOCK_END in text:
        s = text.index(BLOCK_START)
        s = text.rfind("\n", 0, s) + 1
        e = text.index(BLOCK_END) + len(BLOCK_END)
        if e < len(text) and text[e] == "\n":
            e += 1
        return text[:s] + block + text[e:]
    sep = "" if not text or text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")
    return text + sep + block


def ensure_gitignore_block(path: Path, dry_run: bool = False) -> bool:
    """Insert (or refresh) the managed kit block; lines outside the markers are the
    project's and are never touched. Returns True when the file (would) change."""
    path = Path(path)
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    new = with_gitignore_block(text)
    if new == text:
        return False
    if not dry_run:
        path.write_text(new, encoding="utf-8")
    return True


def _write_new(path: Path, content: str, log) -> bool:
    rel = path.name if path.parent.name == "" else path
    if path.exists():
        log("skip", f"{rel} (exists)")
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    log("done", str(rel))
    return True


def run(args) -> int:
    root = Path(args.dir).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    tpl = paths.templates_dir()
    visibility = "private" if args.private else "public"
    fresh_repo = not gitutil.is_repo(root)

    def log(status, what):
        print(f"[{status}] {what}")

    def from_template(name, dest, subst=None):
        src = tpl / name
        target = root / dest
        if not src.is_file():
            if target.exists():
                log("skip", f"{dest} (exists)")
            else:
                log("skip", f"{dest} (template missing: plugin/templates/{name})")
            return
        text = src.read_text(encoding="utf-8")
        for k, v in (subst or {}).items():
            text = text.replace(k, v)
        _write_new(target, text, lambda s, w: log(s, w.replace(str(root) + "/", "")))

    from_template("AGENTS.md", "AGENTS.md")
    from_template("CLAUDE.md", "CLAUDE.md")
    kt = root / "kit.toml"
    if kt.exists():
        log("skip", "kit.toml (exists)")
    else:
        kt.write_text(kittoml.render_kit_toml(visibility, args.license, args.lang, []), encoding="utf-8")
        log("done", f"kit.toml (visibility={visibility}, license={args.license}, readme_lang={args.lang})")
    license_line = {"MIT": "[MIT](LICENSE)", "CC-BY-4.0": "[CC BY 4.0](LICENSE)"}.get(args.license, "All rights reserved")
    from_template("README.private.md" if args.private else "README.public.md", "README.md",
                  {"{{LICENSE_LINE}}": license_line})
    from_template("DEVELOPMENT.md", "docs/DEVELOPMENT.md")
    if args.license != "none":
        owner = args.owner or gitutil.config_get(root, "user.name") or "the authors"
        from_template(f"LICENSE.{args.license}", "LICENSE",
                      {"{{YEAR}}": str(datetime.date.today().year), "{{OWNER}}": owner})
    gi = root / ".gitignore"
    if not gi.exists():
        shutil.copyfile(tpl / "gitignore", gi)
        log("done", ".gitignore")
    elif ensure_gitignore_block(gi):
        log("done", ".gitignore (kit block inserted)")
    else:
        log("skip", ".gitignore (kit block present)")
    from_template("PROJECT.toml.example", "PROJECT.toml")  # template name is not a guard-forbidden path
    if shutil.which("mise"):
        from_template("mise.toml", "mise.toml")
    if not args.private:
        from_template("github/workflows/kit-guard.yml", ".github/workflows/kit-guard.yml")

    if fresh_repo:
        gitutil.run_git(root, "init", "-q", "-b", "main")
        gitutil.run_git(root, "add", "-A")
        r = subprocess.run(["git", "-C", str(root), "commit", "-q", "-m",
                            "chore: bootstrap with multi-agent-kit v5"], capture_output=True, text=True)
        if r.returncode == 0:
            log("done", "git init -b main + bootstrap commit")
        else:
            log("warn", f"git init done, bootstrap commit failed: {(r.stderr or r.stdout).strip()[:200]}")
    else:
        log("skip", "git init (already a repository; nothing committed)")

    print()
    print(f"bootstrap prompt (paste into `claude` started in {root}):")
    print()
    print("  " + BOOTSTRAP_PROMPT)
    return 0
