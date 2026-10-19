"""kit update — local checkout: `git pull --ff-only` + /reload-plugins; GitHub
marketplace: `claude plugin update kit@multi-agent-kit`.

Which one is decided from ~/.claude/plugins/known_marketplaces.json (the
multi-agent-kit marketplace's source), NOT installed_plugins.json installPath:
for a directory marketplace installPath is a stale cache copy while the runtime
CLAUDE_PLUGIN_ROOT is the source dir (spike 0.1)."""
import json
import subprocess
import sys
from pathlib import Path

from cli import paths

MARKETPLACE = "multi-agent-kit"
PLUGIN_ID = "kit@multi-agent-kit"


def decide(cfg: dict):
    """("local", kit_root) | ("github", None) | (None, reason)."""
    kit_root = paths.expand(cfg["kit_root"]) if cfg.get("kit_root") else paths.kit_root()
    km_path = paths.claude_dir() / "plugins" / "known_marketplaces.json"
    try:
        km = json.loads(km_path.read_text())
    except (OSError, ValueError):
        km = {}
    entry = km.get(MARKETPLACE) if isinstance(km, dict) else None
    if not isinstance(entry, dict):
        return None, f"marketplace {MARKETPLACE} not installed ({km_path}) — run: kit setup"
    src = entry.get("source") or {}
    if src.get("source") == "directory":
        p = Path(src.get("path", ""))
        if p.resolve() == kit_root.resolve():
            return "local", kit_root
        return None, f"directory marketplace points at {p}, not this kit checkout {kit_root}"
    if src.get("source") == "github":
        return "github", None
    return None, f"unsupported marketplace source {src.get('source')!r}"


def run(args) -> int:
    try:
        cfg = paths.load_config()
    except Exception as e:
        print(f"kit: error: config.toml malformed: {e}", file=sys.stderr)
        return 1
    mode, info = decide(cfg)
    if mode is None:
        print(f"kit update: {info}", file=sys.stderr)
        return 1
    cmd = (["git", "-C", str(info), "pull", "--ff-only"] if mode == "local"
           else ["claude", "plugin", "update", PLUGIN_ID])
    if args.dry_run:
        print("WOULD RUN: " + " ".join(cmd))
    else:
        r = subprocess.run(cmd)
        if r.returncode != 0:
            return 1
    if mode == "local":
        print("run /reload-plugins in open sessions (local marketplace loads in place)")
    else:
        print("restart open sessions to pick up the updated plugin")
    return 0
