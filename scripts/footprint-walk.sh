#!/bin/zsh
# Runs a walk-through and reads `footprint -p` (phys_footprint) from outside at each of its readings,
# which is the project's measure of memory (ADR 0003, 0005). The walk-through's own readings leave
# out the memory the window and the graphics card hold for it.
#
#   LUMA_BENCH=pin scripts/footprint-walk.sh build/知白.app/Contents/MacOS/Luma some.pdf
#
# Prints "label: footprint -p N MB (own reading M MB)" for each reading.
set -u
binary=$1; shift
log=$(mktemp -t luma-walk)
LUMA_BENCH_HOLD=${LUMA_BENCH_HOLD:-2} timeout ${LUMA_TIMEOUT:-180} "$binary" "$@" > "$log" 2>/dev/null &
runner=$!
# The reader itself is the child of `timeout`, whose own command line names the reader too.
pid=""
for i in $(seq 1 50); do pid=$(pgrep -P $runner); [[ -n $pid ]] && break; sleep 0.1; done
seen=0
while kill -0 $runner 2>/dev/null; do
    lines=("${(@f)$(grep -E '^  .*: [0-9.]+ MB$' "$log")}")
    count=${#lines[@]}
    [[ -z "${lines[1]:-}" ]] && count=0
    while (( seen < count )); do
        seen=$((seen + 1))
        line=${lines[$seen]}
        bytes=$(footprint -p $pid -f bytes --noCategories 2>/dev/null | awk '/phys_footprint:/ {print $2}')
        label=${line%: *}; own=${line##*: }
        printf "%s: footprint -p %.1f MB (own reading %s)\n" "${label##  }" $((bytes / 1048576.0)) "$own"
    done
    sleep 0.2
done
grep -vE '^  .*: [0-9.]+ MB$' "$log" | grep -E '^\s+\(' 
rm -f "$log"
