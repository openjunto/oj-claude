#!/usr/bin/env bash
#
# oj-helper-hook-test.sh — fixture harness for oj-helper SessionStart
# hook surface: `conductor-inject` and `migrate-legacy`.
#
# SCOPE: Locks the contract behavior of the two SessionStart-era
# subcommands so future regressions (path resolution drift, JSON shape
# changes, sentinel write order, lock-handling slips) fail loudly.
#
# Scenarios (conductor-inject):
#   S1 — positive: CONDUCTOR.md present → valid JSON, body matches
#        file contents byte-for-byte, exit 0.
#   S2 — graceful-degradation: no CONDUCTOR.md at resolved path →
#        stable stderr warning + empty additionalContext + exit 0.
#   S3 — adversarial content: CONDUCTOR.md contains shell metacharacters
#        ($VAR, backticks, quotes, newline) → bytes pass through.
#   S4 — empty CONDUCTOR.md → valid JSON, empty additionalContext, no
#        stderr warning (legitimate state).
#   S5 — jq missing (FALSIFIER): PATH stripped → actionable stderr
#        error + hardcoded empty-JSON envelope + exit 0.
#   S6 — script-relative fallback: CLAUDE_PLUGIN_ROOT unset, but
#        CONDUCTOR.md sits at $(dirname oj-helper)/../CONDUCTOR.md
#        → resolves and injects.
#
# Scenarios (migrate-legacy) — added in BL-025-j Commit 2:
#   S7  — first-run + legacy detected: both sentinels written,
#         migration_source=makefile-era, advisory + log emitted.
#   S8  — first-run + clean install: both sentinels written silently,
#         migration_source=clean-install, no advisory, no log.
#   S9  — backup-only sentinel (FALSIFIER): pre-existing backup but
#         no data-dir sentinel → migration does NOT re-fire; marker
#         observable in stdout/stderr.
#   S10 — both sentinels present: no-op, exit 0, silent (or single
#         "already migrated" line).
#   S11 — CLAUDE_PLUGIN_DATA unset: backup written, data-dir skipped,
#         exit 0.
#
# Scenarios (hook-chain + stale-lock) — added in BL-025-j Phase 4:
#   S12 — hook-chain integration: read SessionStart commands from
#         hooks.json via jq, invoke EACH in sequence, assert
#         conductor-inject emits valid JSON AND migrate-legacy writes
#         sentinels (proves wiring, not just per-subcommand contract).
#   S13 — stale-lock recovery: pre-stage a .migration.lock directory
#         with an obviously-stale mtime (5 minutes ago), invoke
#         migrate-legacy, assert sentinels are written + exit 0
#         (FALSIFIER regression guard for auto-fire scenario).
#
# Test isolation: each scenario builds a private tempdir T and
# rebinds HOME, CLAUDE_PLUGIN_ROOT, CLAUDE_PLUGIN_DATA, and
# XDG_CONFIG_HOME beneath it. Cleanup is a SINGLE-ARG EXIT trap
# (`trap 'rm -rf "$T"' EXIT`) per the 2026-05-08 BL-025-e.2 lesson.
#
# Exit codes:
#   0 — all scenarios pass
#   1 — at least one scenario failed
#   2 — driver error (oj-helper missing/non-executable, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OJ_HELPER="${SCRIPT_DIR}/../../bin/oj-helper"
CONTRACTS_SH="${SCRIPT_DIR}/../../bin/lib/contracts.sh"

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

[ -x "${OJ_HELPER}" ] || { echo -e "${RED}ERROR${NC} oj-helper not executable: ${OJ_HELPER}" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo -e "${RED}ERROR${NC} jq required to run this harness (assertions parse JSON)." >&2; exit 2; }

# Source the pinned-string contracts so S2 asserts against the shared
# value instead of a literal duplicated here (BL-025-k F5). Tests source
# contracts.sh directly — they do NOT source oj-helper (which would
# execute its dispatcher side effects). Per F10.
[ -r "${CONTRACTS_SH}" ] || { echo -e "${RED}ERROR${NC} contracts library missing: ${CONTRACTS_SH}" >&2; exit 2; }
# shellcheck source=../../bin/lib/contracts.sh
source "${CONTRACTS_SH}"

PASS_COUNT=0
FAIL_COUNT=0

assert_one() {
    local label="$1"; local cond="$2"; local detail="${3:-}"
    if [ "${cond}" = "ok" ]; then
        echo -e "${GREEN}PASS${NC} ${label}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${RED}FAIL${NC} ${label}"
        [ -n "${detail}" ] && echo -e "${CYAN}      ${detail}${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Run oj-helper with isolated env beneath a tempdir. Captures stdout,
# stderr, and exit code into named output files inside T.
#   $1 = T (tempdir)
#   $2 = subcommand (conductor-inject | migrate-legacy)
# Reads remaining args as oj-helper subcommand args.
run_isolated() {
    local T="$1"; shift
    local subcmd="$1"; shift
    local rc=0
    HOME="$T/home" \
    CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT_OVERRIDE:-$T/plugin}" \
    CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA_OVERRIDE:-$T/data}" \
    XDG_CONFIG_HOME="$T/xdg" \
    "${OJ_HELPER}" "${subcmd}" "$@" >"$T/stdout" 2>"$T/stderr" || rc=$?
    echo "${rc}" > "$T/exit"
}

