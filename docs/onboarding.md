# Onboarding: Your First 10 Minutes with OpenJunto

This guide walks through what to expect right after installation. Read it end-to-end before your first real task.

## 1. Confirm Installation

Start Claude Code:

```bash
claude
```

You should see a banner on stderr before the first prompt:

```
OpenJunto v<version> active — OpenJunto coordination system
```

The banner is printed by the `SessionStart` hook, which fires on session start — startup, resume, `/clear`, or compaction. It does **not** fire on `/reload-plugins` or `/plugin reload`, so if you just reloaded the plugin, start a new session (or `/clear`) to see it. `<version>` comes from the plugin's `VERSION` file.

If you still don't see it on a fresh session, the hook didn't fire. Check that the plugin loaded (`claude --plugin-dir /path/to/oj-claude`, or confirm `oj` appears in `/plugin`). OpenJunto is designed to degrade gracefully — the absence of the banner means the hook didn't run, not that Claude is broken.

## 2. Your First Task

Start with something where multi-perspective review adds obvious value. Paste this:

```
Review this file for security issues: src/auth/token_validator.go
```

### What you should see

1. **Triage declaration.** The Manager opens with an explicit triage: execution model (expect **Moderate**) and a stakeholder list (expect **Product Manager + Distinguished Engineer + Security Engineer**).
2. **Parallel sub-agent spawns.** In Phase 1, you should see Task tool invocations fire in parallel — one per stakeholder. They run concurrently; the Manager does not wait between them.
3. **FINDING / TENSION ledger in synthesis.** Between Phase 1 and Phase 2, the Manager consolidates stakeholder output into a ledger. `FINDING` lines are agreed-upon observations. `TENSION` lines are productive disagreements that get *forwarded* to the implementer — not resolved by the Manager.
4. **STRONGEST OBJECTION per handback.** Every handback includes a STRONGEST OBJECTION field — the best argument *against* that expert's own recommendation. If it reads as boilerplate, call it out.
5. **Dissenting views preserved.** The final synthesis surfaces dissent rather than papering over it. If two stakeholders disagreed, the answer should name the disagreement and say which path was taken and why.

Typical wall-clock for a Moderate-tier task: **4–8 minutes**.

## 3. Understanding Triage

The Manager scores every request against four criteria:

1. Spans multiple technical domains?
2. Regulatory or compliance implications?
3. Could impact production stability?
4. Significant cost or resource commitment?

**Scoring:**

- **0–1 hits** → Simple (inline perspective rotation, no sub-agents)
- **2–3 hits** → Moderate (parallel stakeholder analysis + lead + adversarial review)
- **4 hits** → Complex (coordinator-led team with retrospective)

**Mandatory escalation to Complex:** security vulnerabilities, architecture changes, PCI/regulatory work, production stability risks, irreversible one-way doors.

### You Can Override Triage

If the Manager over-triages a trivial task, push back in plain language:

> "This is a typo fix. Just do it."

The Manager will drop to Simple or apply the change directly. Don't let process weight exceed the blast radius of failure. The override style is natural-language pushback, not syntactic prefixes.

## 4. Stakeholder Selection

Every task gets **Product + Tech** as mandatory stakeholders. Domain signals add more:

| Signal in task | Adds stakeholder |
|---|---|
| Security / compliance | Security Engineer |
| Data modeling / pipelines | Data Architect |
| Infrastructure / CI/CD | DevOps Engineer |
| ML systems / model serving | ML Engineer |
| SLOs / reliability | Site Reliability Engineer |
| Test strategy / quality | Test Engineer |

Full roster and engagement triggers: [`agents/index.md`](../agents/index.md).

## 5. Reading Expert Handbacks

Every expert returns a structured handback. The fields that matter:

- **STATUS** — `Complete` / `Needs Iteration` / `Blocked` / `Escalate`
- **CONFIDENCE** — `High` / `Medium` / `Low`
- **STRONGEST OBJECTION** — the best argument *against* the expert's own recommendation
- **FALSIFIER** — an empirical condition that would break the recommendation in production

**Low confidence is valuable signal, not failure.** A `Low` from a domain expert means "I don't have enough information to stand behind this" — that's useful. For `High` confidence, the reviewer probes with a calibration challenge ("what would drop this to Medium?") to surface where the assumptions live.

Read STRONGEST OBJECTION carefully. It is *not* boilerplate. If it sounds boilerplate, ask the Manager to have the expert genuinely engage it.

## 6. Common Mistakes

- **Over-accepting triage.** The Manager errs on the side of more process. Push back on Simple tasks that got bumped to Moderate for weak reasons.
- **Ignoring STRONGEST OBJECTION.** It's the single highest-signal field in a handback. If you skim past it, you're leaving the whole point of adversarial review on the floor.
- **Expecting instant results.** Moderate tasks take minutes. Complex can take longer. The coordination overhead is the feature.
- **Treating the Manager as an implementer.** The Manager delegates. If you want code written, the Manager spawns an engineer.
- **Skipping the pre-mortem.** On Moderate/Complex, pre-mortem is mandatory. If the Manager skips it, call it out.

## 7. Advanced: Backlog Sprint

For projects with `.claude/BACKLOG.md`, run:

```bash
claude '/run-task'
```

The Manager picks the next item, triages it, delegates to experts, enforces peer review, and marks it done. You can run this repeatedly until the backlog is empty or the Manager escalates.

## 8. Next Steps

- [WHY.md](../WHY.md) — honest tradeoffs and when OpenJunto is (and isn't) worth it
- [CONDUCTOR.md](../CONDUCTOR.md) — the full Manager coordination protocol
- [agents/index.md](../agents/index.md) — expert roster and engagement triggers
- Try `/run-task` on a project with a `.claude/BACKLOG.md`
- Run the same real task through single-agent Claude and through OpenJunto — compare the output
