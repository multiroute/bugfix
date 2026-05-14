#!/usr/bin/env bash
# Render-template lint (R4 #4 from deep code review).
#
# Stage skills include fenced code blocks containing user-facing templates
# (PR bodies, ticket comments, block-and-comment messages). These templates
# are rendered to humans at runtime, and stale increment-era wording inside
# them silently shipped a regression that needed a follow-up sweep
# (commit 5e83a59). This lint prevents the class from returning.
#
# Rule: inside any fenced code block (``` ... ```) in a stage skill body,
# the phrases "Increment N", "not yet implemented", "stub" (with capital S),
# and "future increment" MUST NOT appear. The surrounding prose is allowed
# to discuss them (e.g., the "Routing rule" guardrail in using-bugfix says
# 'don't claim "not yet implemented" at runtime') — only the fenced templates
# are forbidden.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PLUGIN_ROOT="$PLUGIN_ROOT" python3 <<'PY'
import os, re, sys

plugin_root = os.environ["PLUGIN_ROOT"]
skill_dir = os.path.join(plugin_root, "skills")

# Phrases that MUST NOT appear inside fenced templates. The first pattern is
# regex-anchored on word boundaries to avoid matching "incremented" etc.
forbidden = [
    (re.compile(r"\bIncrement\s+\d+\b"), "'Increment N' historical reference"),
    (re.compile(r"\bnot yet implemented\b", re.IGNORECASE), "'not yet implemented' phrase"),
    (re.compile(r"\bfuture increment\b", re.IGNORECASE), "'future increment' phrase"),
    (re.compile(r"\bstub\b"), "'stub' (likely stale)"),
]

fence_re = re.compile(r"^```", re.M)

# Limit to stage skill files (those that render templates at runtime).
stage_skills = [
    "using-bugfix", "run-ticket",
    "ticket-intake", "writing-plans", "executing-plan",
    "autonomous-finishing", "ci-watchdog", "pr-final-review",
    "ticket-adapter", "block-and-comment",
]

violations = []
for name in stage_skills:
    path = os.path.join(skill_dir, name, "SKILL.md")
    if not os.path.isfile(path):
        continue
    with open(path) as fh:
        body = fh.read()

    # Walk the body; track whether we're inside a fenced block.
    inside = False
    block_buf = []
    block_start = 0
    for lineno, line in enumerate(body.split("\n"), 1):
        if line.startswith("```"):
            if inside:
                # Closing fence — scan the buffer for forbidden phrases.
                block = "\n".join(block_buf)
                for pat, label in forbidden:
                    m = pat.search(block)
                    if m:
                        # Find which line within the block matched.
                        prefix = block[:m.start()]
                        rel_line = prefix.count("\n")
                        abs_line = block_start + rel_line
                        violations.append((name, abs_line, label, m.group(0)))
                inside = False
                block_buf = []
            else:
                inside = True
                block_start = lineno
            continue
        if inside:
            block_buf.append(line)

if violations:
    print("FAIL stale wording found inside fenced templates (these render to humans at runtime):")
    for name, lineno, label, matched in violations:
        print(f"  skills/{name}/SKILL.md:{lineno}: {label} — matched: {matched!r}")
    print()
    print("Fenced templates are user-facing. Move historical/internal refs to the surrounding prose.")
    sys.exit(1)

print(f"OK  no stale increment-era wording inside fenced templates in {len(stage_skills)} stage skills")
print("PASS")
PY
