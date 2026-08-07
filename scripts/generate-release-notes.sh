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

# COMPONENTS yaml_path field that identifies the installer's own entry.
readonly TINSTALLER_KEY="tinstaller.version"

# Component registry — loaded from components.yaml (single source of truth).
# Format after loading: yaml_path.version|display_name|github_repo|type|tag_prefix
COMPONENTS=()

# Loads components from a components.yaml file into the COMPONENTS array.
# Produces the same pipe-delimited format consumed by downstream functions.
load_components() {
  local file="$1"
  COMPONENTS=()
  local comp_types=("transpara" "thirdparty")
  for comp_type in "${comp_types[@]}"; do
    local count
    count=$(yq e ".${comp_type} | length" "${file}")
    for (( i=0; i<count; i++ )); do
      local yaml_path display_name github_repo tag_prefix
      yaml_path=$(yq e ".${comp_type}[$i].yaml_path" "${file}")
      display_name=$(yq e ".${comp_type}[$i].display_name" "${file}")
      github_repo=$(yq e ".${comp_type}[$i].github_repo // \"—\"" "${file}")
      tag_prefix=$(yq e ".${comp_type}[$i].tag_prefix // \"\"" "${file}")
      COMPONENTS+=("${yaml_path}.version|${display_name}|${github_repo}|${comp_type}|${tag_prefix}")
    done
  done
}

# Fallback component list for releases that pre-date the components.yaml asset.
# Remove this function after all active releases include components.yaml.
load_components_fallback() {
  COMPONENTS=(
    "container_images.tsystem.version|tsystem|tsystem-api|transpara|"
    "container_images.tsystemevent.version|tevent-processor|tevent-processor|transpara|"
    "container_images.tauth.version|tauth|tauth|transpara|"
    "container_images.tauth_scraper.version|tauth-scraper|tauth-scraper|transpara|"
    "container_images.tstudio.version|tstudio|tstudio|transpara|"
    "container_images.tgraph.version|tgraph|tgraph-api|transpara|"
    "container_images.tgraph_controller.version|tgraph-controller|tgraph-controller|transpara|"
    "container_images.tcalc_api.version|tcalc-api|tcalc|transpara|"
    "container_images.tcalc_scheduler.version|tcalc-scheduler|tcalc|transpara|"
    "container_images.tcalc_worker.version|tcalc-worker|tcalc|transpara|"
    "container_images.tcalc_event_scheduler.version|tcalc-event-scheduler|tcalc|transpara|"
    "container_images.tview.version|tview|tview|transpara|"
    "container_images.taigateway.version|tai-gateway|tai-gateway|transpara|"
    "container_images.tsystem_watcher.version|tsystem-watcher|tsystem-watcher|transpara|"
    "container_images.mcp_memgraph.version|mcp-memgraph|mcp-memgraph|transpara|"
    "container_images.interfaces.tstore.version|tstore-interface|tstore-interface|transpara|"
    "container_images.interfaces.odbc_api.version|odbc-interface-api|odbc-interface|transpara|"
    "container_images.interfaces.odbc_worker.version|odbc-interface-worker|odbc-interface|transpara|"
    "container_images.extractors.odbc.version|extractor-odbc|extractor-odbc|transpara|"
    "container_images.extractors.opcua.version|extractor-opcua|extractor-opcua|transpara|"
    "container_images.extractors.telegraf.version|extractor-telegraf|extractor-telegraf|transpara|"
    "operators.transpara.version|transpara-operator|deployment|transpara|transpara-operator-"
    "container_images.emqx.version|EMQX|—|thirdparty|"
    "container_images.timescale.version|TimescaleDB|—|thirdparty|"
    "container_images.valkey.version|Valkey|—|thirdparty|"
    "container_images.keycloak.version|Keycloak|—|thirdparty|"
    "k3s.version|K3s|—|thirdparty|"
    "helm.version|Helm|—|thirdparty|"
    "envoy_gateway.version|Envoy Gateway|—|thirdparty|"
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
    "tools.crane.version|crane|—|thirdparty|"
  )
}

