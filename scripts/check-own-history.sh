#!/usr/bin/env bash
# Layer 7 — validates that this repository's own commit subjects satisfy the
# rules GITTHAT enforces. Run in CI.
set -euo pipefail

range="${1:-origin/main..HEAD}"
failed=0

# Build the binary once if it is not already present, so the script can
# delegate the casing rule to the real implementation (SubjectCase.swift)
# instead of re-implementing it in shell (which diverges over time).
GITTHAT_BIN="$(swift build --show-bin-path 2>/dev/null)/gitthat"
if [ ! -x "$GITTHAT_BIN" ]; then
  swift build -c release 2>/dev/null
  GITTHAT_BIN="$(swift build -c release --show-bin-path 2>/dev/null)/gitthat"
fi

subjects=()
while IFS= read -r subject; do
  [ -z "$subject" ] && continue
  subjects+=("$subject")
done < <(git log --format=%s "$range")

# Delegate casing check to the real SubjectCase implementation.
if [ "${#subjects[@]}" -gt 0 ]; then
  if printf '%s\n' "${subjects[@]}" | "$GITTHAT_BIN" __check-subject; then
    :
  else
    failed=1
  fi
fi

# Conventional-commits format check (unchanged — not implemented in SubjectCase).
for subject in "${subjects[@]}"; do
  if ! printf '%s' "$subject" | grep -qE '^[a-z]+(\([^)]+\))?!?: .+'; then
    echo "not conventional: $subject"
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo
  echo "Fix the subjects above."
  exit 1
fi

echo "history is clean"
