# Development

Everything you need to pick this project back up after months away. Replace each `[placeholder]`; delete sections that do not apply.

## Restart in 30 seconds

```bash
[install command, e.g. npm install]
# [environment reminder, e.g. make sure .env.local exists (see below); restore it from the password manager or the hosting dashboard]
[start the dev server]          # -> [default URL, e.g. http://localhost:3000]
```

## Commands

| Command | Purpose |
|---------|---------|
| `[dev command]` | Local development |
| `[build command]` | Production build |
| `[start command]` | Run the production build |
| `[lint / test command]` | [what the quality gate covers, e.g. "the only gate; there are no tests yet"] |

## Environment variables

Stored in `[env file, e.g. .env.local]`, never committed. This table lists names and purposes only, no values. Keep an `.env.example` with the same names and empty values.

| Variable | Purpose |
|----------|---------|
| `[VAR_NAME]` | [what it is used for] |

Without `[env file]`: [what breaks, e.g. "uploads silently fall back to local storage; the dashboard returns 500"]. Restore the file before debugging anything else.

## Deploy

- Hosting: [platform, e.g. Vercel, Railway, self-hosted] ([how a deploy is triggered, e.g. push to main])
- Database: [e.g. Postgres on Supabase, SQLite file, none] ([where it lives / how to connect])
- Assets: [where images and files live, e.g. an S3 bucket; delete this line if none]

## Easy to forget

Grows over time. Add a line whenever something nearly bit you, or looks like a bug but is intentional.

- [First gotcha or convention]

## Docs map

| File | What it holds |
|------|---------------|
| `AGENTS.md` | Goal, stack, layout, constraints and conventions (tool-neutral) |
| `docs/specs/` | Requirement specs |
| `docs/DEVELOPMENT.md` | This file |
