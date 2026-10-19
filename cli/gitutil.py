"""Small git helpers shared by init / migrate / audit."""
import subprocess
from pathlib import Path


class GitError(RuntimeError):
    pass


def run_git(repo, *args, check=True, input=None) -> str:
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, input=input)
    if check and r.returncode != 0:
        raise GitError(f"git {' '.join(args)} failed in {repo}: {(r.stderr or r.stdout).strip()[:400]}")
    return r.stdout


def is_repo(path) -> bool:
    r = subprocess.run(["git", "-C", str(path), "rev-parse", "--is-inside-work-tree"],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == "true"


def repo_root(path) -> Path | None:
    r = subprocess.run(["git", "-C", str(path), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(r.stdout.strip()) if r.returncode == 0 else None


def tracked_files(repo, *pathspec) -> list[str]:
    out = run_git(repo, "ls-files", "-z", "--", *pathspec)
    return [p for p in out.split("\0") if p]


def status_porcelain(repo) -> list[str]:
    """`git status --porcelain` lines (untracked included, ignored excluded)."""
    out = run_git(repo, "status", "--porcelain", "-z", "--untracked-files=all")
    # -z: entries separated by NUL; renames carry an extra NUL-separated source path
    items, parts, i = [], out.split("\0"), 0
    while i < len(parts):
        e = parts[i]
        if not e:
            i += 1
            continue
        items.append(e)
        i += 2 if e[:1] in ("R", "C") else 1
    return items


def is_dirty(repo) -> bool:
    return bool(status_porcelain(repo))


def has_commits(repo) -> bool:
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "-q", "HEAD"],
                          capture_output=True).returncode == 0


def config_get(repo, key) -> str:
    r = subprocess.run(["git", "-C", str(repo), "config", "--get", key], capture_output=True, text=True)
    return r.stdout.strip()


def parse_github_remote(url: str) -> tuple[str, str] | None:
    """git@github.com:o/r.git | https://github.com/o/r(.git) | ssh://git@github.com/o/r → (o, r)."""
    import re
    m = re.match(r"^(?:git@github\.com:|ssh://git@github\.com/|https?://(?:[^@/]+@)?github\.com/)"
                 r"([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$", url.strip())
    return (m.group(1), m.group(2)) if m else None
