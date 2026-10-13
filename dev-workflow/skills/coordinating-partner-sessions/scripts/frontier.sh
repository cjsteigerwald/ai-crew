#!/usr/bin/env bash
# frontier.sh — launch selection and dependency-cycle check for partner sessions.
#
#   frontier.sh <state.json>                      issue numbers to launch now, one per line
#   frontier.sh --live-count <state.json>         number of live issues (the one definition of "live")
#   frontier.sh --check-edge <state.json> <n> <m> exit 0 if "n blocked by m" keeps the graph acyclic
#
# Exit 2 on a cycle, with `cycle: 3 -> 5 -> 3` on stderr. Reads only the file
# argument; never calls claude or gh. Bash 3.2 compatible.
set -u

usage() {
  echo "usage: frontier.sh <state.json> | --live-count <state.json> | --check-edge <state.json> <n> <m>" >&2
  exit 64
}

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# jq definitions shared by every mode.
DEFS='
def live: .status as $s
  | (["launched","started","done-claimed","verifying","resync-requested"] | index($s)) != null
    or ($s | startswith("rework-"));

# Kahn: repeatedly drop nodes with no remaining blocker; the rest are cyclic.
def leftover($g):
  {rem: ($g | keys), done: false}
  | until(.done;
      .rem as $r
      | [ $r[] | select(any($g[.][]; . as $b | any($r[]; . == $b))) ] as $n
      | if ($n | length) == ($r | length) then .done = true else .rem = $n end)
  | .rem;

# A concrete cycle among the leftover nodes (each has a leftover blocker).
def cycle_of($g; $rem):
  ($rem | map(tonumber) | min | tostring) as $start
  | {path: [$start], hit: null}
  | until(.hit != null;
      .path[-1] as $cur
      | ([ $g[$cur][] | select(. as $b | any($rem[]; . == $b)) ] | .[0]) as $nx
      | if any(.path[]; . == $nx) then .hit = $nx else .path += [$nx] end)
  | .hit as $h | .path
  | (index($h)) as $i | .[$i:] + [$h]
  | map(tostring) | join(" -> ");
'

# Graph object: issue key -> blocker keys that are themselves issues in the set.
BUILD='. as $s | (.issues | keys) as $ks
  | reduce $ks[] as $k ({};
      .[$k] = [ ($s.issues[$k].blockers // [])[] | tostring
                | select(. as $b | any($ks[]; . == $b)) ])'

mode="frontier"
case "${1:-}" in
  --live-count) mode="live"; shift ;;
  --check-edge) mode="edge"; shift ;;
  -*) usage ;;
esac

if [ "$mode" = "edge" ]; then
  [ "$#" -eq 3 ] || usage
  is_num "$2" && is_num "$3" || usage
  state="$1"; en="$2"; em="$3"
else
  [ "$#" -eq 1 ] || usage
  state="$1"
fi
[ -f "$state" ] || { echo "frontier.sh: $state not found" >&2; exit 64; }

if [ "$mode" = "live" ]; then
  jq -r "$DEFS"'[.issues[] | select(live)] | length' "$state"
  exit $?
fi

# Cycle check (on the graph with the proposed edge added, in edge mode).
cyc="$(jq -r --arg en "${en:-}" --arg em "${em:-}" "$DEFS"'
  ('"$BUILD"') as $g0
  | (if $en == "" then $g0
     else ($g0 | .[$en] = ((.[$en] // []) + (if ($g0 | has($em)) then [$em] else [] end)))
     end) as $g
  | leftover($g) as $rem
  | if ($rem | length) == 0 then empty else "cycle: " + cycle_of($g; $rem) end' "$state")" || exit 64

if [ -n "$cyc" ]; then
  echo "$cyc" >&2
  exit 2
fi
[ "$mode" = "edge" ] && exit 0

jq -r "$DEFS"'
  . as $s | ([.issues[] | select(live)] | length) as $live
  | ((.cap // 3) - $live) as $slots
  | [ .issues | to_entries[]
      | select(.value.status == "pending")
      | select(all((.value.blockers // [])[]; . as $b | $s.issues[($b | tostring)].status == "merged"))
      | select(all((.value.external // [])[]; .closed == true))
      | .key | tonumber ]
  | sort | .[0:(if $slots < 0 then 0 else $slots end)][]' "$state"
