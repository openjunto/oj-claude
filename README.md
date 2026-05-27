# OpenJunto for Claude Code

A Claude Code configuration that transforms the AI into a coordinated team of 16 expert sub-agents with structured peer review.

## Quickstart

OpenJunto ships as a Claude Code plugin — no build step. Install it from the marketplace inside a Claude Code session:

```
/plugin marketplace add openjunto/oj-claude
/plugin install oj@openjunto
```

Then run `/reload-plugins` (or restart Claude Code). To iterate on the plugin locally without installing it, load the working tree directly:

```bash
git clone https://github.com/openjunto/oj-claude.git
claude --plugin-dir ./oj-claude
```

After reload (or on the next session start), you should see a banner on stderr:

```
OpenJunto v<version> active — OpenJunto coordination system
```

## Usage

OpenJunto activates automatically — just describe the work in plain language.

- `Review this pull request for security issues.`
- `Fix the flaky test in auth_service_test.go.`
- `Evaluate whether we should migrate from REST to gRPC for internal services.`

The Manager handles triage, expert selection, peer review, and quality gates transparently. You do not need to invoke experts by name.

## What's Included

- **16 expert agents** — full + compact profiles in [`agents/`](agents/)
- **Templates** — technical analysis, ADR, retrospective, session state, comms playbook ([`templates/`](templates/))
- **Complexity triage** — Simple / Moderate / Complex tiers with process weight proportional to risk
- **Peer review workflow** — adversarial review by a different domain on all Moderate/Complex work
- **Circuit breakers** — auto-escalate after 3 revision cycles or 2 hours without progress

## How It Works

1. **Triage** — Incoming requests scored against 4 criteria (multi-domain, regulatory, production risk, resource commitment)
2. **Delegation** — Manager spawns domain experts via the Task tool
3. **Review** — A different expert adversarially reviews the work, testing failure modes
4. **Synthesis** — Manager consolidates findings, surfaces dissenting views, hands back to you

## Advanced: Backlog Sprint

For projects with a `.claude/BACKLOG.md`, run:

```bash
claude '/run-task'
```

The Manager picks the next item, delegates to experts, enforces peer review, and marks it done.

## Directory Structure

The plugin tree (loaded by the plugin host from this repo's root):

```
.claude-plugin/
└── plugin.json              # Plugin manifest

CONDUCTOR.md                 # Manager coordination protocol (injected at SessionStart)
agents/                      # 16 full + 16 compact expert profiles
skills/                      # /run-task, /show-backlog, /save-session, /cycle
templates/                   # Structured output formats
reference/                   # Tier-loaded background (workflow, stakeholders, examples)
hooks/
└── hooks.json               # SessionStart + SubagentStart wiring
bin/
└── oj-helper                # Hook dispatcher + backlog helpers
```

Per-project, OpenJunto reads and writes a local `.claude/` directory:

```
.claude/
├── CLAUDE.md                # Project-local protocol overrides (optional)
├── BACKLOG.md               # Project backlog (consumed by /run-task)
├── state/                   # Session state, carry-over notes
└── artifacts/               # Generated deliverables (ADRs, analyses, retrospectives)
```

## Documentation

- [WHY.md](WHY.md) — the problem OpenJunto solves, concrete examples, honest tradeoffs
- [docs/onboarding.md](docs/onboarding.md) — your first 10 minutes after installation
- [CONDUCTOR.md](CONDUCTOR.md) — the full Manager protocol
- [agents/index.md](agents/index.md) — expert roster and engagement triggers
