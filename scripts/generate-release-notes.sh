#!/usr/bin/env bash
# generate-release-notes.sh — Aggregates release notes across all Transpara
# platform components by comparing versions.yaml between two releases.
#
# Usage:
#   ./generate-release-notes.sh [TARGET_TAG] [PREVIOUS_TAG]
#
# Environment variables (all optional):
#   ORG            GitHub org           (default: transpara)
#   INSTALLER_REPO Release repo name    (default: tinstaller-releases)
#   OUTPUT_FILE    Output path          (default: JOINT_RELEASE_NOTES.md)
#
# Prerequisites: gh (authenticated), yq, jq
set -uo pipefail

# ── Constants ──────────────────────────────────────────────────────────
readonly IS_CI="${GITHUB_ACTIONS:-false}"
readonly ORG="${ORG:-transpara}"
readonly INSTALLER_REPO="${INSTALLER_REPO:-tinstaller-releases}"
readonly OUTPUT_FILE="${OUTPUT_FILE:-PLATFORM_RELEASE_NOTES.md}"

# Component registry: yaml_path|display_name|github_repo|type|tag_prefix
# type: transpara = full release notes, thirdparty = version table row
# tag_prefix: for repos with non-standard tag naming (e.g. transpara-operator-)
readonly COMPONENTS=(
  # Transpara application images
  "container_images.tsystem.version|tsystem|tsystem|transpara|"
  "container_images.tsystemevent.version|tevent-processor|tsystem|transpara|"
  "container_images.tauth.version|tauth|tauth|transpara|"
  "container_images.tauth_scraper.version|tauth-scraper|tauth-scraper|transpara|"
  "container_images.tstudio.version|tstudio|tstudio-py|transpara|"
  "container_images.tgraph.version|tgraph|tgraph-api|transpara|"
  "container_images.tgraph_controller.version|tgraph-controller|tgraph-api|transpara|"
  "container_images.tcalc.version|tcalc|tcalc|transpara|"
  "container_images.tview.version|tview|tview|transpara|"
  "container_images.taigateway.version|tai-gateway|tai-gateway|transpara|"
  "container_images.tsystem_watcher.version|tsystem-watcher|tsystem-watcher|transpara|"
  "container_images.mcp_memgraph.version|mcp-memgraph|mcp-memgraph|transpara|"
  "container_images.interfaces.tstore.version|tstore-interface|tstore-interface|transpara|"
  # Transpara extractors
  "container_images.extractors.odbc.version|extractor-odbc|extractor_odbc|transpara|"
  "container_images.extractors.opcua.version|extractor-opcua|extractor-opcua|transpara|"
  "container_images.extractors.telegraf.version|extractor-telegraf|extractor-telegraf|transpara|"
  # Transpara operator (tag prefix: transpara-operator-X.Y.Z)
  "operators.transpara.version|transpara-operator|deployment|transpara|transpara-operator-"
  # Third-party container images
  "container_images.emqx.version|EMQX|—|thirdparty|"
  "container_images.timescale.version|TimescaleDB|—|thirdparty|"
  "container_images.valkey.version|Valkey|—|thirdparty|"
  "container_images.keycloak.version|Keycloak|—|thirdparty|"
  # Third-party infrastructure
  "k3s.version|K3s|—|thirdparty|"
  "helm.version|Helm|—|thirdparty|"
  "envoy_gateway.version|Envoy Gateway|—|thirdparty|"
  # Third-party Helm charts
  "charts.cert_manager.version|cert-manager (chart)|—|thirdparty|"
  "charts.prometheus.version|Prometheus stack (chart)|—|thirdparty|"
  "charts.grafana_cnpg.version|Grafana CNPG (chart)|—|thirdparty|"
  "charts.longhorn.version|Longhorn (chart)|—|thirdparty|"
  "charts.emqx_operator.version|EMQX operator (chart)|—|thirdparty|"
  "charts.valkey.version|Valkey (chart)|—|thirdparty|"
  "charts.memgraph_lab.version|Memgraph Lab (chart)|—|thirdparty|"
  "charts.memgraph.version|Memgraph (chart)|—|thirdparty|"
  "charts.cnpg_operator.version|CNPG operator (chart)|—|thirdparty|"
  "charts.zfs_localpv.version|ZFS LocalPV (chart)|—|thirdparty|"
  "charts.headlamp.version|Headlamp (chart)|—|thirdparty|"
  "charts.kyverno.version|Kyverno (chart)|—|thirdparty|"
  "charts.kyverno_policies.version|Kyverno Policies (chart)|—|thirdparty|"
  # Tools
  "tools.crane.version|crane|—|thirdparty|"
)

