<!-- Tool-neutral project memory. Never put local paths, costs or personal data here. -->
# [Project name]

## Project goal

[One sentence: what this is and who it is for. Example: "A personal proj-l site that lists my projects and writing."]

## Stack

- Language / framework: [e.g. TypeScript, Next.js 16, Tailwind v4]
- Services: [e.g. Postgres on Supabase, hosted on Vercel; "none" if there are none]
- Test: `[the exact command, copy-pasteable, e.g. npm test]`   <!-- write it so it runs as-is from the repo root -->

## File layout

- `[src/]` — [what lives here]
- `[docs/specs/]` — requirement specs; the authority for what to build
- `[tests/]` — [what lives here]

## Constraints

- [Things that must never change or break. Example: "Public URLs must not change; other sites link to them."]
- [Example: "Never edit applied database migrations; add a new one."]
- Path-type constraints are mirrored in `kit.toml [protected]`; keep the two in sync (one glob per line).

## Conventions

- [Naming, commit style, formatting. Example: "Conventional commits; run `npm run lint` before committing."]
- GitHub Actions: top-level `permissions: contents: read`, raised per job only when needed.
- GitHub Actions: pin every `uses:` to a 40-character commit SHA with a trailing `# vX.Y.Z` comment.

## Where to look

- `docs/specs/` — requirements and design decisions
- `docs/DEVELOPMENT.md` — restart, commands, environment variables, deploy, gotchas
