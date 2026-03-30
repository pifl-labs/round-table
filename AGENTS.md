# Repository Guidelines

## Project Structure & Module Organization
Root-level orchestrators (`orchestrator.sh`, `code-review-orchestrator.sh`, `task-orchestrator.sh`) own the debate, code-review, and task pipelines. Every run writes transcripts to `sessions/<timestamp>/round-N/agent.md` plus `final/`, with specialized directories for `sessions/code-review` and `sessions/tasks`, while streamed logs land in `logs/`. The `web/` folder holds the Node 18 ESM server (`server.js`) and the three dashboards (`index.html`, `code-review.html`, `task.html`) that visualize those artifacts.

## Build, Test, and Development Commands
- `cp .env.example .env` and fill `CLAUDE_CODE_OAUTH_TOKEN`; add `OPENAI_API_KEY` or `GEMINI_API_KEY` only if the session will invoke those providers.
- `./orchestrator.sh "Ship feature X?" 2 "analyst,developer,critic" $(pwd)` starts a fresh debate; `--continue <id> 1` resumes the next round in an existing `sessions/<id>` directory.
- `./code-review-orchestrator.sh generate <id>` → `run <id>` bootstraps the two-phase review flow; use `--continue` to append rounds after agents are confirmed in the UI.
- `./task-orchestrator.sh generate <id>` → `run <id>` executes the pipeline described in `sessions/tasks/<id>/pipeline.json` with the release threshold from `meta.json`.
- `cd web && node server.js 3847` launches the monitoring UI; pass another port if 3847 is busy.

## Coding Style & Naming Conventions
Bash scripts keep `#!/usr/bin/env bash`, enable `set -euo pipefail`, favor lowercase `snake_case` helpers, and double-quote expansions to avoid globbing. Node modules use ES modules, 2-space indentation, `const` by default, and explicit relative imports; extend the `/api/...` switch and `MIME` map when exposing new assets or endpoints. New session folders should follow the existing `YYYYMMDD_HHMMSS` pattern so the web UI sorts correctly.

## Testing Guidelines
There is no standalone unit-test harness, so gate changes with smoke runs: `./orchestrator.sh "Smoke" 1` and confirm `sessions/<stamp>/round-1/*.md` exist plus `logs/<stamp>-main.log` lacks `❌`. For dashboard work, run `node --check web/server.js`, then `curl http://localhost:3847/api/agents` after the server boots to ensure routing.

## Commit & Pull Request Guidelines
Follow the observed `type: summary` convention (`feat:`, `fix:`, `chore:`, etc.) with imperative subjects. Keep related shell, UI, and documentation edits in the same commit to preserve traceability between pipelines and dashboards. PR descriptions should call out the topic tested, commands executed, the `sessions/<id>` folder reviewed, screenshots or log excerpts, any new configuration needs, and whether existing sessions must be migrated.

## Security & Configuration Tips
Do not commit `.env`, session payloads, or raw logs; scrub tokens and hostnames before sharing snippets. Reference paths (for example `sessions/20260401_101500/meta.json`) instead of pasting contents, and delete temporary sessions once reviewers finish verification.
