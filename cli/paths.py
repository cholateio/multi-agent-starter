"""Machine-level locations for kit. Every location has an env override so tests
(and cautious owners) can point the whole CLI into a throwaway directory.

    config_dir()  KIT_CONFIG_HOME  else ~/.config/kit        (same rule as plugin/hooks/lib.sh)
    state_dir()   KIT_STATE_HOME   else ~/.local/state/kit
    cache_dir()   KIT_CACHE_HOME   else ~/.cache/kit
    data_dir()    KIT_DATA_HOME    else ~/.local/share/kit
    claude_dir()  CLAUDE_CONFIG_DIR else ~/.claude
"""
import os
import re
import shutil
import tomllib
from pathlib import Path


def _env_path(var: str, default: Path) -> Path:
    v = os.environ.get(var, "")
    return Path(v) if v else default


def home() -> Path:
    return Path(os.environ.get("HOME") or Path.home())


def config_dir() -> Path:
    return _env_path("KIT_CONFIG_HOME", home() / ".config" / "kit")


def state_dir() -> Path:
    return _env_path("KIT_STATE_HOME", home() / ".local" / "state" / "kit")


def cache_dir() -> Path:
    return _env_path("KIT_CACHE_HOME", home() / ".cache" / "kit")


def data_dir() -> Path:
    return _env_path("KIT_DATA_HOME", home() / ".local" / "share" / "kit")


def claude_dir() -> Path:
    return _env_path("CLAUDE_CONFIG_DIR", home() / ".claude")


def kit_root() -> Path:
    """The kit checkout this CLI runs from (bin/kit's parent's parent)."""
    return Path(__file__).resolve().parents[1]


def plugin_dir() -> Path:
    return kit_root() / "plugin"


def templates_dir() -> Path:
    return plugin_dir() / "templates"


def version() -> str:
    try:
        return (kit_root() / "VERSION").read_text().strip()
    except OSError:
        return "unknown"


def config_path() -> Path:
    return config_dir() / "config.toml"


def privacy_path() -> Path:
    return config_dir() / "privacy.local.toml"


def load_config() -> dict:
    """~/.config/kit/config.toml as a dict; missing → {}. A malformed file raises
    tomllib.TOMLDecodeError (callers report it; never silently ignore config)."""
    p = config_path()
    if not p.is_file():
        return {}
    with p.open("rb") as f:
        return tomllib.load(f)


def expand(p: str) -> Path:
    """`~` against the (possibly isolated) HOME, not the passwd entry."""
    if p == "~" or p.startswith("~/"):
        return home() / p[2:] if len(p) > 1 else home()
    return Path(p)


def tools_dir() -> Path:
    """Where the pinned tools live: config.toml `tools_dir` (written by kit setup --bin-dir /
    kit doctor --install --bin-dir), else ~/.local/bin. Same rule as plugin/guard/lib-tools.sh."""
    try:
        d = load_config().get("tools_dir")
    except Exception:  # malformed config: doctor reports it; fall back to the default
        d = None
    return expand(d) if isinstance(d, str) and d else home() / ".local" / "bin"


def find_tool(name: str) -> str | None:
    """THE tool resolver (guard, session start, doctor, guard status): tools_dir first, then PATH."""
    p = tools_dir() / name
    if p.is_file() and os.access(p, os.X_OK):
        return str(p)
    return shutil.which(name)


def set_config_value(key: str, value: str) -> None:
    """Set a top-level string key in config.toml in place (replace the line, or insert it
    before the first [table]); creates the file when missing."""
    p = config_path()
    line = f'{key} = "{value}"\n'
    lines = p.read_text().splitlines(True) if p.is_file() else []
    rx = re.compile(rf"^\s*{re.escape(key)}\s*=")
    first_table = next((i for i, l in enumerate(lines) if l.lstrip().startswith("[")), len(lines))
    for i, l in enumerate(lines[:first_table]):
        if rx.match(l):
            lines[i] = line
            break
    else:
        at = first_table
        while at > 0 and not lines[at - 1].strip():
            at -= 1
        lines[at:at] = [line]
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("".join(lines))
