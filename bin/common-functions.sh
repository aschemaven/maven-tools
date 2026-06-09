# shellcheck shell=bash

# NAME
#   common-functions.sh - Shell library for managing and building Maven projects
#
# SYNOPSIS
#   Source this file in your shell script to gain access to helper functions for handling Maven projects.
#
# DESCRIPTION
#   This file is a shell script library intended to be sourced by other scripts.
#   It provides helper functions such as `exec_mvn` to build or handle Maven-based projects.
#   The script processes multiple projects at once and generates logs for each task performed.
#
# INPUT VARIABLES
#   - dir: (Required, injected by caller) The directory path injected by the caller. This is used to determine the root directory.
#   - ONLY_MAVEN: (Optional) If set to true (default), only Maven-based projects will be processed.
#   - MAVEN_PROJECTS_DIR: (Optional) Directory containing Maven project checkouts, defaults to `maven`.
#   - PROJECTS: (Optional) Space-separated list of projects to process, defaulting to the contents of `${MAVEN_PROJECTS_DIR}/.repo/project.list`.
#   - PREVIEW_LOGLINES: (Optional) Number of log lines to preview in case of a build failure.
#   - FAIL_FAST: (Optional) If set to true, the script will exit immediately upon a build failure.
#
# OUTPUT VARIABLES
#   - root: Absolute path to the parent directory of the given `dir`.
#   - noof_projects: Count of the projects being processed.
#   - Logs are stored per project under `logs/<project>/<task>-<pid>.log`.
#
# FUNCTIONS
#   exec_mvn(project, task, counter, opts, goals)
#       Executes the Maven build for a given project.
#       - project: Path to the Maven project directory.
#       - task: A descriptive name for the task (used in logs).
#       - counter: Current project number being processed.
#       - opts: Additional options for the Maven command.
#       - goals: Space-separated list of Maven goals to execute.
#
#       The function checks for the presence of `pom.xml` to identify a Maven project
#       and determines whether to use the Maven wrapper (`mvnw`) if available.
#       Logs build results (succeeded/failed) in the appropriate log directory.
#

: "${ONLY_MAVEN:=true}"
: "${MAVEN_PROJECTS_DIR:=maven}"
: "${SETTINGS:=${PWD}/settings.xml}"
# Find a Maven binary by version, searching known installation locations.
# Checks (in order): SDKman, GitHub Actions tool-cache, MAVEN_HOMES (custom).
# Returns the path to the mvn binary, or empty string if not found.
find_mvn_by_version() {
  local version="$1"
  local candidate

  # SDKman (local development)
  candidate="${HOME}/.sdkman/candidates/maven/${version}/bin/mvn"
  if [[ -x "${candidate}" ]]; then
    echo "${candidate}"
    return
  fi

  # GitHub Actions tool-cache (stCarolas/setup-maven)
  if [[ -n "${RUNNER_TOOL_CACHE:-}" ]]; then
    candidate="${RUNNER_TOOL_CACHE}/maven/${version}/x64/bin/mvn"
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return
    fi
  fi

  # Custom location via MAVEN_HOMES (colon-separated list of base dirs)
  # Each dir is expected to contain <version>/bin/mvn
  local IFS=':'
  for base in ${MAVEN_HOMES:-}; do
    candidate="${base}/${version}/bin/mvn"
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return
    fi
  done
}

