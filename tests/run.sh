#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

TEST_FILES=()
while IFS= read -r file; do
    TEST_FILES+=("$file")
done < <(find "$SCRIPT_DIR" -type f -name 'test_*.sh' | sort)

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    echo "No tests found under $SCRIPT_DIR"
    exit 1
fi

pass_count=0
fail_count=0

for test_file in "${TEST_FILES[@]}"; do
    echo "==> Running $(realpath --relative-to="$PWD" "$test_file" 2>/dev/null || echo "$test_file")"
    if "$test_file" "$@"; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
    echo

done

echo "Test summary: $pass_count passed, $fail_count failed"
[[ "$fail_count" -eq 0 ]]
