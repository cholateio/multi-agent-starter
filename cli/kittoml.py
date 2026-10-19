"""kit.toml: the tracked, tool-neutral v5 project marker (design §5.2, D7).

parse_kit_toml() is lenient (defaults for missing keys) because hooks and the
guard treat a missing visibility as public (fail-closed). validate_kit_toml()
is strict: it also enforces the text-level contract the bash hook relies on —
`protected = [` one entry per line, no inline comments on entry lines.
"""
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from cli import paths

VISIBILITIES = ("public", "private")
LICENSES = ("MIT", "CC-BY-4.0", "none")
LANGS = ("en", "zh-TW")
LITERAL_NAME_RE = re.compile(r"^[a-z0-9-]{3,40}$")


@dataclass
class KitToml:
    kit: int = 5
    visibility: str = "public"
    license: str = "none"
    readme_lang: str = "en"
    protected: list[str] = field(default_factory=list)
    allow_paths: list[str] = field(default_factory=list)
    allow_literals: list[str] = field(default_factory=list)
    path: Path | None = None


def _str_list(v) -> list[str]:
    return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []


def parse_kit_toml(path: Path) -> KitToml:
    """Raises OSError / tomllib.TOMLDecodeError on unreadable / malformed files."""
    path = Path(path)
    with path.open("rb") as f:
        d = tomllib.load(f)
    priv = d.get("privacy") if isinstance(d.get("privacy"), dict) else {}
    return KitToml(
        kit=d.get("kit", 5) if isinstance(d.get("kit", 5), int) else 0,
        visibility=d.get("visibility", "public") if isinstance(d.get("visibility", "public"), str) else "public",
        license=d.get("license", "none") if isinstance(d.get("license", "none"), str) else "none",
        readme_lang=d.get("readme_lang", "en") if isinstance(d.get("readme_lang", "en"), str) else "en",
        protected=_str_list(d.get("protected", [])),
        allow_paths=_str_list(priv.get("allow_paths", [])),
        allow_literals=_str_list(priv.get("allow_literals", [])),
        path=path,
    )


def _protected_text_errors(text: str) -> list[str]:
    """The bash parser's contract (plugin/hooks/lib.sh kit_toml_protected)."""
    errs: list[str] = []
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^\s*\[", line):
            break                                  # first table ends the top level
        m = re.match(r"^\s*protected\s*=\s*\[(.*)$", line)
        if m:
            start = i
            break
    if start is None:
        return errs
    first = re.match(r"^\s*protected\s*=\s*\[(.*)$", lines[start]).group(1)
    for n, rest in enumerate([first] + lines[start + 1:]):
        lineno = start + 1 + n
        items, q, closed = 0, "", False
        for c in rest:
            if q:
                if c == q:
                    q = ""
                continue
            if c in "\"'":
                q = c
                items += 1
            elif c == "#":
                if items:
                    errs.append(f"kit.toml:{lineno}: protected: inline comment on an entry line "
                                "(one entry per line, comments on their own line)")
                break
            elif c == "]":
                closed = True
                break
        if items > 1:
            errs.append(f"kit.toml:{lineno}: protected: one entry per line (found {items})")
        if closed:
            break
    return errs


def validate_kit_toml(path: Path) -> list[str]:
    path = Path(path)
    if not path.is_file():
        return [f"kit.toml: not found at {path}"]
    text = path.read_text(encoding="utf-8", errors="replace")
    try:
        d = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        return [f"kit.toml: TOML syntax error: {e}"]
    errs: list[str] = []
    if d.get("kit") != 5:
        errs.append(f"kit.toml: kit = 5 required (schema major), got {d.get('kit')!r}")
    if "visibility" in d and d["visibility"] not in VISIBILITIES:
        errs.append(f"kit.toml: visibility must be one of {'|'.join(VISIBILITIES)}, got {d['visibility']!r}")
    if "license" in d and d["license"] not in LICENSES:
        errs.append(f"kit.toml: license must be one of {'|'.join(LICENSES)}, got {d['license']!r}")
    if "readme_lang" in d and d["readme_lang"] not in LANGS:
        errs.append(f"kit.toml: readme_lang must be one of {'|'.join(LANGS)}, got {d['readme_lang']!r}")
    if "protected" in d:
        v = d["protected"]
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            errs.append("kit.toml: protected must be an array of strings (the hook ignores anything else)")
        else:
            errs.extend(_protected_text_errors(text))
    priv = d.get("privacy", {})
    if not isinstance(priv, dict):
        errs.append("kit.toml: [privacy] must be a table")
        priv = {}
    for key in ("allow_paths", "allow_literals"):
        if key in priv:
            v = priv[key]
            if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
                errs.append(f"kit.toml: [privacy] {key} must be an array of strings")
    for name in _str_list(priv.get("allow_literals", [])):
        if not LITERAL_NAME_RE.match(name):
            errs.append(f"kit.toml: [privacy] allow_literals entry {name[:12]!r}... is not a literal NAME "
                        "(^[a-z0-9-]{3,40}$) — reference privacy.local.toml names, never values")
    return errs


def render_kit_toml(visibility: str, license: str, readme_lang: str = "en",
                    protected: list[str] | None = None) -> str:
    """Fill plugin/templates/kit.toml. `protected` items starting with '#' are kept
    as comment lines inside the array (migrate carries v4 comments over)."""
    tpl = (paths.templates_dir() / "kit.toml").read_text(encoding="utf-8")
    lines = []
    for item in protected or []:
        item = item.strip()
        if not item:
            continue
        if item.startswith("#"):
            lines.append(f"  {item}\n")
        else:
            lines.append('  "' + item.replace("\\", "\\\\").replace('"', '\\"') + '",\n')
    return (tpl.replace("{{VISIBILITY}}", visibility).replace("{{LICENSE}}", license)
               .replace("{{LANG}}", readme_lang).replace("{{PROTECTED}}", "".join(lines)))