# Select the appropriate Maven binary based on project path.
# Maven 4 projects are identified by having "-4/" in their path
# (e.g. plugins/core-4/*, plugins/packaging-4/*).
# The required Maven version is read from <mavenVersion> in pom.xml.
# MAVEN4_VERSION env var can override the auto-detected version.
select_mvn() {
  local project="$1"
  local project_dir="$2"
  if [[ "${project}" == *-4/* ]]; then
    local mvn4_version="${MAVEN4_VERSION:-}"
    if [[ -z "${mvn4_version}" && -r "${project_dir}/pom.xml" ]]; then
      mvn4_version=$(sed -n 's/.*<mavenVersion>\(.*\)<\/mavenVersion>.*/\1/p' "${project_dir}/pom.xml" | head -1)
    fi
    if [[ -z "${mvn4_version}" ]]; then
      echo "WARNING: ${project}: no <mavenVersion> found in pom.xml and MAVEN4_VERSION not set, falling back to system mvn" >&2
      echo "mvn"
      return
    fi
    local mvn4_bin
    mvn4_bin=$(find_mvn_by_version "${mvn4_version}")
    if [[ -n "${mvn4_bin}" ]]; then
      echo "${mvn4_bin}"
      return
    fi
    echo "WARNING: ${project}: Maven ${mvn4_version} not found in any known location, falling back to system mvn" >&2
  fi
  echo "mvn"
}

# shellcheck disable=SC2034 disable=SC2154
# root is used in other scripts, dir is injected by the caller
root=$(readlink -f "${dir}/..")
[[ -z "${PROJECTS:-}" ]] && PROJECTS="$(cat ${root}/${MAVEN_PROJECTS_DIR}/.repo/project.list)"

# Read non-comment, non-blank lines from a file as a space-separated list.
# Tolerates files that only contain comments (grep returns 1) and missing
# files without aborting the surrounding set -e / pipefail script.
read_project_list_file() {
  local file="$1"
  [[ -r "${file}" ]] || { echo ""; return; }
  grep -vE '^[[:space:]]*(#|$)' "${file}" 2>/dev/null | tr '\n' ' ' || true
}

# Load default EXCLUDE_PROJECTS from exclude-projects.txt unless the caller
# has explicitly set the variable (including to the empty string, which
# disables exclusion entirely).
if [[ -z "${EXCLUDE_PROJECTS+x}" ]]; then
  EXCLUDE_PROJECTS=$(read_project_list_file "${root}/exclude-projects.txt")
fi

# Load default DEVELOCITY_SKIP_PROJECTS from develocity-skip-projects.txt.
# Same convention as EXCLUDE_PROJECTS: unset -> read file; empty string -> off.
if [[ -z "${DEVELOCITY_SKIP_PROJECTS+x}" ]]; then
  DEVELOCITY_SKIP_PROJECTS=$(read_project_list_file "${root}/develocity-skip-projects.txt")
fi

# Load default FLAKY_PROJECTS from flaky-projects.txt.
# Same convention as above. FLAKY_RETRY_DEFAULT controls how many automatic
# retries listed projects get when no --retry override is in effect.
if [[ -z "${FLAKY_PROJECTS+x}" ]]; then
  FLAKY_PROJECTS=$(read_project_list_file "${root}/flaky-projects.txt")
fi
: "${FLAKY_RETRY_DEFAULT:=2}"

# Load default ISOLATED_M2_PROJECTS from isolated-m2-projects.txt.
# Projects on this list get a dedicated local Maven repository
# (${root}/.m2-isolated/<slug>/) instead of the shared M2_REPO,
# isolating their fork-happy IT infrastructures.
if [[ -z "${ISOLATED_M2_PROJECTS+x}" ]]; then
  ISOLATED_M2_PROJECTS=$(read_project_list_file "${root}/isolated-m2-projects.txt")
fi

# Load default LRM_SPLIT_SKIP_PROJECTS from lrm-split-skip-projects.txt.
# Projects on this list get -Daether.enhancedLocalRepository.split=false
# AND auto-isolation (so their flat-layout artefacts stay contained).
if [[ -z "${LRM_SPLIT_SKIP_PROJECTS+x}" ]]; then
  LRM_SPLIT_SKIP_PROJECTS=$(read_project_list_file "${root}/lrm-split-skip-projects.txt")
fi

# Filter PROJECTS by EXCLUDE_PROJECTS, preserving order. The exclude list
# applies to both the default project.list and a user-supplied PROJECTS
# value -- explicit override via EXCLUDE_PROJECTS="" disables filtering.
if [[ -n "${EXCLUDE_PROJECTS// /}" ]]; then
  excluded_list=""
  filtered=""
  for project in ${PROJECTS}; do
    skip=false
    for excl in ${EXCLUDE_PROJECTS}; do
      [[ "${project}" == "${excl}" ]] && skip=true && break
    done
    if ${skip}; then
      excluded_list+="${project} "
    else
      filtered+="${project} "
    fi
  done
  if [[ -n "${excluded_list}" ]]; then
    echo "Excluding project(s) via EXCLUDE_PROJECTS: ${excluded_list% }" >&2
  fi
  PROJECTS="${filtered% }"
fi

noof_projects=$(echo "${PROJECTS}" | wc -w | sed -e 's/ //g')
counter=0

# Only set maven.repo.local if not already configured in MAVEN_OPTS
MAVEN_REPO_LOCAL_OPT=""
if [[ ! "${MAVEN_OPTS:-}" =~ maven.repo.local ]]; then
  MAVEN_REPO_LOCAL_OPT="-Dmaven.repo.local=${root}/.m2/repository"
fi

# Enable Maven Resolver's Enhanced LRM split mode (resolver 1.9+ / 2.x).
# Layout: ${maven.repo.local}/{installed,cached}/{releases,snapshots}/
# Lets us purge installed/snapshots/ cleanly without nuking the cached
# Maven Central artifacts, and makes the kind of cross-pollution that
# caused the mvnd/resolver-2.0.18 mystery directly visible in the layout
# (a locally-built SNAPSHOT lives in installed/snapshots/, a downloaded
# Central artifact in cached/releases/ -- never mixed).
#
# Properties go into MAVEN_OPTS (not just our own mvn CLI) so child
# Maven processes spawned by maven-invoker-plugin (in integration
# tests of core/3.x/its-3, core/3.x/resolver-1, ...) inherit them.
# JVM system properties don't propagate to child Java processes;
# env vars do, and MAVEN_OPTS is what every mvn shell launcher reads.
#
# Set MAVEN_LRM_SPLIT=false to opt out.
if [[ "${MAVEN_LRM_SPLIT:-true}" == "true" ]]; then
  if [[ ! "${MAVEN_OPTS:-}" =~ aether\.enhancedLocalRepository\.split ]]; then
    export MAVEN_OPTS="${MAVEN_OPTS:-} -Daether.enhancedLocalRepository.split=true -Daether.enhancedLocalRepository.splitLocal=true -Daether.enhancedLocalRepository.splitRemote=true"
  fi
fi

# List workspace pollution for a single project on stdout (one item per line,
# path relative to the project directory).
#
# An item is considered pollution if it would trip Apache RAT or otherwise
# leak into the build despite not being part of the project's source tree:
#   - jqassistant/store/  (leftover from earlier central-mode jQA runs)
#   - untracked root-level files that the project's own .gitignore does
#     NOT exclude. Files matched by the project .gitignore (e.g. shade's
#     dependency-reduced-pom.xml) are expected build outputs that
#     maven-parent's RAT config already accepts -- they are not pollution.
#     Files matched only by the *user's global* gitignore (e.g. .sdkmanrc)
#     still count: RAT does not honor any gitignore so they trip license
#     checks.
#   - .mvn/develocity.xml and .mvn/extensions.xml that are byte-identical
#     to our Develocity template AND USE_DEVELOCITY is not currently active
#     (stale hardlinks from earlier USE_DEVELOCITY=true runs). Project-owned
#     .mvn/extensions.xml stays untouched.
#
# target/ is excluded: clean verify will handle it; listing it would be noisy.
list_workspace_pollution() {
  local project_dir="$1"
  [[ -d "${project_dir}/jqassistant/store" ]] && echo "jqassistant/store"
  if [[ "${USE_DEVELOCITY:-false}" != "true" ]]; then
    for f in develocity.xml extensions.xml; do
      local own="${project_dir}/.mvn/${f}"
      local tmpl="${root}/develocity/${f}"
      if [[ -f "${own}" && -f "${tmpl}" ]] && cmp -s "${own}" "${tmpl}"; then
        echo ".mvn/${f}"
      fi
    done
  fi
  if git -C "${project_dir}" rev-parse --git-dir >/dev/null 2>&1; then
    local candidates
    candidates=$(git -C "${project_dir}" ls-files --others -z 2>/dev/null \
      | tr '\0' '\n' \
      | grep -v '/' \
      | grep -vx 'target' \
      || true)
    [[ -z "${candidates}" ]] && return
    while IFS= read -r f; do
      [[ -z "${f}" ]] && continue
      # check-ignore exits 0 if a gitignore rule matches; setting
      # core.excludesFile=/dev/null disables the user's global gitignore,
      # so only the project's own .gitignore counts. Matching files are
      # expected build outputs and skipped.
      if ! git -C "${project_dir}" \
            -c core.excludesFile=/dev/null \
            check-ignore -q "${f}" 2>/dev/null; then
        echo "${f}"
      fi
    done <<< "${candidates}"
  fi
}

# Pre-flight check across all PROJECTS. With do_clean="true", removes any
# pollution found and prints a report. Otherwise prints the findings and
# exits non-zero so the caller can fix things before kicking off a build.
check_workspaces() {
  local do_clean="$1"
  local polluted=0
  local report=""
  for project in ${PROJECTS}; do
    local project_dir="${root}/${MAVEN_PROJECTS_DIR}/${project}"
    [[ ! -d "${project_dir}" ]] && continue
    [[ ! -r "${project_dir}/pom.xml" ]] && continue
    local items
    items=$(list_workspace_pollution "${project_dir}")
    [[ -z "${items}" ]] && continue
    polluted=$((polluted + 1))
    report+="  ${project}:"$'\n'
    while IFS= read -r item; do
      report+="    ${item}"$'\n'
      if [[ "${do_clean}" == "true" ]]; then
        /bin/rm -rf "${project_dir:?}/${item}"
      fi
    done <<< "${items}"
  done
  [[ ${polluted} -eq 0 ]] && return 0
  if [[ "${do_clean}" == "true" ]]; then
    echo "Cleaned workspace pollution in ${polluted} project(s):" >&2
    printf '%s' "${report}" >&2
  else
    echo "ERROR: workspace pollution detected in ${polluted} project(s)." >&2
    echo "       The following items would trip RAT or pollute the build:" >&2
    printf '%s' "${report}" >&2
    echo "       Re-run with '--clean' as the first argument to remove them." >&2
    exit 1
  fi
}

exec_mvn() {
  project=$1
  shift
  task=$1
  shift
  counter=$1
  shift
  opts=$1
  shift
  goals=${*}

  # Full path to project directory (under MAVEN_PROJECTS_DIR)
  project_dir="${root}/${MAVEN_PROJECTS_DIR}/${project}"

  if ! test -r "${project_dir}/pom.xml" && eval "${ONLY_MAVEN}"; then
    echo "${project} is not a Maven project (${counter}/${noof_projects})"
    return
  fi

  test ! -d "${project_dir}" && echo "${project} does not exist" >&2 && return
  mkdir -p "${root}/logs/${project}"

  # When 'clean' is part of the requested goals, recursively wipe
  # build-output target/ directories before invoking Maven. Apache
  # Maven aggregator POMs (inherited from maven-parent) run
  # apache-rat-plugin in the process-resources phase, BEFORE child
  # modules get their own `clean`. Stale target/ content from previous
  # local builds then trips RAT in the aggregator. Upstream CI doesn't
  # see this because fresh runners start with empty workspaces.
  #
  # Exclude target/ directories under */src/* -- several Maven plugin
  # projects ship mock-project fixtures (with their own target/) under
  # src/test/resources/ that the tests rely on. Wiping those breaks
  # maven-install-plugin, maven-rar-plugin, maven-clean-plugin, and
  # friends.
  if [[ " ${goals} " == *" clean "* ]]; then
    find "${project_dir}" -type d -name target -not -path '*/src/*' -prune -exec /bin/rm -rf {} + 2>/dev/null || true
  fi

  ext=""
  case "${project}" in
  "core/maven")
    ext=" (no extension)"
    ;;
  *)
    if test "${USE_DEVELOCITY:-false}" = "true"; then
      # Skip if the project has its own .mvn/extensions.xml that differs
      # from our Develocity template -- overwriting it would corrupt
      # tracked content (e.g. plugins/core/surefire ships a tracked but
      # mostly-commented extensions.xml; Maven 4 core has build-cache
      # extensions there).
      own_ext="${project_dir}/.mvn/extensions.xml"
      tmpl_ext="${root}/develocity/extensions.xml"
      if [[ -f "${own_ext}" ]] && ! cmp -s "${own_ext}" "${tmpl_ext}"; then
        ext=" (Develocity skipped: project has own .mvn/extensions.xml)"
      else
        mkdir -p "${project_dir}/.mvn"
        ln -f "${root}/develocity"/*.xml "${project_dir}/.mvn"
      fi
    fi
    ;;
  esac

  # Per-project Develocity deactivation: append -Ddevelocity.deactivate=true
  # for projects listed in DEVELOCITY_SKIP_PROJECTS. Works even if the
  # extension is loaded transitively (parent POM, SDKman, auto-injection).
  for skip_p in ${DEVELOCITY_SKIP_PROJECTS:-}; do
    if [[ "${project}" == "${skip_p}" ]]; then
      opts="${opts} -Ddevelocity.deactivate=true"
      ext="${ext} (Develocity deactivated)"
      break
    fi
  done

  # Per-project LRM split-skip: some projects have tests hard-coded to
  # the flat local-repo layout (e.g. plexus/components/compiler's
  # AspectJCompilerTest asserts on ${maven.repo.local}/commons-lang/...).
  # Disable Enhanced LRM split via CLI -D (overrides the MAVEN_OPTS
  # exported true). Force auto-isolation so the resulting flat-layout
  # artefacts do not pollute the shared M2_REPO.
  local force_isolation=false
  for split_skip_p in ${LRM_SPLIT_SKIP_PROJECTS:-}; do
    if [[ "${project}" == "${split_skip_p}" ]]; then
      opts="${opts} -Daether.enhancedLocalRepository.split=false"
      ext="${ext} (LRM split disabled)"
      force_isolation=true
      break
    fi
  done

  # Per-project isolated local Maven repository: for projects whose
  # IT infrastructures spawn fresh Maven / daemon processes that
  # bypass MAVEN_OPTS and pollute the shared M2_REPO with flat-layout
  # artifacts (mvnd, Maven integration testing, ...), and implicitly
  # for any project on the LRM split-skip list above. CLI
  # -Dmaven.repo.local overrides whatever MAVEN_OPTS configured.
  local is_isolated=${force_isolation}
  if ! ${is_isolated}; then
    for isolated_p in ${ISOLATED_M2_PROJECTS:-}; do
      if [[ "${project}" == "${isolated_p}" ]]; then
        is_isolated=true
        break
      fi
    done
  fi
  if ${is_isolated}; then
    local iso_path="${root}/.m2-isolated/${project//\//--}"
    mkdir -p "${iso_path}"
    opts="${opts} -Dmaven.repo.local=${iso_path}"
    ext="${ext} (isolated M2)"
  fi

  mvn_info=""
  if test -r "${project_dir}/mvnw"; then
    mvn="./mvnw"
    mvn_info="with wrapper"
  else
    mvn=$(select_mvn "${project}" "${project_dir}")
    if [[ "${mvn}" != "mvn" ]]; then
      local detected_version
      detected_version=$(echo "${mvn}" | sed 's|.*/maven/\([^/]*\)/.*|\1|')
      mvn_info="without wrapper (using Maven ${detected_version})"
    else
      mvn_info="without wrapper"
    fi
  fi
  # Decide retry budget. --retry on the CLI (RETRY_CLI) wins and applies
  # to ALL projects; without it, projects listed in FLAKY_PROJECTS get
  # FLAKY_RETRY_DEFAULT automatic retries; all others get 0.
  local is_flaky=false
  for fp in ${FLAKY_PROJECTS:-}; do
    if [[ "${project}" == "${fp}" ]]; then
      is_flaky=true
      break
    fi
  done
  local max_retries=0
  if [[ -n "${RETRY_CLI:-}" ]]; then
    max_retries="${RETRY_CLI}"
  elif ${is_flaky}; then
    max_retries="${FLAKY_RETRY_DEFAULT}"
  fi

  logs="${root}/logs/${project}/${task}-$$-${counter}.log"
  echo -n "${project} (${counter}/${noof_projects}), a Maven project ${mvn_info}, build (logs: '${logs}') "
  set +e
  local attempt=0
  local current_logs
  while :; do
    if [[ ${attempt} -eq 0 ]]; then
      current_logs="${logs}"
    else
      current_logs="${logs%.log}-retry${attempt}.log"
    fi
    (
      cd "${project_dir}"
      # shellcheck disable=SC2086
      ${mvn} -B -s "${SETTINGS}" ${opts} ${goals} 2>&1
    ) > "${current_logs}"
    status="${?}"
    [[ ${status} -eq 0 ]] && break
    [[ ${attempt} -ge ${max_retries} ]] && break
    attempt=$((attempt + 1))
  done
  local retry_tag=""
  if [[ ${attempt} -eq 1 ]]; then
    retry_tag=" after 1 retry"
  elif [[ ${attempt} -gt 1 ]]; then
    retry_tag=" after ${attempt} retries"
  fi
  if test ${status} -ne 0; then
    echo "failed${retry_tag}${ext}"
    test "${PREVIEW_LOGLINES:-0}" -gt 0 && tail -"${PREVIEW_LOGLINES}" "${current_logs}"
    if eval "${FAIL_FAST:-false}"; then
      echo "Failing fast and current execution failed with status '${status}'"
      exit ${status}
    fi
  else
    echo "succeeded${retry_tag}${ext}"
  fi
  set -e
}