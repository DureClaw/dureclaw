# open-agent-harness

A 5-agent AI development workflow harness for [OpenCode](https://opencode.ai), built as a plugin.

Agents collaborate in a loop: **Planner → Builder → Verifier → Reviewer → Gate → repeat** until all checks pass.

Repetitive checks run as deterministic shell hooks (not LLM calls), keeping token costs low.

---

## Architecture

```
5 Agents (Markdown + YAML frontmatter)
  Orchestrator  (primary)  — loop control, goal tracking, completion judgment
  Planner       (subagent) — task decomposition, risk assessment
  Builder       (subagent) — code changes (full write + bash access)
  Verifier      (subagent) — test/lint execution + result summary
  Reviewer      (subagent) — code review + fix instructions (read-only)

TypeScript Plugin (.opencode/plugin/harness.ts)
  tool.execute.before       — Builder permission gate (only Builder edits source)
  tool.execute.after        — bash results → .opencode/reports/ (automatic)
  session.idle              — runs 09_completion_gate.sh
  experimental.session.stop — gate FAIL → restart signal to Orchestrator
  Custom tools: run_hook, read_state, write_state, post_message, read_mailbox

Shell Hooks (.opencode/hooks/) — deterministic, no LLM calls
  00_preflight.sh      — env check + dependency install
  01_diff_summary.sh   — git diff → report
  02_format.sh         — formatter check (prettier/biome/black/gofmt)
  03_lint.sh           — linter (eslint/biome/ruff/golangci-lint)
  04_typecheck.sh      — type checker (tsc/mypy/go build/cargo check)
  05_unit_test.sh      — unit tests (bun test/vitest/pytest/go test)
  06_integration_test.sh — integration tests (if available)
  07_build.sh          — production build
  08_fail_classifier.py — classify + prioritize failures from reports
  09_completion_gate.sh — final gate: all required checks must pass

File-based State
  .opencode/state/state.json     — run_id, goal, tasks, loop_count
  .opencode/state/mailbox/       — inter-agent messages (JSON files)
  .opencode/reports/             — hook execution results (auto-generated)
```

---

## Installation

### Into a new project (via init script)

```bash
git clone https://github.com/your-org/open-agent-harness
bash open-agent-harness/scripts/init.sh /path/to/your-project
cd /path/to/your-project
opencode
```

### Manual

```bash
cp -r open-agent-harness/.opencode your-project/.opencode
cp open-agent-harness/opencode.json your-project/opencode.json
chmod +x your-project/.opencode/hooks/*.sh your-project/.opencode/hooks/*.py
```

### Requirements

- [OpenCode](https://opencode.ai) CLI installed
- Bun ≥ 1.0 (for the TypeScript plugin)
- Python 3 (for `08_fail_classifier.py`)
- Your project's stack tools (tsc, eslint, pytest, etc.)

---

## Usage

### Start a workloop

```
/workloop Add pagination to the user list API endpoint
```

This initializes state and starts the 5-agent loop:

```
Orchestrator → Planner (decompose goal into tasks)
             → Builder (implement each task)
             → Verifier (run lint + tests + typecheck)
             → Reviewer (code review + fix instructions)
             → Gate (09_completion_gate.sh)
                ├── exit 0 → ✅ Done! Run /ship
                ├── exit 1 → ❌ Failures → loop again (max 5)
                └── exit 2 → ⚠️  No tests → Builder adds tests → loop again
```

### Ship when ready

```
/ship feat: add pagination to user list API
```

Runs preflight + build + gate. If all pass, proposes a conventional commit.

### Run hooks directly (for debugging)

```bash
bash .opencode/hooks/00_preflight.sh
bash .opencode/hooks/09_completion_gate.sh
python3 .opencode/hooks/08_fail_classifier.py
```

Reports are written to `.opencode/reports/`.

---

## Token-Saving Design

The harness enforces strict token budgets through hard rules in agent prompts:

| Rule | Saves tokens |
|------|-------------|
| Hooks run outside LLM — results in reports/ | 90%+ of test output |
| Agents pass report paths, not contents | 60-80% per message |
| Messages capped at 200 tokens | Prevents context bloat |
| Orchestrator does 1:1 messaging only | No broadcast overhead |
| Verifier/Reviewer send 3-line summaries | ~95% vs full output |

---

## Agent Permissions

| Agent | Read | Write | Bash | Task |
|-------|------|-------|------|------|
| Orchestrator | All | state/, reports/ | Query-only | ✅ spawn subagents |
| Planner | All | *.md, state/ | ❌ | ❌ |
| Builder | All | **All** | ✅ Full | ❌ |
| Verifier | All | reports/ | Test/lint only | ❌ |
| Reviewer | All | mailbox/ | ❌ | ❌ |

The plugin enforces: **only Builder may edit source files**.

---

## Supported Stacks

Auto-detected by `_lib.sh`:

| Stack | Detected by | Format | Lint | Typecheck | Test | Build |
|-------|-------------|--------|------|-----------|------|-------|
| **Bun/TS** | bun.lockb | prettier/biome | eslint/biome | tsc | bun test | bun run build |
| **Node/TS** | package.json | prettier | eslint | tsc | vitest/jest | npm run build |
| **Python** | pyproject.toml | black/ruff | ruff/flake8 | mypy/pyright | pytest | python -m build |
| **Go** | go.mod | gofmt | golangci-lint | go build | go test | go build |
| **Rust** | Cargo.toml | rustfmt | clippy | cargo check | cargo test | cargo build |

---

## File Structure

```
open-agent-harness/
├── .opencode/
│   ├── agents/
│   │   ├── orchestrator.md    primary agent, loop controller
│   │   ├── planner.md         task decomposition
│   │   ├── builder.md         code implementation
│   │   ├── verifier.md        test/lint execution
│   │   └── reviewer.md        code review (read-only)
│   ├── plugin/
│   │   └── harness.ts         OpenCode plugin
│   ├── hooks/
│   │   ├── _lib.sh            shared utilities
│   │   ├── 00_preflight.sh    environment check
│   │   ├── 01_diff_summary.sh git diff report
│   │   ├── 02_format.sh       format check
│   │   ├── 03_lint.sh         linting
│   │   ├── 04_typecheck.sh    type checking
│   │   ├── 05_unit_test.sh    unit tests
│   │   ├── 06_integration_test.sh integration tests
│   │   ├── 07_build.sh        build
│   │   ├── 08_fail_classifier.py failure classification
│   │   └── 09_completion_gate.sh final gate
│   ├── commands/
│   │   ├── workloop.md        /workloop command
│   │   └── ship.md            /ship command
│   └── state/
│       ├── state.json         runtime state
│       └── mailbox/           inter-agent messages
├── opencode.json              agent config + permissions
├── package.json
├── tsconfig.json
├── scripts/
│   └── init.sh               install into existing project
└── README.md
```

---

## Customization

### Add a custom hook

1. Create `.opencode/hooks/10_my_check.sh`
2. Add `"10_my_check.sh"` to `ALLOWED_HOOKS` in `harness.ts`
3. Call from agents with `run_hook("10_my_check.sh")`

### Adjust agent permissions

Edit `opencode.json` → `agents.<name>.permissions`.

### Increase loop limit

Edit `.opencode/agents/orchestrator.md` → change `max_steps: 20` and the loop limit comment.

---

## License

MIT
