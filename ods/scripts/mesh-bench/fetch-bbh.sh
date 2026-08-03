#!/usr/bin/env bash
# Fetch BIG-Bench Hard task files.
#
# Not vendored into the repo: BBH is ~10MB across 27 tasks and carries its own
# licence. Fetch what you need, where you need it.
set -euo pipefail

dest="${1:-./bbh}"
base="https://raw.githubusercontent.com/suzgunmirac/BIG-Bench-Hard/main/bbh"

# A reasoning-weighted subset. Add more task names as needed.
tasks=(
    logical_deduction_three_objects
    logical_deduction_five_objects
    tracking_shuffled_objects_three_objects
    date_understanding
    boolean_expressions
    formal_fallacies
)

mkdir -p "$dest"
for task in "${tasks[@]}"; do
    if [[ -f "${dest}/${task}.json" ]]; then
        echo "have ${task}.json"
        continue
    fi
    curl -fsSL "${base}/${task}.json" -o "${dest}/${task}.json" \
        || warn_failed="${warn_failed:-}${task} "
    echo "fetched ${task}.json"
done

if [[ -n "${warn_failed:-}" ]]; then
    echo "WARNING: could not fetch: ${warn_failed}" >&2
fi

echo "BBH tasks in ${dest}:"
ls -1 "${dest}"