# ── Logging ────────────────────────────────────────────────────────────
log()    { echo "[*] $*" >&2; }
warn()   { if [[ "${IS_CI}" == "true" ]]; then echo "::warning::$*" >&2; else echo "[!] WARNING: $*" >&2; fi; }
notice() { if [[ "${IS_CI}" == "true" ]]; then echo "::notice::$*" >&2; else echo "[i] $*" >&2; fi; }

# ── Helpers ────────────────────────────────────────────────────────────

check_dependencies() {
  for cmd in gh yq jq; do
    if ! command -v "${cmd}" &>/dev/null; then
      echo "ERROR: '${cmd}' is required but not found." >&2
      exit 1
    fi
  done
  if [[ "${IS_CI}" != "true" ]] && ! gh auth status &>/dev/null; then
    echo "ERROR: gh CLI is not authenticated. Run:  gh auth login -h github.com" >&2
    exit 1
  fi
}

# Reads a version from a YAML file. Returns empty string if not found.
get_version() {
  local file="$1" path="$2"
  if [[ -z "${file}" ]] || [[ ! -f "${file}" ]]; then echo ""; return; fi
  yq eval ".${path}" "${file}" 2>/dev/null | tr -d '"'
}

# Retries a command up to 3 times with exponential backoff.
gh_retry() {
  local attempt
  for (( attempt = 1; attempt <= 3; attempt++ )); do
    if "$@" 2>/dev/null; then return 0; fi
    if (( attempt < 3 )); then sleep "${attempt}"; fi
  done
  return 1
}

# Flattens markdown h1-h5 to h5 so upstream notes nest properly.
normalize_headers() {
  sed -E 's/^#{1,5} /##### /'
}

# Formats a version transition line for display.
format_version_line() {
  local prev="$1" curr="$2"
  if [[ -n "${prev}" ]] && [[ "${prev}" != "null" ]] && [[ "${prev}" != "${curr}" ]]; then
    echo "Previous: \`${prev}\` | Current: \`${curr}\`"
  elif [[ -z "${prev}" ]] || [[ "${prev}" == "null" ]]; then
    echo "Current: \`${curr}\` (new component)"
  else
    echo "Current: \`${curr}\`"
  fi
}

# Returns true if a component version changed between releases.
version_changed() {
  local prev="$1" curr="$2"
  if [[ -z "${curr}" ]] || [[ "${curr}" == "null" ]]; then return 1; fi
  if [[ -n "${prev}" ]] && [[ "${prev}" == "${curr}" ]]; then return 1; fi
  return 0
}

# ── Core ───────────────────────────────────────────────────────────────