# Ensures the installer's own component is present and leads COMPONENTS, so the
# tinstaller section heads every generated view regardless of whether (or where)
# the components.yaml asset lists it. Older assets omit the self-entry, so it is
# synthesized when missing. An unchanged version is still skipped by
# version_changed, like any other component.
# Globals: COMPONENTS (augmented/reordered in place), TINSTALLER_KEY
ensure_tinstaller_first() {
  local front=() rest=() entry
  for entry in "${COMPONENTS[@]}"; do
    if [[ "${entry%%|*}" == "${TINSTALLER_KEY}" ]]; then
      front+=("${entry}")
    else
      rest+=("${entry}")
    fi
  done
  if (( ${#front[@]} == 0 )); then
    front=("${TINSTALLER_KEY}|tinstaller|tinstaller|transpara|")
  fi
  COMPONENTS=("${front[@]}" "${rest[@]}")
}

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

# Formats an upstream release body for inclusion: flattens its headers, then rewrites
# bare 40-char commit SHAs into short clickable links. The commits live in the
# component's own repo, not this one, so a bare SHA would never autolink on the
# release page.
# Arguments: $1 = github repo (under ORG) the body came from
format_notes_body() {
  local repo="$1"
  normalize_headers \
    | sed -E "s@\(([0-9a-f]{7})([0-9a-f]{33})\)@([\1](https://github.com/${ORG}/${repo}/commit/\1\2))@g"
}

# Formats a compact version transition fragment for a component heading.
format_version_line() {
  local prev="$1" curr="$2"
  if [[ -n "${prev}" ]] && [[ "${prev}" != "null" ]] && [[ "${prev}" != "${curr}" ]]; then
    echo "\`${prev}\` → \`${curr}\`"
  elif [[ -z "${prev}" ]] || [[ "${prev}" == "null" ]]; then
    echo "\`${curr}\` (new)"
  else
    echo "\`${curr}\`"
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
    gh_retry gh release view "${new_tag}" --repo "${ORG}/${repo}" \
      --json body --jq '.body' | format_notes_body "${repo}" || true
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
    gh_retry gh release view "${new_tag}" --repo "${ORG}/${repo}" \
      --json body --jq '.body' | format_notes_body "${repo}" || true
    echo ""
    return
  fi

  if [[ -n "${tags}" ]]; then
    # Keep the per-tag marker only when aggregating multiple versions; for a single
    # version the component heading already names it.
    local tag_count
    tag_count=$(grep -c . <<< "${tags}")
    while IFS= read -r tag; do
      (( tag_count > 1 )) && echo "#### ${tag}"
      gh_retry gh release view "${tag}" --repo "${ORG}/${repo}" \
        --json body --jq '.body' | format_notes_body "${repo}" || true
      echo ""
    done <<< "${tags}"
  fi
}

# ── Output generators ──────────────────────────────────────────────────

# Echoes one "display|prev|curr|repo|tag_prefix" line per changed, repo-deduplicated
# first-party (transpara) component, in COMPONENTS order. Centralizes the detection
# shared by the summary table and the per-component sections.
# Globals: COMPONENTS
collect_changed_transpara() {
  local curr_yaml="$1" prev_yaml="$2"
  local -A seen
  local entry yaml_path name repo comp_type tag_prefix curr_ver prev_ver
  local display count check check_repo
  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r yaml_path name repo comp_type tag_prefix <<< "${entry}"
    [[ "${comp_type}" != "transpara" ]] && continue
    if [[ "${repo}" != "—" ]] && [[ -n "${seen[${repo}]+_}" ]]; then continue; fi

    curr_ver=$(get_version "${curr_yaml}" "${yaml_path}")
    prev_ver=""
    [[ -n "${prev_yaml}" ]] && prev_ver=$(get_version "${prev_yaml}" "${yaml_path}")

    if ! version_changed "${prev_ver}" "${curr_ver}"; then
      [[ "${repo}" != "—" ]] && seen[${repo}]=1
      continue
    fi

    # Multi-image repos (e.g. tcalc) share one repo; show the repo name once.
    display="${name}"
    count=0
    for check in "${COMPONENTS[@]}"; do
      IFS='|' read -r _ _ check_repo _ _ <<< "${check}"
      [[ "${check_repo}" == "${repo}" ]] && count=$((count + 1))
    done
    (( count > 1 )) && display="${repo}"

    [[ "${repo}" != "—" ]] && seen[${repo}]=1
    echo "${display}|${prev_ver}|${curr_ver}|${repo}|${tag_prefix}"
  done
}

# Emits a brief platform-level rollup at the top of the document: the installer
# version transition and the first/third-party change counts. Pure templating of
# already-computed state (no model, no extra network).
# Arguments: $1 = changed-components file, $2 = curr versions.yaml,
#            $3 = prev versions.yaml (may be empty), $4 = prev tag, $5 = target tag
generate_release_summary() {
  local changed_file="$1" curr_yaml="$2" prev_yaml="$3" prev_tag="$4" target_tag="$5"
  local security_findings="$6"

  local fp_count=0
  [[ -s "${changed_file}" ]] && fp_count=$(grep -c . "${changed_file}")

  local tp_count=0 entry yaml_path comp_type cur prev
  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r yaml_path _ _ comp_type _ <<< "${entry}"
    [[ "${comp_type}" != "thirdparty" ]] && continue
    cur=$(get_version "${curr_yaml}" "${yaml_path}")
    prev=""
    [[ -n "${prev_yaml}" ]] && prev=$(get_version "${prev_yaml}" "${yaml_path}")
    version_changed "${prev}" "${cur}" && tp_count=$((tp_count + 1))
  done

  echo "### Release Summary"
  echo ""
  if [[ -n "${prev_tag}" ]]; then
    echo "- Platform installer: \`${prev_tag}\` → \`${target_tag}\`"
  else
    echo "- Platform installer: \`${target_tag}\` (initial release)"
  fi
  echo "- First-party components changed: ${fp_count}"
  echo "- Third-party components changed: ${tp_count}"
  if [[ -n "${security_findings}" ]]; then
    echo "- Security keyword scan: matches detected (see Security-Relevant Changes below)"
  else
    echo "- Security keyword scan: no matches detected"
  fi
  echo ""
}

# Emits the top index table mapping each changed first-party component to its version
# transition. Reads the lines produced by collect_changed_transpara.
# Arguments: $1 = path to the changed-components file
generate_summary_table() {
  local changed_file="$1"
  if [[ ! -s "${changed_file}" ]]; then
    echo "_No first-party component changes in this release._"
    echo ""
    return
  fi
  echo "| Component | Previous | Current |"
  echo "|-----------|----------|---------|"
  local display prev_ver curr_ver repo tag_prefix prev_cell
  while IFS='|' read -r display prev_ver curr_ver repo tag_prefix; do
    [[ -z "${display}" ]] && continue
    if [[ -n "${prev_ver}" ]] && [[ "${prev_ver}" != "null" ]]; then
      prev_cell="\`${prev_ver}\`"
    else
      prev_cell="(new)"
    fi
    echo "| ${display} | ${prev_cell} | \`${curr_ver}\` |"
  done < "${changed_file}"
  echo ""
}

# Emits one section per changed first-party component: a single self-describing H3
# (name + version transition) followed by the verbatim upstream notes. Fetches run in
# parallel; sections are assembled in the order of the changed-components file.
# Arguments: $1 = workdir, $2 = path to the changed-components file
generate_transpara_sections() {
  local workdir="$1" changed_file="$2"

  mkdir -p "${workdir}/notes"
  local pids=() names=()
  local display prev_ver curr_ver repo tag_prefix

  while IFS='|' read -r display prev_ver curr_ver repo tag_prefix; do
    [[ -z "${display}" ]] && continue
    names+=("${display}")
    {
      echo "### ${display}: $(format_version_line "${prev_ver}" "${curr_ver}")"
      echo ""
      fetch_notes_between "${repo}" "${prev_ver}" "${curr_ver}" "${tag_prefix}"
    } > "${workdir}/notes/${display}.md" 2>"${workdir}/notes/${display}.err" &
    pids+=($!)
  done < "${changed_file}"

  for pid in "${pids[@]}"; do
    wait "${pid}" 2>/dev/null || true
  done

  local name err_file notes_file
  for name in "${names[@]}"; do
    err_file="${workdir}/notes/${name}.err"
    if [[ -s "${err_file}" ]]; then
      warn "Error fetching notes for ${name}: $(cat "${err_file}")"
    fi
  done

  # Assemble in original order
  for name in "${names[@]}"; do
    notes_file="${workdir}/notes/${name}.md"
    [[ -f "${notes_file}" ]] && cat "${notes_file}"
  done
}

# Scans fetched component notes for security keywords. Echoes the findings block
# (matching lines grouped by component), or nothing when there are no matches.
# Arguments: $1 = workdir (with a notes/ subdirectory populated by the fetch step)
scan_security() {
  local notes_dir="$1/notes"
  local pattern="CVE-|GHSA-|security|vulnerab|auth.*fix|XSS|CSRF|injection|privilege.escalat|access.control"
  local findings="" notes_file comp_name matches
  [[ -d "${notes_dir}" ]] || return
  for notes_file in "${notes_dir}"/*.md; do
    [[ -f "${notes_file}" ]] || continue
    comp_name=$(basename "${notes_file}" .md)
    matches=$(grep -iE "${pattern}" "${notes_file}" 2>/dev/null || true)
    if [[ -n "${matches}" ]]; then
      findings+="**${comp_name}**"$'\n'"${matches}"$'\n\n'
    fi
  done
  printf '%s' "${findings}"
}

# Renders the security section from precomputed findings. Emits nothing when empty;
# the all-clear state is reported in the Release Summary instead.
# Arguments: $1 = findings block from scan_security
render_security() {
  local findings="$1"
  [[ -z "${findings}" ]] && return
  echo "### Security-Relevant Changes"
  echo ""
  echo "> Identified by keyword matching (CVE, security, vulnerability, auth fix, etc.); not a vulnerability assessment, review each item for applicability."
  echo ""
  echo "${findings}"
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

  # Render only when something changed; the all-clear is reported in the Release Summary.
  [[ -z "${rows}" ]] && return
  echo "### Infrastructure & Third-Party"
  echo ""
  echo "| Component | Previous | Current |"
  echo "|-----------|----------|---------|"
  echo -n "${rows}"
  echo ""
}

generate_version_status() {
  local curr_yaml="$1" workdir="$2" target_tag="$3"

  echo "### Version Status"
  echo ""

  # Check tinstaller + all transpara components for "behind latest"
  # Include tag_prefix so we can strip it when comparing versions.
  # tinstaller arrives via COMPONENTS (ensured first), like any other component.
  local check_entries=()
  local -A seen_repos_status
  for entry in "${COMPONENTS[@]}"; do
    IFS='|' read -r yaml_path name repo comp_type tag_prefix <<< "${entry}"
    [[ "${comp_type}" != "transpara" ]] && continue
    if [[ "${repo}" != "—" ]] && [[ -n "${seen_repos_status[${repo}]+_}" ]]; then continue; fi
    [[ "${repo}" != "—" ]] && seen_repos_status[${repo}]=1
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
    echo "Bundled versions differing from latest (may be intentionally pinned). Full manifest: [versions.yaml](https://github.com/${ORG}/${INSTALLER_REPO}/releases/tag/${target_tag})."
    echo ""
    echo "| Component | Bundled | Latest Available |"
    echo "|-----------|---------|------------------|"
    echo -n "${behind}"
  else
    echo "All bundled component versions match their latest available releases."
  fi
  echo ""
}

# Emits the compatibility ranges (from compatibility.yaml) and links to the release
# manifests. Only links assets that actually exist in this release; renders nothing
# when neither a compatibility table nor any manifest is available.
# Arguments: $1 = compatibility.yaml path (may be empty), $2 = assets list file,
#            $3 = target tag
generate_compatibility_section() {
  local compat_yaml="$1" assets_file="$2" target_tag="$3"
  local base="https://github.com/${ORG}/${INSTALLER_REPO}/releases/download/${target_tag}"

  # Link only the manifests that are actually attached to this release.
  local links="" name
  for name in compatibility.yaml versions.yaml components.yaml; do
    grep -qx "${name}" "${assets_file}" 2>/dev/null && links+="[${name}](${base}/${name}) · "
  done

  local have_table="false"
  [[ -n "${compat_yaml}" && -f "${compat_yaml}" ]] && have_table="true"
  [[ "${have_table}" == "false" && -z "${links}" ]] && return

  echo "### Compatibility"
  echo ""

  if [[ "${have_table}" == "true" ]]; then
    echo "Tested ranges for core infrastructure components:"
    echo ""
    echo "| Component | Minimum | Max minor |"
    echo "|-----------|---------|-----------|"
    local key min max
    while IFS= read -r key; do
      [[ -z "${key}" ]] && continue
      min=$(yq e ".[\"${key}\"].min // \"—\"" "${compat_yaml}" | tr -d '"')
      max=$(yq e ".[\"${key}\"].max_minor // \"—\"" "${compat_yaml}" | tr -d '"')
      echo "| ${key} | \`${min}\` | \`${max}\` |"
    done < <(yq e 'keys | .[]' "${compat_yaml}")
    echo ""
  fi

  [[ -n "${links}" ]] && { echo "Manifests: ${links% · }"; echo ""; }
}

# Lists the CycloneDX SBOM assets for the release as links. Self-adjusting: filters the
# live asset inventory by the .sbom.cdx.json suffix, so new SBOMs appear automatically.
# Arguments: $1 = assets list file, $2 = target tag
generate_sbom_section() {
  local assets_file="$1" target_tag="$2"
  local base="https://github.com/${ORG}/${INSTALLER_REPO}/releases/download/${target_tag}"

  local sboms
  sboms=$(grep '\.sbom\.cdx\.json$' "${assets_file}" 2>/dev/null || true)
  [[ -z "${sboms}" ]] && return

  echo "### Software Bill of Materials"
  echo ""
  echo "CycloneDX SBOMs attached to this release:"
  local name
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    echo "* [${name}](${base}/${name})"
  done <<< "${sboms}"
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

  # Load component registry from components.yaml (single source of truth)
  log "Downloading components.yaml for ${target_tag} ..."
  if gh release download "${target_tag}" --repo "${ORG}/${INSTALLER_REPO}" \
      --pattern "components.yaml" --dir "${workdir}/current" 2>/dev/null; then
    load_components "${workdir}/current/components.yaml"
    log "Loaded ${#COMPONENTS[@]} components from components.yaml"
  else
    warn "components.yaml not found in release ${target_tag} — using built-in fallback"
    load_components_fallback
  fi

  # Release asset inventory, used for manifest/SBOM links and the compatibility table.
  local assets_file="${workdir}/assets.txt"
  gh_retry gh release view "${target_tag}" --repo "${ORG}/${INSTALLER_REPO}" \
    --json assets --jq '.assets[].name' > "${assets_file}" 2>/dev/null || true
  local compat_yaml=""
  if grep -qx "compatibility.yaml" "${assets_file}" 2>/dev/null \
      && gh release download "${target_tag}" --repo "${ORG}/${INSTALLER_REPO}" \
        --pattern "compatibility.yaml" --dir "${workdir}/current" 2>/dev/null; then
    compat_yaml="${workdir}/current/compatibility.yaml"
  fi

  # Ensure tinstaller is present and leads, regardless of the asset's contents.
  ensure_tinstaller_first

  # Detect changed first-party components once; reused by the summary table and the
  # per-component sections so detection is not duplicated.
  local changed_file="${workdir}/changed.tsv"
  collect_changed_transpara "${curr_yaml}" "${prev_yaml}" > "${changed_file}"

  # Use the target tag's actual publish date, not the script's run date (which drifts
  # on re-runs and local runs). Fall back to today (UTC) only if the release is not
  # yet published. Not createdAt: that is the shared commit date across tags.
  local release_date
  release_date=$(gh_retry gh release view "${target_tag}" --repo "${ORG}/${INSTALLER_REPO}" \
    --json publishedAt --jq '.publishedAt')
  release_date="${release_date%%T*}"
  [[ -z "${release_date}" || "${release_date}" == "null" ]] && release_date=$(date -u +%Y-%m-%d)

  # Fetch component notes first (this populates ${workdir}/notes and captures the
  # rendered sections); the Release Summary's security state needs the notes scanned
  # up front, before anything is emitted.
  local sections_md="${workdir}/sections.md"
  : > "${sections_md}"
  [[ -s "${changed_file}" ]] \
    && generate_transpara_sections "${workdir}" "${changed_file}" > "${sections_md}"
  local security_findings
  security_findings=$(scan_security "${workdir}")

  # Generate the release notes document. cat -s collapses any incidental double
  # blank lines so the page stays dense.
  log "Generating release notes → ${OUTPUT_FILE}"

  {
    echo "## Transpara Platform ${target_tag} Release Notes"
    echo ""
    echo "Released: ${release_date} | Previous: \`${prev_tag:-initial}\` | Current: \`${target_tag}\`"
    echo ""

    generate_release_summary "${changed_file}" "${curr_yaml}" "${prev_yaml}" \
      "${prev_tag}" "${target_tag}" "${security_findings}"
    generate_summary_table "${changed_file}"

    if [[ -s "${sections_md}" ]]; then
      echo "---"
      echo ""
      cat "${sections_md}"
    fi

    # Detail sections appear only when they carry content; the all-clear states are
    # reported in the Release Summary above.
    echo "---"
    echo ""
    render_security "${security_findings}"
    generate_thirdparty_table "${curr_yaml}" "${prev_yaml}"
    generate_version_status "${curr_yaml}" "${workdir}" "${target_tag}"
    generate_compatibility_section "${compat_yaml}" "${assets_file}" "${target_tag}"
    generate_sbom_section "${assets_file}" "${target_tag}"
  } | cat -s > "${OUTPUT_FILE}"

  # Expose target tag for CI
  if [[ "${IS_CI}" == "true" ]] && [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "target_tag=${target_tag}" >> "${GITHUB_ENV}"
  fi

  log "Done. Output written to ${OUTPUT_FILE}"
}

main "$@"