# ────────────────────────────────────────────────────────────────────
# S1 — positive: synthetic CONDUCTOR.md round-trips byte-identical
# ────────────────────────────────────────────────────────────────────
scenario_s1_positive() {
    local T; T=$(mktemp -d -t oj-hook-s1-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/home" "$T/plugin" "$T/data" "$T/xdg"
    printf '# Conductor\n\nTest content.\n' > "$T/plugin/CONDUCTOR.md"
    printf '7.8.9\n' > "$T/plugin/VERSION"

    run_isolated "$T" conductor-inject

    local rc; rc=$(cat "$T/exit")
    if [ "$rc" != "0" ]; then
        assert_one "S1 conductor-inject positive: exit code 0" "fail" "exit=$rc stderr=$(cat "$T/stderr")"
        rm -rf "$T"; trap - EXIT; return
    fi
    assert_one "S1 conductor-inject positive: exit code 0" "ok"

    # JSON validity + shape
    if jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' "$T/stdout" >/dev/null 2>&1; then
        assert_one "S1 conductor-inject positive: hookEventName == SessionStart" "ok"
    else
        assert_one "S1 conductor-inject positive: hookEventName == SessionStart" "fail" "stdout=$(cat "$T/stdout")"
    fi

    # additionalContext must equal CONDUCTOR.md byte-for-byte
    local expected actual
    expected=$(cat "$T/plugin/CONDUCTOR.md")
    actual=$(jq -r '.hookSpecificOutput.additionalContext' "$T/stdout")
    if [ "$expected" = "$actual" ]; then
        assert_one "S1 conductor-inject positive: additionalContext byte-identical to CONDUCTOR.md" "ok"
    else
        assert_one "S1 conductor-inject positive: additionalContext byte-identical to CONDUCTOR.md" "fail" "expected=[$expected] actual=[$actual]"
    fi

    # SessionStart version banner: exact text with the resolved plugin
    # version interpolated, on stderr only (must not appear in stdout).
    if grep -qF "OpenJunto v7.8.9 active — OpenJunto coordination system" "$T/stderr"; then
        assert_one "S1 conductor-inject positive: version banner on stderr with resolved version" "ok"
    else
        assert_one "S1 conductor-inject positive: version banner on stderr with resolved version" "fail" "stderr=$(cat "$T/stderr")"
    fi
    if ! grep -qF "active — OpenJunto coordination system" "$T/stdout"; then
        assert_one "S1 conductor-inject positive: banner does not leak into stdout" "ok"
    else
        assert_one "S1 conductor-inject positive: banner does not leak into stdout" "fail" "stdout=$(cat "$T/stdout")"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S2 — missing CONDUCTOR.md: stable warning + empty body + exit 0
# ────────────────────────────────────────────────────────────────────
scenario_s2_missing() {
    local T; T=$(mktemp -d -t oj-hook-s2-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/home" "$T/plugin" "$T/data" "$T/xdg"
    # NO CONDUCTOR.md placed under $T/plugin

    run_isolated "$T" conductor-inject

    local rc; rc=$(cat "$T/exit")
    if [ "$rc" = "0" ]; then
        assert_one "S2 missing-CONDUCTOR: exit code 0 (graceful)" "ok"
    else
        assert_one "S2 missing-CONDUCTOR: exit code 0 (graceful)" "fail" "exit=$rc"
    fi

    # Stable stderr warning string — sourced from bin/lib/contracts.sh
    # so updates flow through a single edit. /oj:health-check and the
    # structural-validator C4 drift canary pin the same constant.
    if grep -qF "${OJ_STDERR_CONDUCTOR_MISSING}" "$T/stderr"; then
        assert_one "S2 missing-CONDUCTOR: stable stderr warning present (\$OJ_STDERR_CONDUCTOR_MISSING)" "ok"
    else
        assert_one "S2 missing-CONDUCTOR: stable stderr warning present (\$OJ_STDERR_CONDUCTOR_MISSING)" "fail" "stderr=$(cat "$T/stderr")"
    fi

    # Empty additionalContext + valid JSON
    if jq -e '.hookSpecificOutput.additionalContext == ""' "$T/stdout" >/dev/null 2>&1; then
        assert_one "S2 missing-CONDUCTOR: additionalContext == \"\"" "ok"
    else
        assert_one "S2 missing-CONDUCTOR: additionalContext == \"\"" "fail" "stdout=$(cat "$T/stdout")"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S3 — adversarial content: shell metachars survive byte-identical
# ────────────────────────────────────────────────────────────────────
scenario_s3_adversarial() {
    local T; T=$(mktemp -d -t oj-hook-s3-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/home" "$T/plugin" "$T/data" "$T/xdg"

    # Content with $VAR_NOT_SET, backticks, double-quotes, and a newline.
    # Use printf so the heredoc-quoting question doesn't sneak in.
    printf 'Variable: $VAR_NOT_SET\nBacktick: `whoami`\nQuote: "quoted"\nLine 4\n' \
        > "$T/plugin/CONDUCTOR.md"

    run_isolated "$T" conductor-inject

    local rc; rc=$(cat "$T/exit")
    [ "$rc" = "0" ] || { assert_one "S3 adversarial content: exit 0" "fail" "exit=$rc"; rm -rf "$T"; trap - EXIT; return; }

    local expected actual
    expected=$(cat "$T/plugin/CONDUCTOR.md")
    actual=$(jq -r '.hookSpecificOutput.additionalContext' "$T/stdout")
    if [ "$expected" = "$actual" ]; then
        assert_one "S3 adversarial content: bytes pass through (no shell expansion)" "ok"
    else
        assert_one "S3 adversarial content: bytes pass through (no shell expansion)" "fail" "expected=[$expected] actual=[$actual]"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S4 — empty CONDUCTOR.md: valid JSON, empty body, version banner on
# stderr, but NO CONDUCTOR advisory (empty file is a legitimate
# adopter "protocol intentionally disabled" state — we must not warn
# about it). The SessionStart version banner still fires on every
# conductor-inject path, so stderr is NOT empty here; the contract is
# specifically the absence of the CONDUCTOR-missing/disabled warning.
# ────────────────────────────────────────────────────────────────────
scenario_s4_empty() {
    local T; T=$(mktemp -d -t oj-hook-s4-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/home" "$T/plugin" "$T/data" "$T/xdg"
    : > "$T/plugin/CONDUCTOR.md"  # zero-byte file

    run_isolated "$T" conductor-inject

    local rc; rc=$(cat "$T/exit")
    [ "$rc" = "0" ] || { assert_one "S4 empty CONDUCTOR: exit 0" "fail" "exit=$rc"; rm -rf "$T"; trap - EXIT; return; }

    if jq -e '.hookSpecificOutput.additionalContext == ""' "$T/stdout" >/dev/null 2>&1; then
        assert_one "S4 empty CONDUCTOR: additionalContext == \"\"" "ok"
    else
        assert_one "S4 empty CONDUCTOR: additionalContext == \"\"" "fail" "stdout=$(cat "$T/stdout")"
    fi

    # Version banner fires on every conductor-inject path (SessionStart
    # active confirmation) — assert it is present on stderr.
    if grep -qF "active — OpenJunto coordination system" "$T/stderr"; then
        assert_one "S4 empty CONDUCTOR: version banner present on stderr" "ok"
    else
        assert_one "S4 empty CONDUCTOR: version banner present on stderr" "fail" "stderr=$(cat "$T/stderr")"
    fi

    # No CONDUCTOR advisory — empty file is a legitimate "disabled"
    # state, so the CONDUCTOR-missing warning must NOT appear. (The
    # banner above is an active signal, not a warning.)
    if ! grep -qF "${OJ_STDERR_CONDUCTOR_MISSING}" "$T/stderr"; then
        assert_one "S4 empty CONDUCTOR: no CONDUCTOR advisory (disabled state stays silent)" "ok"
    else
        assert_one "S4 empty CONDUCTOR: no CONDUCTOR advisory (disabled state stays silent)" "fail" "stderr=$(cat "$T/stderr")"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S5 — FALSIFIER: jq missing → actionable error + hardcoded empty JSON
# ────────────────────────────────────────────────────────────────────
scenario_s5_no_jq() {
    local T; T=$(mktemp -d -t oj-hook-s5-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/home" "$T/plugin" "$T/data" "$T/xdg" "$T/bin"

    # Build an isolated PATH containing ONLY a curated set of POSIX
    # binaries that oj-helper's conductor-inject code path needs.
    # CRITICALLY: jq is NOT symlinked in, so `command -v jq` returns
    # non-zero inside the helper and we exercise the missing-jq
    # branch regardless of host OS or jq install location.
    local b
    for b in bash sh cat dirname readlink grep head mkdir rm touch sed env; do
        if command -v "$b" >/dev/null 2>&1; then
            ln -sf "$(command -v "$b")" "$T/bin/$b"
        fi
    done

    local rc=0
    HOME="$T/home" \
    CLAUDE_PLUGIN_ROOT="$T/plugin" \
    CLAUDE_PLUGIN_DATA="$T/data" \
    XDG_CONFIG_HOME="$T/xdg" \
    PATH="$T/bin" \
    "${OJ_HELPER}" conductor-inject >"$T/stdout" 2>"$T/stderr" || rc=$?

    if [ "$rc" = "0" ]; then
        assert_one "S5 no-jq FALSIFIER: exit code 0" "ok"
    else
        assert_one "S5 no-jq FALSIFIER: exit code 0" "fail" "exit=$rc stderr=$(cat "$T/stderr")"
    fi

    if grep -qF "jq required" "$T/stderr"; then
        assert_one "S5 no-jq FALSIFIER: stderr contains 'jq required'" "ok"
    else
        assert_one "S5 no-jq FALSIFIER: stderr contains 'jq required'" "fail" "stderr=$(cat "$T/stderr")"
    fi

    # Hardcoded empty-JSON envelope (single line, no jq pretty-print)
    if grep -qF '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":""}}' "$T/stdout"; then
        assert_one "S5 no-jq FALSIFIER: hardcoded empty-JSON envelope on stdout" "ok"
    else
        assert_one "S5 no-jq FALSIFIER: hardcoded empty-JSON envelope on stdout" "fail" "stdout=$(cat "$T/stdout")"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S6 — script-relative fallback: CLAUDE_PLUGIN_ROOT unset
# ────────────────────────────────────────────────────────────────────
# Place a CONDUCTOR.md at $(dirname oj-helper)/../CONDUCTOR.md inside
# the tempdir, copy oj-helper next to it, then invoke without
# CLAUDE_PLUGIN_ROOT set. The script-relative fallback resolves the
# path via dirname/readlink and finds the planted CONDUCTOR.md.
# ────────────────────────────────────────────────────────────────────
scenario_s6_script_relative_fallback() {
    local T; T=$(mktemp -d -t oj-hook-s6-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/plugin/bin/lib" "$T/home" "$T/data" "$T/xdg"

    # Layout: $T/plugin/bin/oj-helper, $T/plugin/bin/lib/contracts.sh,
    # $T/plugin/CONDUCTOR.md. contracts.sh must travel WITH oj-helper —
    # the helper sources it at startup and dies if missing (BL-025-k F5).
    cp "${OJ_HELPER}" "$T/plugin/bin/oj-helper"
    cp "${CONTRACTS_SH}" "$T/plugin/bin/lib/contracts.sh"
    chmod +x "$T/plugin/bin/oj-helper"
    printf 'fallback content\n' > "$T/plugin/CONDUCTOR.md"

    local rc=0
    # Deliberately do NOT set CLAUDE_PLUGIN_ROOT — exercise the fallback.
    HOME="$T/home" \
    CLAUDE_PLUGIN_DATA="$T/data" \
    XDG_CONFIG_HOME="$T/xdg" \
    env -u CLAUDE_PLUGIN_ROOT \
      "$T/plugin/bin/oj-helper" conductor-inject >"$T/stdout" 2>"$T/stderr" || rc=$?

    if [ "$rc" = "0" ]; then
        assert_one "S6 script-relative fallback: exit code 0" "ok"
    else
        assert_one "S6 script-relative fallback: exit code 0" "fail" "exit=$rc stderr=$(cat "$T/stderr")"
        rm -rf "$T"; trap - EXIT; return
    fi

    if jq -e '.hookSpecificOutput.additionalContext == "fallback content\n"' "$T/stdout" >/dev/null 2>&1; then
        assert_one "S6 script-relative fallback: additionalContext resolved from ../CONDUCTOR.md" "ok"
    else
        local actual
        actual=$(jq -r '.hookSpecificOutput.additionalContext' "$T/stdout" 2>/dev/null || cat "$T/stdout")
        assert_one "S6 script-relative fallback: additionalContext resolved from ../CONDUCTOR.md" "fail" "got=[$actual]"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S7 — migrate-legacy first-run + legacy detected
# ────────────────────────────────────────────────────────────────────
scenario_s7_migrate_first_run_legacy() {
    local T; T=$(mktemp -d -t oj-hook-s7-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/home/.claude" "$T/plugin" "$T/data" "$T/xdg"
    cp "${SCRIPT_DIR}/../../VERSION" "$T/plugin/VERSION"
    # Plant legacy artifact
    printf 'v0.legacy\n' > "$T/home/.claude/.oj-version"

    run_isolated "$T" migrate-legacy

    local rc; rc=$(cat "$T/exit")
    [ "$rc" = "0" ] || { assert_one "S7 migrate-legacy first-run: exit 0" "fail" "exit=$rc stderr=$(cat "$T/stderr")"; rm -rf "$T"; trap - EXIT; return; }

    if [ -f "$T/xdg/oj/.migration-done" ]; then
        assert_one "S7 migrate-legacy first-run: backup sentinel exists" "ok"
    else
        assert_one "S7 migrate-legacy first-run: backup sentinel exists" "fail"
    fi

    if [ -f "$T/data/.migration-done" ]; then
        assert_one "S7 migrate-legacy first-run: data-dir sentinel exists" "ok"
    else
        assert_one "S7 migrate-legacy first-run: data-dir sentinel exists" "fail"
    fi

    # Sentinel content sanity: must include plugin_version=
    local v="0.0.1"
    [ -r "$T/plugin/VERSION" ] && v=$(head -1 "$T/plugin/VERSION" | tr -d '[:space:]')
    if grep -qF "plugin_version=$v" "$T/xdg/oj/.migration-done" 2>/dev/null; then
        assert_one "S7 migrate-legacy first-run: sentinel records plugin_version" "ok"
    else
        assert_one "S7 migrate-legacy first-run: sentinel records plugin_version" "fail" "backup=$(cat "$T/xdg/oj/.migration-done" 2>/dev/null)"
    fi

    if grep -qF "migration_source=makefile-era" "$T/xdg/oj/.migration-done" 2>/dev/null; then
        assert_one "S7 migrate-legacy first-run: migration_source=makefile-era" "ok"
    else
        assert_one "S7 migrate-legacy first-run: migration_source=makefile-era" "fail"
    fi

    if grep -qF "[oj] Legacy install detected" "$T/stderr"; then
        assert_one "S7 migrate-legacy first-run: stderr advisory present" "ok"
    else
        assert_one "S7 migrate-legacy first-run: stderr advisory present" "fail" "stderr=$(cat "$T/stderr")"
    fi

    # Log file must exist with at least one detection line
    local logs
    logs=$(ls "$T/xdg/oj/"migration-*.log 2>/dev/null | head -1)
    if [ -n "$logs" ] && grep -qF "legacy_version_file:" "$logs" 2>/dev/null; then
        assert_one "S7 migrate-legacy first-run: log file captures findings" "ok"
    else
        assert_one "S7 migrate-legacy first-run: log file captures findings" "fail" "logs=$logs"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S8 — migrate-legacy first-run + clean install (silent)
# ────────────────────────────────────────────────────────────────────
scenario_s8_migrate_first_run_clean() {
    local T; T=$(mktemp -d -t oj-hook-s8-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/home" "$T/plugin" "$T/data" "$T/xdg"
    cp "${SCRIPT_DIR}/../../VERSION" "$T/plugin/VERSION"
    # No legacy artifacts planted

    run_isolated "$T" migrate-legacy

    local rc; rc=$(cat "$T/exit")
    [ "$rc" = "0" ] || { assert_one "S8 migrate-legacy clean: exit 0" "fail" "exit=$rc"; rm -rf "$T"; trap - EXIT; return; }

    if [ -f "$T/xdg/oj/.migration-done" ] && [ -f "$T/data/.migration-done" ]; then
        assert_one "S8 migrate-legacy clean: both sentinels written" "ok"
    else
        assert_one "S8 migrate-legacy clean: both sentinels written" "fail"
    fi

    if grep -qF "migration_source=clean-install" "$T/xdg/oj/.migration-done" 2>/dev/null; then
        assert_one "S8 migrate-legacy clean: migration_source=clean-install" "ok"
    else
        assert_one "S8 migrate-legacy clean: migration_source=clean-install" "fail" "backup=$(cat "$T/xdg/oj/.migration-done" 2>/dev/null)"
    fi

    # No advisory line, no log file (silence is the contract)
    if ! grep -qF "Legacy install detected" "$T/stderr" 2>/dev/null; then
        assert_one "S8 migrate-legacy clean: stderr contains no advisory" "ok"
    else
        assert_one "S8 migrate-legacy clean: stderr contains no advisory" "fail" "stderr=$(cat "$T/stderr")"
    fi

    local logcount
    # `ls ... 2>/dev/null` returns 1 on no match; isolate from `set -e`/pipefail.
    logcount=$( { ls "$T/xdg/oj/"migration-*.log 2>/dev/null || true; } | wc -l | tr -d '[:space:]' )
    if [ "$logcount" = "0" ]; then
        assert_one "S8 migrate-legacy clean: no log file written" "ok"
    else
        assert_one "S8 migrate-legacy clean: no log file written" "fail" "logcount=$logcount"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S9 — FALSIFIER: backup-only sentinel → no re-fire (load-bearing)
# ────────────────────────────────────────────────────────────────────
scenario_s9_migrate_backup_only() {
    local T; T=$(mktemp -d -t oj-hook-s9-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/home/.claude" "$T/plugin" "$T/data" "$T/xdg/oj"
    cp "${SCRIPT_DIR}/../../VERSION" "$T/plugin/VERSION"

    # Plant the backup sentinel with a recognizable origin marker.
    # Also plant a legacy artifact — this is the FALSIFIER: if the
    # sentinel logic were buggy and re-fired detection, the
    # makefile-era source label would overwrite our marker.
    printf 'schema_version=1\nplugin_version=0.0.0-PRESEEDED\nmigrated_at=2026-01-01T00:00:00Z\nmigration_source=clean-install\n' \
        > "$T/xdg/oj/.migration-done"
    printf 'v0.legacy\n' > "$T/home/.claude/.oj-version"

    run_isolated "$T" migrate-legacy

    local rc; rc=$(cat "$T/exit")
    [ "$rc" = "0" ] || { assert_one "S9 backup-only FALSIFIER: exit 0" "fail" "exit=$rc"; rm -rf "$T"; trap - EXIT; return; }

    # Marker observable in stdout or stderr
    if grep -qF "already complete (backup sentinel found)" "$T/stderr" "$T/stdout" 2>/dev/null; then
        assert_one "S9 backup-only FALSIFIER: self-heal marker present" "ok"
    else
        assert_one "S9 backup-only FALSIFIER: self-heal marker present" "fail" "stderr=$(cat "$T/stderr") stdout=$(cat "$T/stdout")"
    fi

    # Detection MUST NOT have re-fired: the backup retains its
    # preseeded version + source, NOT the live VERSION + makefile-era.
    if grep -qF "plugin_version=0.0.0-PRESEEDED" "$T/xdg/oj/.migration-done" 2>/dev/null; then
        assert_one "S9 backup-only FALSIFIER: backup NOT overwritten (detection did not re-fire)" "ok"
    else
        assert_one "S9 backup-only FALSIFIER: backup NOT overwritten (detection did not re-fire)" "fail" "backup=$(cat "$T/xdg/oj/.migration-done" 2>/dev/null)"
    fi

    # No log file from re-fired detection
    local logcount
    # `ls ... 2>/dev/null` returns 1 on no match; isolate from `set -e`/pipefail.
    logcount=$( { ls "$T/xdg/oj/"migration-*.log 2>/dev/null || true; } | wc -l | tr -d '[:space:]' )
    if [ "$logcount" = "0" ]; then
        assert_one "S9 backup-only FALSIFIER: no migration log written" "ok"
    else
        assert_one "S9 backup-only FALSIFIER: no migration log written" "fail" "logcount=$logcount"
    fi

    # Self-healing: data-dir sentinel re-created from backup
    if [ -f "$T/data/.migration-done" ] && grep -qF "plugin_version=0.0.0-PRESEEDED" "$T/data/.migration-done" 2>/dev/null; then
        assert_one "S9 backup-only FALSIFIER: data-dir sentinel self-healed from backup" "ok"
    else
        assert_one "S9 backup-only FALSIFIER: data-dir sentinel self-healed from backup" "fail" "data=$(cat "$T/data/.migration-done" 2>/dev/null)"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S10 — both sentinels present → silent no-op
# ────────────────────────────────────────────────────────────────────
scenario_s10_migrate_both_present() {
    local T; T=$(mktemp -d -t oj-hook-s10-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/home" "$T/plugin" "$T/data" "$T/xdg/oj"
    cp "${SCRIPT_DIR}/../../VERSION" "$T/plugin/VERSION"

    printf 'schema_version=1\nplugin_version=0.0.1\nmigrated_at=2026-01-01T00:00:00Z\nmigration_source=clean-install\n' \
        > "$T/xdg/oj/.migration-done"
    cp "$T/xdg/oj/.migration-done" "$T/data/.migration-done"
    cp "$T/xdg/oj/.migration-done" "$T/expected"

    run_isolated "$T" migrate-legacy

    local rc; rc=$(cat "$T/exit")
    if [ "$rc" = "0" ]; then
        assert_one "S10 both-present no-op: exit 0" "ok"
    else
        assert_one "S10 both-present no-op: exit 0" "fail" "exit=$rc stderr=$(cat "$T/stderr")"
    fi

    # Backup content byte-for-byte unchanged. Use diff so trailing
    # newlines compare correctly (command-sub strips them).
    if diff -q "$T/expected" "$T/xdg/oj/.migration-done" >/dev/null 2>&1; then
        assert_one "S10 both-present no-op: backup sentinel unchanged" "ok"
    else
        assert_one "S10 both-present no-op: backup sentinel unchanged" "fail" "diff: $(diff "$T/expected" "$T/xdg/oj/.migration-done" 2>&1)"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S11 — CLAUDE_PLUGIN_DATA unset: backup written, data-dir skipped
# ────────────────────────────────────────────────────────────────────
scenario_s11_migrate_no_data_dir() {
    local T; T=$(mktemp -d -t oj-hook-s11-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/home" "$T/plugin" "$T/xdg"
    cp "${SCRIPT_DIR}/../../VERSION" "$T/plugin/VERSION"

    local rc=0
    HOME="$T/home" \
    CLAUDE_PLUGIN_ROOT="$T/plugin" \
    XDG_CONFIG_HOME="$T/xdg" \
    env -u CLAUDE_PLUGIN_DATA \
      "${OJ_HELPER}" migrate-legacy >"$T/stdout" 2>"$T/stderr" || rc=$?

    if [ "$rc" = "0" ]; then
        assert_one "S11 no-data-dir: exit 0" "ok"
    else
        assert_one "S11 no-data-dir: exit 0" "fail" "exit=$rc stderr=$(cat "$T/stderr")"
        rm -rf "$T"; trap - EXIT; return
    fi

    if [ -f "$T/xdg/oj/.migration-done" ]; then
        assert_one "S11 no-data-dir: backup sentinel written" "ok"
    else
        assert_one "S11 no-data-dir: backup sentinel written" "fail"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S12 — hook-chain integration: walk SessionStart commands from
#       hooks.json and invoke each as Claude Code would on session
#       start. Asserts conductor-inject emits valid JSON with the
#       CONDUCTOR.md body AND migrate-legacy writes both sentinels.
# ────────────────────────────────────────────────────────────────────
scenario_s12_hook_chain_integration() {
    local T; T=$(mktemp -d -t oj-hook-s12-XXXXXX); trap 'rm -rf "$T"' EXIT
    local plugin_root="${SCRIPT_DIR}/../.."
    local hooks_json="${plugin_root}/hooks/hooks.json"

    mkdir -p "$T/home" "$T/plugin/bin/lib" "$T/data" "$T/xdg"

    # Mirror the plugin layout: copy oj-helper, contracts.sh, VERSION,
    # and plant a synthetic CONDUCTOR.md so conductor-inject has content
    # to emit. contracts.sh travels WITH oj-helper (BL-025-k F5 — helper
    # sources it at startup; die-on-fail).
    cp "${OJ_HELPER}" "$T/plugin/bin/oj-helper"
    cp "${CONTRACTS_SH}" "$T/plugin/bin/lib/contracts.sh"
    chmod +x "$T/plugin/bin/oj-helper"
    cp "${plugin_root}/VERSION" "$T/plugin/VERSION"
    printf '# Synthetic CONDUCTOR\n\nHook-chain integration test.\n' > "$T/plugin/CONDUCTOR.md"

    if [ ! -r "$hooks_json" ]; then
        assert_one "S12 hook-chain: hooks.json readable" "fail" "missing=$hooks_json"
        rm -rf "$T"; trap - EXIT; return
    fi
    assert_one "S12 hook-chain: hooks.json readable" "ok"

    # Validate hooks.json is valid JSON.
    if ! jq -e . "$hooks_json" >/dev/null 2>&1; then
        assert_one "S12 hook-chain: hooks.json is valid JSON" "fail"
        rm -rf "$T"; trap - EXIT; return
    fi
    assert_one "S12 hook-chain: hooks.json is valid JSON" "ok"

    # Extract SessionStart commands. Each comes through with the literal
    # ${CLAUDE_PLUGIN_ROOT} placeholder — substitute our tempdir-plugin
    # path before invocation to simulate the plugin host's expansion.
    local -a commands=()
    while IFS= read -r cmd; do
        # Substitute the plugin-root placeholder. Claude Code does this
        # at hook-invocation time; we mirror that here.
        cmd="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$T/plugin}"
        commands+=("$cmd")
    done < <(jq -r '.hooks.SessionStart[]?.hooks[]?.command // empty' "$hooks_json")

    if [ "${#commands[@]}" -ge 2 ]; then
        assert_one "S12 hook-chain: SessionStart has >=2 handler commands" "ok"
    else
        assert_one "S12 hook-chain: SessionStart has >=2 handler commands" "fail" "count=${#commands[@]}"
        rm -rf "$T"; trap - EXIT; return
    fi

    # Invoke each command in sequence; capture per-command stdout/stderr.
    local i=0
    local conductor_output=""
    local migrate_stderr=""
    for cmd in "${commands[@]}"; do
        local out_file="$T/cmd${i}.stdout"
        local err_file="$T/cmd${i}.stderr"
        local rc=0
        HOME="$T/home" \
        CLAUDE_PLUGIN_ROOT="$T/plugin" \
        CLAUDE_PLUGIN_DATA="$T/data" \
        XDG_CONFIG_HOME="$T/xdg" \
          bash -c "$cmd" >"$out_file" 2>"$err_file" || rc=$?
        if [ "$rc" != "0" ]; then
            assert_one "S12 hook-chain: cmd[$i] exit 0" "fail" "rc=$rc cmd=$cmd err=$(cat "$err_file")"
            rm -rf "$T"; trap - EXIT; return
        fi
        # Identify which subcommand we just ran for downstream assertions.
        case "$cmd" in
            *conductor-inject*) conductor_output="$out_file" ;;
            *migrate-legacy*)   migrate_stderr="$err_file" ;;
        esac
        i=$((i + 1))
    done
    assert_one "S12 hook-chain: all handler commands exit 0" "ok"

    # conductor-inject emitted valid JSON with the CONDUCTOR.md body.
    if [ -n "$conductor_output" ] \
       && jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' "$conductor_output" >/dev/null 2>&1 \
       && [ "$(jq -r '.hookSpecificOutput.additionalContext' "$conductor_output")" = "$(cat "$T/plugin/CONDUCTOR.md")" ]; then
        assert_one "S12 hook-chain: conductor-inject emits valid JSON with CONDUCTOR body" "ok"
    else
        assert_one "S12 hook-chain: conductor-inject emits valid JSON with CONDUCTOR body" "fail" "out=$(cat "$conductor_output" 2>/dev/null)"
    fi

    # migrate-legacy wrote both sentinels.
    if [ -f "$T/xdg/oj/.migration-done" ] && [ -f "$T/data/.migration-done" ]; then
        assert_one "S12 hook-chain: migrate-legacy wrote both sentinels" "ok"
    else
        assert_one "S12 hook-chain: migrate-legacy wrote both sentinels" "fail" "xdg=$(ls "$T/xdg/oj/" 2>/dev/null) data=$(ls "$T/data/" 2>/dev/null)"
    fi

    # Second-run idempotency: invoke the migrate-legacy command again
    # and confirm it stays silent (no log, no advisory) and exit 0.
    local second_rc=0
    HOME="$T/home" \
    CLAUDE_PLUGIN_ROOT="$T/plugin" \
    CLAUDE_PLUGIN_DATA="$T/data" \
    XDG_CONFIG_HOME="$T/xdg" \
      bash -c "${commands[1]}" >"$T/second.stdout" 2>"$T/second.stderr" || second_rc=$?
    if [ "$second_rc" = "0" ]; then
        assert_one "S12 hook-chain: migrate-legacy second-run exits 0 (idempotent)" "ok"
    else
        assert_one "S12 hook-chain: migrate-legacy second-run exits 0 (idempotent)" "fail" "rc=$second_rc"
    fi

    rm -rf "$T"; trap - EXIT
}

# ────────────────────────────────────────────────────────────────────
# S13 — FALSIFIER: stale .migration.lock directory must not block
#       migration. Pre-stage a lockdir with mtime 5 minutes ago,
#       invoke migrate-legacy, assert sentinels are written.
# ────────────────────────────────────────────────────────────────────
scenario_s13_stale_lock_recovery() {
    local T; T=$(mktemp -d -t oj-hook-s13-XXXXXX); trap 'rm -rf "$T"' EXIT
    mkdir -p "$T/home" "$T/plugin" "$T/data" "$T/xdg/oj"
    cp "${SCRIPT_DIR}/../../VERSION" "$T/plugin/VERSION"

    # Pre-stage a stale lockdir. Setting mtime 5 minutes in the past
    # via `touch -t YYYYmmddHHMM.SS` — far beyond the 60s threshold.
    # We pin to a deterministic date well in the past so the test
    # remains stable regardless of host clock skew of a few minutes.
    mkdir "$T/xdg/oj/.migration.lock"
    touch -t 202401010000.00 "$T/xdg/oj/.migration.lock"

    run_isolated "$T" migrate-legacy

    local rc; rc=$(cat "$T/exit")
    if [ "$rc" = "0" ]; then
        assert_one "S13 stale-lock recovery: exit 0" "ok"
    else
        assert_one "S13 stale-lock recovery: exit 0" "fail" "exit=$rc stderr=$(cat "$T/stderr")"
        rm -rf "$T"; trap - EXIT; return
    fi

    # Both sentinels written (proves stale lock was reclaimed and
    # migration completed normally).
    if [ -f "$T/xdg/oj/.migration-done" ]; then
        assert_one "S13 stale-lock recovery: backup sentinel written" "ok"
    else
        assert_one "S13 stale-lock recovery: backup sentinel written" "fail"
    fi

    if [ -f "$T/data/.migration-done" ]; then
        assert_one "S13 stale-lock recovery: data-dir sentinel written" "ok"
    else
        assert_one "S13 stale-lock recovery: data-dir sentinel written" "fail"
    fi

    # Lockdir is cleaned up via the EXIT trap inside migrate-legacy
    # (we reclaimed it, then released it).
    if [ ! -e "$T/xdg/oj/.migration.lock" ]; then
        assert_one "S13 stale-lock recovery: lock released after run" "ok"
    else
        assert_one "S13 stale-lock recovery: lock released after run" "fail"
    fi

    rm -rf "$T"; trap - EXIT
}

echo -e "${YELLOW}[INFO]${NC} oj-helper-hook-test"
echo -e "${YELLOW}[INFO]${NC} oj-helper: ${OJ_HELPER}"
echo

scenario_s1_positive
scenario_s2_missing
scenario_s3_adversarial
scenario_s4_empty
scenario_s5_no_jq
scenario_s6_script_relative_fallback
scenario_s7_migrate_first_run_legacy
scenario_s8_migrate_first_run_clean
scenario_s9_migrate_backup_only
scenario_s10_migrate_both_present
scenario_s11_migrate_no_data_dir
scenario_s12_hook_chain_integration
scenario_s13_stale_lock_recovery

echo
echo "================================"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ "${FAIL_COUNT}" -eq 0 ]; then
    echo -e "${GREEN}PASS${NC} oj-helper-hook-test: ${PASS_COUNT}/${TOTAL}"
    echo "================================"
    exit 0
fi
echo -e "${RED}FAIL${NC} oj-helper-hook-test: ${FAIL_COUNT}/${TOTAL} scenario(s) failed"
echo "================================"
exit 1
