#!/usr/bin/env bash
# Fetch BIG-Bench Hard task files.
#
# Not vendored into the repo: BBH is ~10MB across 27 tasks and carries its own
# licence. Fetch what you need, where you need it.
set -euo pipefail

dest="${1:-./bbh}"
base="https://raw.githubusercontent.com/suzgunmirac/BIG-Bench-Hard/main/bbh"

# A reasoning-weighted subset. Add more task names as needed.
#
# Every task here answers with an option letter, or with a word the aggregator
# treats as an answer (yes/no/true/false/valid/invalid). That is a constraint,
# not a preference: consensus_key only extracts those, so a task answering with
# a number or a sorted word list falls back to comparing the prose around the
# answer -- which scores ~0.96 between peers that disagree, bypasses the judge,
# and silently disables selection on the very run meant to evaluate it.
# word_sorting, dyck_languages, object_counting and multistep_arithmetic_two
# are all excluded for that reason.
tasks=(
    # Saturated for a 9B on the easy end -- kept for continuity with earlier runs.
    logical_deduction_three_objects
    boolean_expressions
    date_understanding
    tracking_shuffled_objects_three_objects

    # Where a small model actually starts losing items, which is the only
    # place selection has anything to recover.
    logical_deduction_five_objects
    logical_deduction_seven_objects
    tracking_shuffled_objects_seven_objects
    formal_fallacies
    causal_judgement
    temporal_sequences
    penguins_in_a_table
    disambiguation_qa
    snarks
    web_of_lies
    geometric_shapes
    salient_translation_error_detection
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
