#!/usr/bin/env bash
# render-handoff.sh — fill the handoff-prompt template from a JSON values file.
#
#   render-handoff.sh <template.md> <values.json>
#
# values.json is one JSON object: placeholder name -> string (an integer is
# accepted and written as its digits). Every {{NAME}} in the template (NAME is
# A-Z, 0-9 and _, starting with a letter) must have a non-blank value, except
# the names in OPTIONAL below, which may be empty. Stdout carries the rendered
# text only when the render is complete.
#
# Exit 0: rendered. Exit 1: blocked, nothing on stdout, one problem per line on
# stderr: a placeholder with no value, a blank required value, a value that is
# not a string or integer, a values key the template does not use, or a stray
# "{{" or "}}" left in the template (a malformed placeholder). Exit 2: usage,
# unreadable file, or invalid JSON.
#
# Values are data. jq substitutes them in one pass over the template, so text
# inside a value ("{{", "&", "\1", "$x", backticks, newlines) is copied
# verbatim and never rescanned or expanded; nothing is evaluated by the shell.
set -u

OPTIONAL='["BLOCKER_EVIDENCE"]'

if [ "$#" -ne 2 ]; then
  echo "usage: render-handoff.sh <template.md> <values.json>" >&2
  exit 2
fi
tpl="$1"
vals="$2"
[ -f "$tpl" ] && [ -r "$tpl" ] || { echo "render-handoff: cannot read template: $tpl" >&2; exit 2; }
[ -f "$vals" ] && [ -r "$vals" ] || { echo "render-handoff: cannot read values: $vals" >&2; exit 2; }
jq -e 'type == "object"' "$vals" >/dev/null 2>&1 || { echo "render-handoff: values must be a JSON object: $vals" >&2; exit 2; }

tmp="$(mktemp)" || exit 2
trap 'rm -f "$tmp"' EXIT

# One program: collect problems, and the rendered text when there are none.
jq -n --rawfile t "$tpl" --slurpfile vs "$vals" --argjson opt "$OPTIONAL" '
  "\\{\\{(?<k>[A-Z][A-Z0-9_]*)\\}\\}" as $re
  | $vs[0] as $v
  | [$t | match($re; "g") | .captures[0].string] | unique as $need
  | ($t | gsub($re; "")) as $rest
  | ($v | keys) as $have
  | def scalar: type == "string" or (type == "number" and . == floor);
    def blank: type == "string" and test("\\A\\s*\\z");
  (
      [ $need[] | . as $k | select($have | index([$k]) == null) | "unfilled placeholder: {{" + $k + "}}" ]
    + [ $need[] | . as $k | select($have | index([$k]) != null)
        | select($v[$k] | scalar | not) | "value is not a string or integer: " + $k ]
    + [ $need[] | . as $k | select($have | index([$k]) != null)
        | select(($v[$k] | scalar) and ($v[$k] | blank) and ($opt | index([$k]) == null))
        | "empty required value: " + $k ]
    + [ $have[] | . as $k | select($need | index([$k]) == null)
        | "values key not used by the template: " + $k ]
    + (if ($rest | test("\\{\\{|\\}\\}")) then ["template has a malformed placeholder (stray {{ or }})"] else [] end)
  ) as $problems
  | if ($problems | length) > 0 then {problems: $problems}
    else {problems: [],
          out: ($t | gsub($re; $v[.k] | if type == "number" then tostring else . end))}
    end
' >"$tmp" || { echo "render-handoff: internal error while rendering" >&2; exit 2; }

if [ "$(jq -r '.problems | length' "$tmp")" -ne 0 ]; then
  jq -r '.problems[]' "$tmp" | sed 's/^/render-handoff: /' >&2
  exit 1
fi
jq -j '.out' "$tmp"
