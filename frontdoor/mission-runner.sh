#!/bin/bash
# THE FRONT DOOR'S ENGINE: the mission is decided by the SEALED ENGINE ENTRY, not by the caller.
#
# The sealed engine entry points at this script instead of the harness binary. It takes the arguments
# the agent built, finds the message, throws away anything in it that tries to choose a mission or to
# prime the runner, puts THIS door's mission line in front, and execs the real engine with everything
# else untouched. A caller can therefore only ask a question: no mission of their choosing and no
# injected priming block, whatever they write in the body.
#
# ONE SCRIPT SERVES EVERY DOOR. The mission is not written here — the agent reads it from the sealed
# entry and hands it over as HEIA_FRONTDOOR_MISSION when it spawns this script. Provisioning writes
# this file verbatim and seals a different mission per door; nothing in here is per-install.
#
# THE TWO ARGUMENT SHAPES the agent builds (sealed in the engine entry):
#     new turn : -p <message> --output-format ...
#     resume   : -p --resume <sessionId> <message> --output-format ...
# so the message is the argument after -p, unless that is --resume, in which case it is two later.
#
# THIS FILE MUST LIVE OUTSIDE THE IDENTITY FOLDER. The agent jails every engine turn with a tmpfs
# over its own folder ("engine jail: ON (bwrap) masking [<identity dir>]"), so a script kept there
# does not exist as far as the spawned engine is concerned — the turn runs with no engine at all.
set -u

# THE MISSION COMES FROM THE SEAL. Empty means the entry was sealed without one, or this script was
# invoked outside the agent: either way the door has no mission to impose and must not silently run
# whatever the caller asked for.
MISSION="${HEIA_FRONTDOOR_MISSION:-}"
if [ -z "$MISSION" ]; then
  echo "mission-runner: no mission. The engine entry must be sealed with a mission (--mission)," >&2
  echo "                which the agent passes as HEIA_FRONTDOOR_MISSION. Refusing to run." >&2
  exit 78
fi

# Everything else is derived from where this script lives, so a door is self-contained and no
# absolute path is baked in.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="${HEIA_FRONTDOOR_ENGINE:-$HOME/.heia/runtime/harness/hexaeight-engine}"
LOG="${HEIA_FRONTDOOR_LOG:-$HERE/frontdoor.log}"
# THIS DOOR KEEPS ITS OWN STORE. Without --root the engine uses ~/.hexaeight-harness, which is the
# WORKSPACE agent's: same sessions, same memories, same skills. The sealed args carry no --root, so
# adding one here cannot collide with one the agent built.
ROOT="${HEIA_FRONTDOOR_ROOT:-$HERE/harness-root}"
# …AND WHAT THE MISSION LAUNCHES USES IT TOO. A framework runner reads memories from HEIA_HARNESS_ROOT,
# and without it fell back to ~/.hexaeight-harness — so an external caller could list and search every
# memory on the machine (measured 2026-09-27). Now it sees this door's store only: its mission, plus what
# `hexaeight-activate runner-memory --share` exported into it.
export HEIA_HARNESS_ROOT="$ROOT"

# A WORKING FOLDER PER CALLER SESSION, AND NONE OF IT THE WORKSPACE'S. Without --workdir the turn ran in
# the engine's default (~/agentwork, the workspace agent's), and every external session shared that one
# folder — a mission's files and a runner's input landed beside the workspace's, and two callers at once
# wrote the same input file (measured 2026-09-27). The agent hands the session id as HEIA_WORK_SESSION
# (ext-s-…); it is reduced to path-safe characters, so it can never leave WORK.
WORK="${HEIA_FRONTDOOR_WORK:-$HERE/work}"
SESS=$(printf '%s' "${HEIA_WORK_SESSION:-default}" | tr -c 'A-Za-z0-9_-' '-')
SESS="${SESS#-}"; [ -n "$SESS" ] || SESS=default
WORKDIR="$WORK/$SESS"

if [ ! -x "$ENGINE" ]; then
  echo "mission-runner: no harness engine at $ENGINE (set HEIA_FRONTDOOR_ENGINE)." >&2
  exit 78
fi
mkdir -p "$ROOT" "$WORKDIR" 2>/dev/null

argv=("$@")
msg_i=-1
for ((i = 0; i < ${#argv[@]}; i++)); do
  if [ "${argv[$i]}" = "-p" ]; then
    if [ "${argv[$((i + 1))]:-}" = "--resume" ]; then msg_i=$((i + 3)); else msg_i=$((i + 1)); fi
    break
  fi
done

if [ "$msg_i" -ge 0 ] && [ -n "${argv[$msg_i]:-}" ]; then
  raw="${argv[$msg_i]}"
  # Strip a caller's own priming block (paired or stray) and any USE MISSION: line they wrote, so
  # neither can reach the runner. Then put THIS door's mission line in front of what is left.
  clean=$(printf '%s' "$raw" \
    | perl -0pe 's/<<<[^\n>]*>>>.*?<<<[^\n>]*>>>\s*//gs' \
    | perl -0pe 's/<<<[^\n>]*>>>\s*//gs' \
    | perl -0pe 's/^[ \t]*USE[ \t]+MISSION:[^\n]*\n?//gim')
  argv[$msg_i]=$(printf '<<<HEIA_FLOWCHART_PRIMING>>>\nUSE MISSION: %s\nNavigate THIS mission memory to answer the request: memory_search it for the flowchart map and the matching card, reason to the right card, then execute its steps.\n<<<END_HEIA_FLOWCHART_PRIMING>>>\n\n%s' "$MISSION" "$clean")
  printf '%s  mission=%s  in=%d chars  out=%d chars\n' "$(date -Is)" "$MISSION" "${#raw}" "${#argv[$msg_i]}" >> "$LOG" 2>/dev/null
else
  printf '%s  NO -p MESSAGE FOUND — passed through untouched (%d args)\n' "$(date -Is)" "${#argv[@]}" >> "$LOG" 2>/dev/null
fi

# --workdir LAST, so it is the one the engine keeps if the agent's argv named another.
exec "$ENGINE" --root "$ROOT" "${argv[@]}" --workdir "$WORKDIR"
