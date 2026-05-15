# bugfix

Autonomous bug-fix loop as a Claude skills plugin. From ticket to merge-ready PR with strong quality gates: spec-compliance review, code-quality review, mandatory regression-test-first plan, CI watchdog, and a calibrated final PR review.

## Status

**Production (Increments 1–7) — full autonomous loop runs end-to-end.**

`fix bug <github-url>` → ticket-intake → planning → executing → autonomous-finishing → CI watching (with auto-fix on failure) → calibrated final review → terminal `merge-ready` (human merges manually) or `pr-closed`. Real-world tuning of reviewer calibration comes after observing actual runs.

### Host requirements

The plugin runs on Bash + Claude Code's standard built-in tools (Read, Edit, Write, Bash, Skill, Task, TodoWrite) plus **either** the GitHub MCP server **or** the `gh` CLI for GitHub access. The adapter prefers GitHub MCP when present and falls back to `gh` (≥ 2.40) otherwise. The choice is cached per-run in `state.artifacts.adapter_backend` so a single run never mixes backends.

The CI watchdog stage long-polls CI. With `gh`, it uses `gh pr checks --watch --fail-fast` (blocking, backgrounded) — efficient and notified by the host runtime on completion. With MCP, it falls back to in-skill polling (30 s interval). For MCP-only environments with long CI runs (~30 min+), this consumes meaningfully more session time than the `gh` path.

## Install

**By GitHub repo (recommended):**

```bash
claude plugin marketplace add multiroute/bugfix
claude plugin install bugfix@multiroute
```

**From a local clone:**

```bash
git clone git@github.com:multiroute/bugfix.git
claude plugin marketplace add ./bugfix
claude plugin install bugfix@multiroute
```

