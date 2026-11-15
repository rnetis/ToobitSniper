#!/usr/bin/env bash
# Compile the signal engine against the synthetic harness and run it.
#
# Catches traps inside SignalEngine.evaluate (index out of range, bad unwraps, arithmetic)
# before they reach a build. Runs in CI ahead of the IPA archive step.
#
#   ./scripts/run-engine-smoke.sh
#
# Only Sources/Core is compiled; no simulator, network or signing needed.

set -euo pipefail

cd "$(dirname "$0")/.."

SWIFT="${SWIFT:-swiftc}"
if ! command -v "$SWIFT" >/dev/null 2>&1; then
  echo "error: '$SWIFT' not found — install Xcode or the Swift toolchain" >&2
  exit 1
fi

sources=(Sources/Core/*.swift)

# RiskGovernor publishes Combine state and is not part of the signal engine. Combine is
# Apple-only, so drop it when running on a non-Apple toolchain.
if [[ "$(uname -s)" == "Linux" ]]; then
  filtered=()
  for file in "${sources[@]}"; do
    [[ "$(basename "$file")" == "RiskGovernor.swift" ]] && continue
    filtered+=("$file")
  done
  sources=("${filtered[@]}")
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
binary="$workdir/engine-smoke"

echo "engine smoke: compiling ${#sources[@]} engine sources…"
"$SWIFT" -O "${sources[@]}" scripts/engine-smoke/main.swift -o "$binary"

echo "engine smoke: running synthetic datasets…"
"$binary"
