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

echo ""
echo "── Regression assertions ─────────────────────────────────────"

fail() { echo "ASSERTION FAILED: $*" >&2; exit 1; }

# Exactly one tinstaller component section (the header carries the version transition).
count="$(grep -c '^### tinstaller:' "$OUTPUT_FILE" || true)"
[[ "$count" == "1" ]] || fail "expected exactly 1 '### tinstaller:' section, found ${count}"

# The first component section (its header carries a version transition) must be tinstaller.
first="$(grep -m1 '^### .*: `' "$OUTPUT_FILE" || true)"
[[ "$first" == "### tinstaller:"* ]] || fail "first component section is '${first}', want '### tinstaller: ...'"

# No legacy capital-I duplicate anywhere.
! grep -q 'tInstaller' "$OUTPUT_FILE" || fail "legacy 'tInstaller' string still present"

# Commit SHAs must be linked, never a bare 40-char hex in parentheses.
! grep -qE '\([0-9a-f]{40}\)' "$OUTPUT_FILE" || fail "bare 40-char commit SHA found (should be a short link)"

# Link text must not be wrapped in backticks ([`x`](url) breaks rendering on GitHub).
! grep -qE '\[`' "$OUTPUT_FILE" || fail "backtick-wrapped link text found (breaks links on GitHub)"

# All-clear states live in the Release Summary, not as floating lines in the body.
! grep -qE '^_No (security|third-party)' "$OUTPUT_FILE" \
  || fail "floating empty-state line present (should be folded into the Release Summary)"
grep -q '^- Security keyword scan:' "$OUTPUT_FILE" \
  || fail "Release Summary is missing the security keyword scan bullet"

# Detail sections must appear iff the Release Summary reports changes/items.
tp_n="$(grep -m1 '^- Third-party components changed:' "$OUTPUT_FILE" | grep -oE '[0-9]+$' || true)"
if [[ "$tp_n" == "0" ]]; then
  ! grep -q '^### Infrastructure & Third-Party' "$OUTPUT_FILE" \
    || fail "third-party section present though summary count is 0"
else
  grep -q '^### Infrastructure & Third-Party' "$OUTPUT_FILE" \
    || fail "third-party section missing though summary count is ${tp_n}"
fi
if grep -q '^- Security keyword scan: no matches' "$OUTPUT_FILE"; then
  ! grep -q '^### Security-Relevant Changes' "$OUTPUT_FILE" \
    || fail "security section present though summary reports no matches"
else
  grep -q '^### Security-Relevant Changes' "$OUTPUT_FILE" \
    || fail "security section missing though summary reports matches"
fi

# When a target tag is given, the Released date must be the tag's publish date, not today.
if [[ -n "${1:-}" ]]; then
  pub="$(gh release view "$1" --repo transpara/tinstaller-releases --json publishedAt --jq '.publishedAt' 2>/dev/null | cut -d'T' -f1 || true)"
  if [[ -n "$pub" && "$pub" != "null" ]]; then
    grep -q "^Released: ${pub} " "$OUTPUT_FILE" || fail "Released date is not the tag's publish date (${pub})"
  fi
fi

# Release Summary heads the document, above the summary table.
rs_line="$(grep -nm1 '^### Release Summary' "$OUTPUT_FILE" | cut -d: -f1 || true)"
table_line="$(grep -nm1 '^| Component | Previous | Current |' "$OUTPUT_FILE" | cut -d: -f1 || true)"
comp_line="$(grep -nm1 '^### .*: `' "$OUTPUT_FILE" | cut -d: -f1 || true)"
[[ -n "$rs_line" && -n "$table_line" && "$rs_line" -lt "$table_line" ]] \
  || fail "Release Summary not above the summary table (rs=${rs_line:-none}, table=${table_line:-none})"
[[ -n "$table_line" && -n "$comp_line" && "$table_line" -lt "$comp_line" ]] \
  || fail "summary table not found above first component (table=${table_line:-none}, comp=${comp_line:-none})"

# Additive: the Version Status table must still be present (nothing was removed).
grep -q '^### Version Status' "$OUTPUT_FILE" || fail "Version Status section was removed (changes must be additive)"

# New footer sections must appear when their source assets exist for the target tag.
if [[ -n "${1:-}" ]]; then
  assets="$(gh release view "$1" --repo transpara/tinstaller-releases --json assets --jq '.assets[].name' 2>/dev/null || true)"
  if grep -qx 'compatibility.yaml' <<<"$assets"; then
    grep -q '^### Compatibility' "$OUTPUT_FILE" || fail "Compatibility section missing though compatibility.yaml asset exists"
  fi
  if grep -q '\.sbom\.cdx\.json$' <<<"$assets"; then
    grep -q '^### Software Bill of Materials' "$OUTPUT_FILE" || fail "SBOM section missing though SBOM assets exist"
  fi
fi

echo "All assertions passed."
