#!/usr/bin/env bash
# review-ledger.sh — the Codex round ledger: counts Codex review dispatches per
# key, across sessions and worktrees, so round 4+ prompts the user. Warning
# accounting, not enforcement. hooks/codex-cap-gate.py records every Codex
# dispatch; this CLI corrects and inspects the count.
#
#   review-ledger.sh [-C <repo-path>] record <key> <agent> [--id <tool_use_id>] [--id-source payload|generated] [--cap <n>]
#   review-ledger.sh [-C <repo-path>] link <to-key> <from-key>
#   review-ledger.sh [-C <repo-path>] void <tool_use_id> <reason>
#   review-ledger.sh [-C <repo-path>] reset <key> <reason>
#   review-ledger.sh [-C <repo-path>] count <key>
#   review-ledger.sh [-C <repo-path>] show [<key>]
#
# -C names any path inside the checkout (default: the current directory).
# <key> is branch:<name> or plan:<ticket> (a slug if there is no ticket).
#
# record  counts one dispatch by hand (a direct Bash Codex launch the hook
#         cannot see). Prints "<allow|ask> <count-after> <tool_use_id>":
#         allow below --cap (default 3), ask at or above it. Without --id an id
#         gen:cli:<ts>:<hash> is generated (id_source generated). An id already
#         in the key's current generation is not counted again.
# link    copies <from-key>'s current-generation rows into <to-key>'s current
#         generation, skipping ids already there (re-linking is idempotent).
#         A snapshot: run it at the end of the step. Copies keep their origin.
# void    removes every row with <tool_use_id> in every key and generation,
#         linked copies included; exit 1 if no row has it.
# reset   starts a new generation of <key> (count 0) for genuinely new work
#         under a recycled name.
# count   prints the number of rows in <key>'s current generation.
# show    prints <key>'s generation, current rows and history; with no key,
#         one line per key.
# void, reset and link are recorded in the key's history with their reason.
#
# State: <git-common-dir>/review-ledger/, shared by every worktree of a clone.
# One file per key, <enc>.json, where <enc> is the key percent-encoded (every
# UTF-8 byte outside A-Za-z0-9-_.~ becomes %XX, '%' included), so the encoding
# is injective: branch:a/b -> branch%3Aa%2Fb.json. File format (version 1):
#   {"version": 1, "key": "branch:feat/x", "generation": 1,
#    "rows": [{"key": "branch:feat/x", "generation": 1, "tool_use_id": "toolu_..",
#              "id_source": "payload", "agent": "codex-adversary",
#              "ts": "2026-10-22T12:00:00Z", "origin": "plan:PROJ-1",
#              "decision": "allow"}],
#    "events": [{"type": "reset"|"void"|"link", "ts": "...", ...}]}
# origin is the key the dispatch was first recorded under. Rows of older
# generations are kept; count ignores them. Files are replaced by rename from
# a .tmp-*.partial file in the same directory; dotfiles are never keys.
#
# Lock: every writing command holds flock(2) on <dir>/.lock (persistent, one
# per ledger) across read, decide and write; a busy lock is retried for
# REVIEW_LEDGER_LOCK_TIMEOUT seconds (default 10). count and show take no lock.
#
# Exit: 0 ok; 1 usage or refused (bad key, unknown id, not a git repo);
# 2 ledger error (corrupt file, lock, git cannot run). Needs python3 (stdlib).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/review_ledger.py" "$@"
