#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# test-release-notes.sh
# Thin wrapper to run generate-release-notes.sh locally with nice output.
#
# Usage:
#   ./scripts/test-release-notes.sh                  # latest two releases
#   ./scripts/test-release-notes.sh 0.216.2          # explicit target
#   ./scripts/test-release-notes.sh 0.216.2 0.216.1  # explicit target + previous
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="/tmp/PLATFORM_RELEASE_NOTES.md"

export OUTPUT_FILE

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Transpara Platform Release Notes — Local Test"
echo "══════════════════════════════════════════════════════════════"
echo ""

"$SCRIPT_DIR/generate-release-notes.sh" "$@"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  GENERATED RELEASE NOTES"
echo "══════════════════════════════════════════════════════════════"
echo ""
cat "$OUTPUT_FILE"
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Saved to: $OUTPUT_FILE"
echo "══════════════════════════════════════════════════════════════"