# Fetches release notes between two versions from a GitHub repo.
# Supports an optional tag_prefix for repos with non-standard naming.
fetch_notes_between() {
  local repo="$1" old_ver="$2" new_ver="$3" tag_prefix="${4:-}"

  if [[ -z "${new_ver}" ]] || [[ "${new_ver}" == "null" ]]; then return; fi
  if [[ "${old_ver}" == "${new_ver}" ]]; then return; fi

  local new_tag="${tag_prefix}${new_ver}"
  local old_tag="${tag_prefix}${old_ver}"

  local all_releases
  all_releases=$(gh_retry gh release list --repo "${ORG}/${repo}" --limit 100 \
    --json tagName,publishedAt || echo "[]")

  # No previous version — show only new version notes
  if [[ -z "${old_ver}" ]] || [[ "${old_ver}" == "null" ]]; then
    echo "#### ${new_tag}"
    gh_retry gh release view "${new_tag}" --repo "${ORG}/${repo}" \
      --json body --jq '.body' | normalize_headers || true
    echo ""
    return
  fi

  local old_date new_date
  old_date=$(echo "${all_releases}" | jq -r \
    ".[] | select(.tagName == \"${old_tag}\") | .publishedAt" 2>/dev/null)
  new_date=$(echo "${all_releases}" | jq -r \
    ".[] | select(.tagName == \"${new_tag}\") | .publishedAt" 2>/dev/null)

  local tags=""

  if [[ -n "${old_date}" ]] && [[ -n "${new_date}" ]]; then
    # Both versions found — collect releases between them
    tags=$(echo "${all_releases}" | jq -r \
      "[.[] | select(.publishedAt > \"${old_date}\" and .publishedAt <= \"${new_date}\")] | reverse | .[].tagName" 2>/dev/null)
  elif [[ -n "${old_date}" ]] && [[ -z "${new_date}" ]]; then
    # New version has no release yet — show all after old
    tags=$(echo "${all_releases}" | jq -r \
      "[.[] | select(.publishedAt > \"${old_date}\")] | reverse | .[].tagName" 2>/dev/null)
  else
    # Can't resolve dates — show just new version notes
    echo "#### ${new_tag}"
    gh_retry gh release view "${new_tag}" --repo "${ORG}/${repo}" \
      --json body --jq '.body' | normalize_headers || true
    echo ""
    return
  fi

  if [[ -n "${tags}" ]]; then
    while IFS= read -r tag; do
      echo "#### ${tag}"
      gh_retry gh release view "${tag}" --repo "${ORG}/${repo}" \
        --json body --jq '.body' | normalize_headers || true
      echo ""
    done <<< "${tags}"
  fi
}

# ── Output generators ──────────────────────────────────────────────────

generate_tinstaller_section() {
  local curr_yaml="$1" prev_yaml="$2" workdir="$3"

  local curr_ver prev_ver
  curr_ver=$(get_version "${curr_yaml}" "tinstaller.version")
  prev_ver=""
  [[ -n "${prev_yaml}" ]] && prev_ver=$(get_version "${prev_yaml}" "tinstaller.version")

  echo "### tInstaller"
  format_version_line "${prev_ver}" "${curr_ver}"
  echo ""
  # Save notes to temp file for security section scanning
  fetch_notes_between "tinstaller" "${prev_ver}" "${curr_ver}" \
    | tee "${workdir}/tinstaller_notes.md"
  echo "---"
  echo ""
}

generate_transpara_sections() {
  local curr_yaml="$1" prev_yaml="$2" workdir="$3"

  mkdir -p "${workdir}/notes"
  local pids=()
  local names=()

  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r yaml_path name repo comp_type tag_prefix <<< "${entry}"
    [[ "${comp_type}" != "transpara" ]] && continue

    local curr_ver prev_ver
    curr_ver=$(get_version "${curr_yaml}" "${yaml_path}")
    prev_ver=""
    [[ -n "${prev_yaml}" ]] && prev_ver=$(get_version "${prev_yaml}" "${yaml_path}")

    if ! version_changed "${prev_ver}" "${curr_ver}"; then continue; fi

    names+=("${name}")

    # Write header + version line to temp file, then fetch notes in background
    {
      echo "### ${name}"
      format_version_line "${prev_ver}" "${curr_ver}"
      echo ""
      fetch_notes_between "${repo}" "${prev_ver}" "${curr_ver}" "${tag_prefix}"
      echo "---"
      echo ""
    } > "${workdir}/notes/${name}.md" 2>"${workdir}/notes/${name}.err" &
    pids+=($!)
  done

  # Wait for all background fetches
  for pid in "${pids[@]}"; do
    wait "${pid}" 2>/dev/null || true
  done

  # Report errors
  for name in "${names[@]}"; do
    local err_file="${workdir}/notes/${name}.err"
    if [[ -s "${err_file}" ]]; then
      warn "Error fetching notes for ${name}: $(cat "${err_file}")"
    fi
  done

  # Assemble in original order
  for name in "${names[@]}"; do
    local notes_file="${workdir}/notes/${name}.md"
    if [[ -f "${notes_file}" ]]; then
      cat "${notes_file}"
    fi
  done
}

