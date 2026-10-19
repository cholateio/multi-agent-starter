"""privacy.local.toml: the owner's personal literals (design §7.3). LOCAL ONLY.

The file is a strict TOML subset so the bash guard (Phase 4) can parse it with
awk: one key per line, arrays on one line, no inline tables. Validation errors
never echo literal values (they name the block / key instead).
"""
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from cli import paths

NAME_RE = re.compile(r"^[a-z0-9-]{3,40}$")
TIERS = ("always", "public-only")
MIN_VALUE_LEN = 4
TOP_KEYS = {"usernames", "emails", "literal"}
LITERAL_KEYS = {"name", "value", "tier", "note", "alias"}


@dataclass
class Literal:
    name: str
    value: str
    tier: str = "always"
    note: str = ""
    alias: str = ""


@dataclass
class Privacy:
    usernames: list[str] = field(default_factory=list)
    emails: list[str] = field(default_factory=list)
    literals: list[Literal] = field(default_factory=list)

    @staticmethod
    def skeleton() -> str:
        return (paths.templates_dir() / "privacy.local.toml.example").read_text(encoding="utf-8")

    def literal_by_name(self, name: str) -> Literal | None:
        return next((l for l in self.literals if l.name == name), None)


def load_privacy(path: Path) -> Privacy:
    """Lenient load (invalid entries skipped). Raises OSError / TOMLDecodeError."""
    with Path(path).open("rb") as f:
        d = tomllib.load(f)
    lits = []
    for b in d.get("literal", []) if isinstance(d.get("literal"), list) else []:
        if not isinstance(b, dict):
            continue
        name, value = b.get("name"), b.get("value")
        if not (isinstance(name, str) and isinstance(value, str) and len(value.strip()) >= MIN_VALUE_LEN):
            continue
        tier = b.get("tier") if b.get("tier") in TIERS else "always"
        lits.append(Literal(name, value, tier, str(b.get("note", "")), str(b.get("alias", ""))))
    strs = lambda v: [x for x in v if isinstance(x, str) and x] if isinstance(v, list) else []  # noqa: E731
    return Privacy(strs(d.get("usernames")), strs(d.get("emails")), lits)


def _text_errors(text: str) -> list[str]:
    errs = []
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#") or re.fullmatch(r"\[\[literal\]\]\s*(#.*)?", s):
            continue
        # strip quoted strings, then look for structure the line parser cannot follow
        bare = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)
        bare = re.sub(r"'[^']*'", "''", bare).split("#", 1)[0]
        if "{" in bare or bare.count("=") > 1:
            errs.append(f"privacy.local.toml:{n}: one key per line (no inline tables / multiple keys)")
        elif re.match(r"^[A-Za-z_]+\s*=\s*\[", bare) and "]" not in bare:
            errs.append(f"privacy.local.toml:{n}: arrays must open and close on one line")
    return errs


def validate_privacy(path: Path) -> list[str]:
    path = Path(path)
    if not path.is_file():
        return [f"privacy.local.toml: {path} not found"]
    text = path.read_text(encoding="utf-8", errors="replace")
    errs = _text_errors(text)
    try:
        d = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        return errs or [f"privacy.local.toml: TOML syntax error: {e}"]
    for k in d:
        if k not in TOP_KEYS:
            errs.append(f"privacy.local.toml: unknown top-level key {k!r}")
    for k in ("usernames", "emails"):
        v = d.get(k, [])
        if not isinstance(v, list) or not all(isinstance(x, str) and x for x in v):
            errs.append(f"privacy.local.toml: {k} must be a one-line array of non-empty strings")
    blocks = d.get("literal", [])
    if not isinstance(blocks, list):
        return errs + ["privacy.local.toml: literal must be [[literal]] blocks"]
    seen: set[str] = set()
    for i, b in enumerate(blocks, 1):
        where = f"privacy.local.toml: [[literal]] #{i}"
        if not isinstance(b, dict):
            errs.append(f"{where}: must be a table")
            continue
        for k in b:
            if k not in LITERAL_KEYS:
                errs.append(f"{where}: unknown key {k!r} (allowed: {', '.join(sorted(LITERAL_KEYS))})")
        name = b.get("name")
        if name is None:
            errs.append(f"{where}: name missing (required; kit.toml allow_literals refers to it)")
        elif not isinstance(name, str) or not NAME_RE.match(name):
            errs.append(f"{where}: name must match ^[a-z0-9-]{{3,40}}$")
        elif name in seen:
            errs.append(f"{where}: duplicate name {name!r}")
        else:
            seen.add(name)
            where = f"privacy.local.toml: [[literal]] {name!r}"
        v = b.get("value")
        if not isinstance(v, str):
            errs.append(f"{where}: value missing")
        elif len(v.strip()) < MIN_VALUE_LEN:
            errs.append(f"{where}: value must be >= 4 characters (short values match everywhere)")
        if b.get("tier", "always") not in TIERS:
            errs.append(f"{where}: tier must be always | public-only")
    return errs
