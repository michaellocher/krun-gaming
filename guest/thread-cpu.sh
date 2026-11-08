#!/bin/sh
# Guest: top CPU threads over ${1:-3} s (percent of one core), from /proc/*/task/*/stat (the guest has no top).
snap() { for t in /proc/[0-9]*/task/[0-9]*; do
  s=$(cat "$t/stat" 2> /dev/null) || continue
  rest=${s##*) }; name=${s#*(}; name=${name%%)*}
  set -- $rest; echo "${t#/proc/} $name $((${12} + ${13}))"
done; }
snap > /tmp/cpu.a; sleep "${1:-3}"; snap > /tmp/cpu.b
awk -v s="${1:-3}" 'NR==FNR { a[$1]=$NF; next } ($1 in a) { d=$NF-a[$1]; if (d > 0) printf "%5.0f%% %s %s\n", d/s, $1, $2 }' \
  /tmp/cpu.a /tmp/cpu.b | sort -rn | head -"${2:-12}"