# Scans fetched release notes for security-related changes.
# Extracts matching lines from temp files already populated by generate_transpara_sections.
generate_security_section() {
  local workdir="$1"
  local notes_dir="${workdir}/notes"

  # Security keywords pattern (case-insensitive grep)
  local pattern="CVE-|GHSA-|security|vulnerab|auth.*fix|XSS|CSRF|injection|privilege.escalat|access.control"

  local findings=""

  # Scan tinstaller notes if present
  if [[ -f "${workdir}/tinstaller_notes.md" ]]; then
    local matches
    matches=$(grep -iE "${pattern}" "${workdir}/tinstaller_notes.md" 2>/dev/null || true)
    if [[ -n "${matches}" ]]; then
      findings+="**tInstaller**"$'\n'
      findings+="${matches}"$'\n\n'
    fi
  fi

  # Scan each component's notes
  if [[ -d "${notes_dir}" ]]; then
    for notes_file in "${notes_dir}"/*.md; do
      [[ -f "${notes_file}" ]] || continue
      local comp_name
      comp_name=$(basename "${notes_file}" .md)
      local matches
      matches=$(grep -iE "${pattern}" "${notes_file}" 2>/dev/null || true)
      if [[ -n "${matches}" ]]; then
        findings+="**${comp_name}**"$'\n'
        findings+="${matches}"$'\n\n'
      fi
    done
  fi

  echo "### Security-Relevant Changes"
  echo ""
  if [[ -n "${findings}" ]]; then
    echo "> The following changes were identified by keyword matching (CVE, security, vulnerability, auth fix, etc.)."
    echo "> This is not a vulnerability assessment — review each item for applicability."
    echo ""
    echo "${findings}"
  else
    echo "No security-relevant changes detected in this release."
    echo ""
  fi
  echo "---"
  echo ""
}

generate_thirdparty_table() {
  local curr_yaml="$1" prev_yaml="$2"

  local rows=""
  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r yaml_path name repo comp_type tag_prefix <<< "${entry}"
    [[ "${comp_type}" != "thirdparty" ]] && continue

    local curr_ver prev_ver
    curr_ver=$(get_version "${curr_yaml}" "${yaml_path}")
    prev_ver=""
    [[ -n "${prev_yaml}" ]] && prev_ver=$(get_version "${prev_yaml}" "${yaml_path}")

    if ! version_changed "${prev_ver}" "${curr_ver}"; then continue; fi

    if [[ -z "${prev_ver}" ]] || [[ "${prev_ver}" == "null" ]]; then
      rows+="| ${name} | (new) | \`${curr_ver}\` |"$'\n'
    else
      rows+="| ${name} | \`${prev_ver}\` | \`${curr_ver}\` |"$'\n'
    fi
  done

  echo "### Infrastructure & Third-Party"
  echo ""
  if [[ -n "${rows}" ]]; then
    echo "| Component | Previous | Current |"
    echo "|-----------|----------|---------|"
    echo -n "${rows}"
  else
    echo "No third-party version changes in this release."
  fi
  echo ""
  echo "---"
  echo ""
}

generate_version_status() {
  local curr_yaml="$1" workdir="$2" target_tag="$3"

  echo "### Version Status"
  echo ""

  # Check tinstaller + all transpara components for "behind latest"
  # Include tag_prefix so we can strip it when comparing versions
  local check_entries=("tinstaller.version|tinstaller|tinstaller|")
  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r yaml_path name repo comp_type tag_prefix <<< "${entry}"
    [[ "${comp_type}" != "transpara" ]] && continue
    check_entries+=("${yaml_path}|${name}|${repo}|${tag_prefix}")
  done

  # Fetch latest releases in parallel
  mkdir -p "${workdir}/status"
  local pids=()
  for check in "${check_entries[@]}"; do
    IFS='|' read -r yaml_path name repo tag_prefix <<< "${check}"
    {
      gh_retry gh release list --repo "${ORG}/${repo}" --limit 1 \
        --json tagName --jq '.[0].tagName' > "${workdir}/status/${name}.latest" || true
    } &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "${pid}" 2>/dev/null || true
  done

  local behind=""
  for check in "${check_entries[@]}"; do
    IFS='|' read -r yaml_path name repo tag_prefix <<< "${check}"
    local curr_ver
    curr_ver=$(get_version "${curr_yaml}" "${yaml_path}")
    if [[ -z "${curr_ver}" ]] || [[ "${curr_ver}" == "null" ]]; then continue; fi

    local latest=""
    [[ -f "${workdir}/status/${name}.latest" ]] && latest=$(cat "${workdir}/status/${name}.latest")

    # Strip tag prefix for version comparison, but display the full tag for transparency
    local latest_comparable="${latest#"${tag_prefix}"}"

    if [[ -n "${latest}" ]] && [[ "${latest_comparable}" != "${curr_ver}" ]]; then
      behind+="| ${name} | \`${curr_ver}\` | \`${latest}\` |"$'\n'
    fi
  done

  if [[ -n "${behind}" ]]; then
    echo "Components where the bundled version differs from the latest available release."
    echo "Versions may be intentionally pinned for stability or compatibility."
    echo "See [\`versions.yaml\`](https://github.com/${ORG}/${INSTALLER_REPO}/releases/tag/${target_tag}) attached to this release for the full manifest."
    echo ""
    echo "| Component | Bundled | Latest Available |"
    echo "|-----------|---------|------------------|"
    echo -n "${behind}"
  else
    echo "All bundled component versions match their latest available releases."
  fi
  echo ""
}

# ── Entry point ────────────────────────────────────────────────────────

main() {
  check_dependencies

  # Resolve target and previous tags
  local target_tag prev_tag
  if [[ -n "${1:-}" ]]; then
    target_tag="$1"
  else
    target_tag=$(gh release list --repo "${ORG}/${INSTALLER_REPO}" \
      --limit 1 --json tagName --jq '.[0].tagName')
  fi

  if [[ -n "${2:-}" ]]; then
    prev_tag="$2"
  else
    prev_tag=$(gh release list --repo "${ORG}/${INSTALLER_REPO}" \
      --limit 2 --json tagName --jq '.[1].tagName // empty')
  fi

  notice "Target tag:   ${target_tag}"
  notice "Previous tag: ${prev_tag:-<none>}"

  # Download versions.yaml from both releases
  WORKDIR=$(mktemp -d)
  trap 'rm -rf "${WORKDIR}"' EXIT
  local workdir="${WORKDIR}"

  mkdir -p "${workdir}/current" "${workdir}/previous"

  log "Downloading versions.yaml for ${target_tag} ..."
  gh release download "${target_tag}" --repo "${ORG}/${INSTALLER_REPO}" \
    --pattern "versions.yaml" --dir "${workdir}/current"
  local curr_yaml="${workdir}/current/versions.yaml"

  local prev_yaml=""
  if [[ -n "${prev_tag}" ]]; then
    log "Downloading versions.yaml for ${prev_tag} ..."
    if gh release download "${prev_tag}" --repo "${ORG}/${INSTALLER_REPO}" \
        --pattern "versions.yaml" --dir "${workdir}/previous" 2>/dev/null; then
      prev_yaml="${workdir}/previous/versions.yaml"
    else
      warn "Could not download versions.yaml from previous release ${prev_tag}"
    fi
  fi

  # Generate the release notes document
  log "Generating release notes → ${OUTPUT_FILE}"

  {
    echo "## Transpara Platform Release Notes"
    echo "Consolidated release notes for all platform components."
    echo ""
    echo "Released: $(date +%Y-%m-%d) | Previous: \`${prev_tag:-initial}\` | Current: \`${target_tag}\`"
    echo ""

    generate_tinstaller_section "${curr_yaml}" "${prev_yaml}" "${workdir}"
    generate_transpara_sections "${curr_yaml}" "${prev_yaml}" "${workdir}"
    generate_security_section "${workdir}"
    generate_thirdparty_table "${curr_yaml}" "${prev_yaml}"
    generate_version_status "${curr_yaml}" "${workdir}" "${target_tag}"
  } > "${OUTPUT_FILE}"

  # Expose target tag for CI
  if [[ "${IS_CI}" == "true" ]] && [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "target_tag=${target_tag}" >> "${GITHUB_ENV}"
  fi

  log "Done. Output written to ${OUTPUT_FILE}"
}

main "$@"
