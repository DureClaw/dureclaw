# @dureclaw/sim-agent

A **virtual fleet simulator** for DureClaw. It is *not* a mock UI — each simulated
worker JOINs the real Phoenix bus using the exact same wire protocol as
`packages/agent-daemon`, declares presence, and exchanges real `task.assign` /
`task.progress` / `task.result` / `task.approval_requested` events. The
orchestrator, dashboard and event stream are 100% identical to a physical fleet;
only the worker *execution* is replaced by a deterministic scenario script.

## Why

1. **Stage safety net** — run the entire Build Day demo with zero physical
   machines. No venue wifi or hardware dependency.
2. **Open-sim distribution** — anyone with no factory and no fleet can run the
   full demo with one command.
3. **Dev / CI** — exercise nested teams and the eval/approval loop without a
   heterogeneous fleet.

## Run

```bash
# from the repo root (Phoenix server must be running on :4000)
bun run packages/sim-agent/src/cli.ts sim --scenario factory-defect

# unattended (auto-trigger + auto-approve) — backup / CI mode
bun run packages/sim-agent/src/cli.ts sim --scenario factory-defect --auto

# against a remote / Tailscale server, with auth
bun run packages/sim-agent/src/cli.ts sim \
  --scenario factory-defect \
  --server ws://100.x.y.z:4000 \
  --token "$OAH_SECRET"
```

The server prints its auto-generated `OAH_SECRET` on first start. Pass it via
`--token` or `$OAH_SECRET`. Open the dashboard URL the runner prints to watch the
fan-out live.

### Options

| Flag | Default | Meaning |
|------|---------|---------|
| `--scenario <ref>` | — (required) | bundled name (`factory-defect`) or path to a `.yaml`/`.json` |
| `--server <url>` | `$STATE_SERVER` or `ws://localhost:4000` | Phoenix server |
| `--work-key <wk>` | new key created | join an existing Work Key |
| `--token <secret>` | `$OAH_SECRET` | Bearer / WS auth token |
| `--auto` | off | non-interactive: auto-trigger and auto-approve |

## Scenario format

Declarative and deterministic — the same file produces the same on-stage output
every run. See [`scenarios/factory-defect.yaml`](./scenarios/factory-defect.yaml).

```yaml
name: factory-defect
fleet:
  - { name: "executor@pi-cam", role: executor, latency_ms: 200, caps: [camera, gpio] }
  - { name: "builder@gpu-sim", role: builder,  latency_ms: 800, caps: [nvidia-gpu, vision] }
  - { name: "analyst@mac-sim", role: analyst,  latency_ms: 400, caps: [genealogy] }
events:
  - trigger: defect_injected
    lot: "A-2026-1031"
    fanout:                       # simultaneous task.assign to each worker
      - { to: "executor@pi-cam", emits: { defect_suspect: true } }
      - { to: "builder@gpu-sim", emits: { vision_score: 0.88 } }
      - { to: "analyst@mac-sim", emits: { shared_material_lot: "R-882" } }
    suggest:                      # fan-in → cached golden suggestion (HITL gate)
      defect_type: "외관/스크래치"
      root_cause: "원자재 LOT R-882"
      confidence: 0.82
      action: quarantine
```

`latency_ms` produces the staggered-but-concurrent "all my machines spring to
life" effect. `suggest` is surfaced as a real `task.approval_requested` event;
approval writes a real `state.update` (where a physical Pi LED/buzzer fires).

## Real / sim mix

Because sim workers are indistinguishable on the bus, you can run a real Pi
camera as one node and simulate the rest — keep the physical "wow" while
removing the risk. Start the real `agent-daemon` for the physical node and a
`--scenario` that fans out only to the simulated names.