**From a checkout (any directory containing this repo's tree at `./`):**

```bash
claude plugin marketplace add ./
claude plugin install bugfix@multiroute
```

The `@multiroute` suffix is the marketplace name (declared in `.claude-plugin/marketplace.json`), distinct from the plugin name `bugfix` before it.

Then start a fresh Claude Code session. The `SessionStart` hook fires on `startup|clear|compact` and the `bugfix:using-bugfix` meta-skill becomes part of the agent's context.

To uninstall:

```bash
claude plugin uninstall bugfix
```

## First-run setup

The loop writes `bugfix-status:in-progress`/`needs-info`/`rejected`/`ready-for-merge` labels on GitHub issues. The adapter **auto-creates** these labels on first use, so no manual setup is required for a default install — `gh label create` runs idempotently before each `set_status` call.

If you want to pre-create them (e.g., to customize colors), here are the defaults the adapter would create:

```bash
gh label create "bugfix-status:in-progress"     --color "0e8a16" --description "bugfix loop actively working"
gh label create "bugfix-status:needs-info"      --color "fbca04" --description "bugfix loop paused, needs human input"
gh label create "bugfix-status:rejected"        --color "b60205" --description "bugfix loop rejected this ticket"
gh label create "bugfix-status:ready-for-merge" --color "1d76db" --description "bugfix loop completed review; ready for human merge"
```

## Try it

In a fresh session:

```
fix bug https://github.com/<owner>/<repo>/issues/<number>
```

The agent invokes `bugfix:run-ticket`, parses the URL, initializes `.bugfix/runs/<ticket-id>.json`, and loops the stage skills to a terminal verdict on the PR. Identical behavior with `fix issue <url>` and `resolve issue <url>`.

The loop also handles improvement tickets (refactors, cleanups, new behavior requests) — not just defects. The ticket-intake stage classifies the ticket; bugs and improvements both run through planning → executing → finishing → CI → review, with the only difference being that improvements relax the failing-test-first rule (since there's no defect to reproduce). Tickets that are too vague to act on still reject at intake with a `bugfix-status:rejected` comment.

The URL must be a GitHub **issue** URL (not a PR URL). Owner and repo names must contain only `A-Za-z0-9._-` characters.

## Resuming a blocked ticket

When the loop pauses for human input (an intake classification couldn't decide, a plan reviewer rejected three times, CI couldn't be auto-fixed, the final reviewer found something critical), the bot posts a comment on the issue describing what it needs. To resume:

1. Read the bot's comment and provide whatever was requested (clarification, decision, manual fix).
2. Add a new comment on the issue containing the single word `resume` as its first non-whitespace token. (Substring matches like "don't resume" or "resume tomorrow" do NOT trigger resumption — `resume` must be the leading token.)
3. Re-invoke `fix bug <url>`. The driver detects the `resume` signal in the ticket comments, clears `blocked_reason`, and continues from the stored stage.

Bot-authored comments are filtered out, so the loop's own template (which contains the word "resume" in its instructions) won't self-trigger.

## Configuration

Optional plugin-wide config lives at `.bugfix/runs/config.json` (per-project, not committed). Schema: [`bugfix/schemas/config.schema.json`](schemas/config.schema.json). Useful knobs:

```json
{
  "base_branch": "main",
  "ticket_adapter": "github",
  "retry_budgets": {
    "spec_review": 2,
    "code_quality_review": 2,
    "ci": 2,
    "planning": 2
  },
  "pr_review": {
    "important_findings_block": false,
    "reviewer_must_run_regression_test": true
  },
  "model_hints": {
    "implementer": "opus"
  },
  "bot_author_allowlist": ["our-ci-runner", "release-bot"]
}
```

`bot_author_allowlist` extends the built-in `[bot]`-suffix and `authorAssociation=="BOT"` detection — list any service-account logins whose comments should NOT trigger resume signals.

`model_hints.implementer` selects the model class (`haiku` / `sonnet` / `opus`) the host should spawn for sub-agents that do real implementation work — the per-task implementers dispatched by `executing-plan` and the CI fix sub-agent dispatched by `ci-watchdog`. The single-session driver itself inherits the session model.

## Runtime tree (`.bugfix/`)

All operational data for bug-fix runs lives under `.bugfix/` at the repo root. **This directory is per-project temporary data and should be gitignored** — it's the loop's scratch space, not source-tracked artifacts.

```
.bugfix/
├── runs/
│   ├── config.json               # plugin-wide knobs (per project)
│   ├── <ticket-id>.json          # run state
│   └── <ticket-id>.events.log    # append-only JSONL audit trail
├── specs/
│   └── <ticket-id>.md            # bug spec written by ticket-intake (NOT committed)
└── plans/
    └── <ticket-id>.md            # implementation plan written by writing-plans (NOT committed)
```

Add `.bugfix/` to your project's `.gitignore`:

```bash
echo ".bugfix/" >> .gitignore
```

(Feature specs and plans — written outside the bug-fix loop — still go to `docs/superpowers/{specs,plans}/` and are committed normally. The split is intentional: bug-fix runs are operational, ephemeral, per-ticket; feature work is design artifacts kept in the source tree.)

State and events files are schema-validated by `bugfix/schemas/{run-state,events,config}.schema.json`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `gh CLI missing or not authenticated` | Install `gh` and run `gh auth login`. The adapter preflight requires both. |
| Loop reaches `merge-ready` but doesn't merge | By design — humans merge manually. Look for the bot's `merge-ready` comment on the PR. |
| Reviewer always finds critical issues that auto-close the PR | Tune the reviewer calibration by adjusting `pr_review.important_findings_block` in `.bugfix/runs/config.json`. |
| Ticket comment with `resume` doesn't unblock | Verify the word `resume` is the first non-whitespace token on the first non-empty line. "yes, resume" or "please resume" does NOT trigger. |
| `bugfix-status:* label not found` | Almost never happens (auto-create), but if it does: run the manual label-create commands from "First-run setup" above. |

## Tests

```bash
bugfix/tests/run-unit-tests.sh
```

Runs every `test-*.sh` script under `tests/unit/` and prints `ALL PASS` on success.

## License

MIT. Vendored superpowers skills inherit upstream MIT terms — see `LICENSE` and `VENDORED.md` at this plugin's root for attribution.
