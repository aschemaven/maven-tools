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

# --- Parallelism (Phase 4) -------------------------------------------------
# CPU detection (Linux/macOS) for callers that want to scale to the machine.
detect_cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif [[ "$(uname)" == "Darwin" ]]; then
    sysctl -n hw.ncpu
  else
    getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
  fi
}

# Max concurrent build jobs. Default 1 = sequential (historical behaviour, zero
# risk). Set >1 to parallelise. NOTE: concurrent builds may share a local Maven
# repo -- resolver's enhanced-LRM locking + isolated-m2-projects.txt cover the
# worst offenders; run-compat-matrix parallelises over VARIANTS (distinct repos)
# so its cells never collide.
: "${PARALLEL_JOBS:=1}"

# run_parallel <max_jobs> <worker_fn> <item> [item ...]
# Runs worker_fn for each item, at most <max_jobs> concurrently, invoking it as
#   worker_fn <item> <index>
# Portable to macOS /bin/bash 3.2 (no `wait -n`): throttles by polling the
# running-job count. Each worker should emit its console output as a single
# printf line so concurrent lines stay intact.
run_parallel() {
  local max_jobs="$1"; shift
  local worker="$1"; shift
  local item idx=0
  for item in "$@"; do
    while [ "$(jobs -rp 2>/dev/null | wc -l | tr -d ' ')" -ge "${max_jobs}" ]; do
      sleep 0.2
    done
    idx=$((idx + 1))
    "${worker}" "${item}" "${idx}" &
  done
  wait
}
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
# Central cache base for Maven local repos (.m2, .m2-isolated).
# Defaults to the repo root (unchanged behaviour); set MAVEN_TOOLS_CACHE
# (e.g. ~/wrk/maven via direnv) to share caches across worktrees.
: "${MAVEN_TOOLS_CACHE:=${root}}"
[[ -z "${PROJECTS:-}" ]] && PROJECTS="$(cat "${root}/${MAVEN_PROJECTS_DIR}/.repo/project.list" 2>/dev/null || true)"

# Read non-comment, non-blank lines from a file as a space-separated list.
# Only the FIRST whitespace-separated token of each line is returned, so
# files that carry optional per-line parameters (e.g. flaky-projects.txt:
# "<project> [retries]") still produce a clean project-name list.
# Tolerates files that only contain comments (grep returns 1) and missing
# files without aborting the surrounding set -e / pipefail script.
read_project_list_file() {
  local file="$1"
  [[ -r "${file}" ]] || { echo ""; return; }
  grep -vE '^[[:space:]]*(#|$)' "${file}" 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true
}

# Look up the per-project retry count from flaky-projects.txt. Lines may
# carry an optional second field (the override), e.g. "misc/wagon 3".
# Falls back to FLAKY_RETRY_DEFAULT when no override is set or the file
# is missing.
get_flaky_retry_count() {
  local project="$1"
  local count="${FLAKY_RETRY_DEFAULT}"
  local file="${root}/flaky-projects.txt"
  [[ -r "${file}" ]] || { echo "${count}"; return; }
  local n
  n=$(awk -v p="${project}" '$1 == p {print $2; exit}' "${file}" 2>/dev/null)
  [[ "${n}" =~ ^[0-9]+$ ]] && count="${n}"
  echo "${count}"
}

# Look up per-project extra Maven CLI arguments from extra-mvn-args.txt.
# Format per line: "<project> <arg1> [<arg2> ...]". Returns the rest of
# the line (everything after the project name) or an empty string.
get_extra_mvn_args() {
  local project="$1"
  local file="${root}/extra-mvn-args.txt"
  [[ -r "${file}" ]] || { echo ""; return; }
  awk -v p="${project}" '$1 == p {$1=""; sub(/^[[:space:]]+/, ""); print; exit}' "${file}" 2>/dev/null
}

# --- Variants (compat matrix) ----------------------------------------------
# A "variant" bundles a Maven binary, its own settings.xml and local repo, an
# optional JDK and an optional source branch, all rooted under the
# self-contained directory ${root}/variants/<name>/. Variants are declared in
# variants.txt (columns: <name> <mvn-version> [jdk] [branch]; # and blank
# lines ignored; "-" means "unset" for the optional jdk/branch columns).
#
# These helpers are PURE lookups with no side effects -- exec_mvn wires them
# into the build only when VARIANT is set, so sourcing this file changes
# nothing for normal (variant-less) runs.

# Self-contained root directory of a variant.
variant_root() {
  echo "${root}/variants/$1"
}

# Look up a single column for a variant from variants.txt.
#   variant_field <name> <col>     col: 2=mvn-version 3=jdk 4=branch
# Echoes the empty string if the variant or field is absent, or the field is
# the "-" sentinel.
variant_field() {
  local name="$1" col="$2"
  local file="${root}/variants.txt"
  [[ -r "${file}" ]] || { echo ""; return; }
  local val
  val=$(awk -v n="${name}" -v c="${col}" '$1 == n {print $c; exit}' "${file}" 2>/dev/null)
  [[ "${val}" == "-" ]] && val=""
  echo "${val}"
}

# True if <name> is a declared variant (has a row in variants.txt).
variant_exists() {
  [[ -n "$(variant_field "$1" 2)" ]]
}

# Resolve the mvn binary for a variant, in order:
#   1. variant-local  variants/<name>/maven/bin/mvn  (symlink or built distro)
#   2. find_mvn_by_version <variant mvn-version>
# Echoes the resolved path, or the empty string if neither resolves.
variant_mvn() {
  local name="$1"
  local local_mvn
  local_mvn="$(variant_root "${name}")/maven/bin/mvn"
  if [[ -x "${local_mvn}" ]]; then
    echo "${local_mvn}"
    return
  fi
  local version
  version=$(variant_field "${name}" 2)
  [[ -n "${version}" ]] && find_mvn_by_version "${version}"
}

# Resolve the settings.xml for a variant: its own if present, else fall back
# to the shared ${SETTINGS} template.
variant_settings() {
  local name="$1"
  local s
  s="$(variant_root "${name}")/settings.xml"
  if [[ -r "${s}" ]]; then
    echo "${s}"
  else
    echo "${SETTINGS}"
  fi
}

# Resolve the local Maven repository for a variant (its own repository/ dir).
variant_repo_local() {
  echo "$(variant_root "$1")/repository"
}

# Resolve the JDK major version for a variant (column 3); empty = use default.
variant_jdk() {
  variant_field "$1" 3
}

# Resolve a JAVA_HOME for a JDK major version, preferring SDKman. Picks the
# highest installed build of that major from the preferred vendor (default
# Temurin), e.g. major 21 -> 21.0.10-tem. Echoes the home dir, or the empty
# string if none is found.
#
# The vendor filter exists to keep other vendors OUT, not to support them:
# nothing here targets GraalVM, Zulu or Amazon, but builds of all three sit in
# ~/.sdkman next to Temurin, and a plain "sort -V | tail" hands the build to
# whoever happens to ship the highest patch level. Falls back to any vendor
# rather than returning nothing.
find_java_home() {
  local major="$1" vendor="${2:-tem}"
  [[ -z "${major}" ]] && return
  local base="${HOME}/.sdkman/candidates/java"
  [[ -d "${base}" ]] || return
  local best
  best=$(ls -1 "${base}" 2>/dev/null | grep -E "^${major}([.-]|$)" | grep -E -- "-${vendor}\$" | sort -V | tail -1)
  [[ -z "${best}" ]] && best=$(ls -1 "${base}" 2>/dev/null | grep -E "^${major}([.-]|$)" | sort -V | tail -1)
  [[ -n "${best}" ]] && echo "${base}/${best}"
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

# Load default JDK21_PROJECTS from jdk21-projects.txt. Projects on this list
# get JAVA_HOME pointed at a Java 21 SDKman candidate (configurable via the
# JDK21_HOME env var, default: ~/.sdkman/candidates/java/21.0.10-tem). Used
# for the small set of projects whose source code requires Java 21 while the
# rest of the reactor runs on a lower JDK -- e.g. misc/dist-tool depends on
# HttpClient.AutoCloseable (JDK 21 source feature), and core/resolver
# enforces [21,) on its build environment regardless of bytecode target.
if [[ -z "${JDK21_PROJECTS+x}" ]]; then
  JDK21_PROJECTS=$(read_project_list_file "${root}/jdk21-projects.txt")
fi
# Resolved, not pinned: a literal default silently rots as soon as a newer
# 21.0.x is installed, and every machine then builds against a different JDK.
: "${JDK21_HOME:=$(find_java_home 21)}"

# Baseline JDK for everything that does not carry a per-variant or per-project
# override. Without this the pipeline inherits SDKman's "current", which is a
# per-machine, mutable symlink -- godecane pointed at 25.0.4-tem while
# godestorm pointed at 17.0.7-tem, so the same commit built against different
# JDKs. .sdkmanrc cannot fill this role: "sdk env" only fires from an
# interactive shell hook and never under launchd.
#
# Pin the MAJOR version, resolve the patch level. Set JQA_JDK_HOME to override
# the lookup entirely.
: "${JQA_JDK_MAJOR:=25}"
: "${JQA_JDK_VENDOR:=tem}"
: "${JQA_JDK_HOME:=$(find_java_home "${JQA_JDK_MAJOR}" "${JQA_JDK_VENDOR}")}"
if [[ -n "${JQA_JDK_HOME}" ]]; then
  export JAVA_HOME="${JQA_JDK_HOME}"
  export PATH="${JAVA_HOME}/bin:${PATH}"
else
  echo "WARNING: no JDK ${JQA_JDK_MAJOR} (${JQA_JDK_VENDOR}) under ~/.sdkman;" >&2
  echo "         falling back to inherited JAVA_HOME=${JAVA_HOME:-<unset>}" >&2
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
  MAVEN_REPO_LOCAL_OPT="-Dmaven.repo.local=${MAVEN_TOOLS_CACHE}/.m2/repository"
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
  if true; then
    # In MAVEN_OPTS, so that forked Maven processes inherit it. Measured the
    # hard way: moving this to the command line -- where it is not inherited
    # -- took the matrix from 23 failures to 51, because every forked build
    # using the SHARED repository then looked flat and missed everything
    # installed under the prefix.
    #
    # The cost is invoker integration tests: invoker:install lays out its own
    # per-project test repository by hand, flat, so a forked build that
    # inherits the split cannot find what the invoker put there. Those
    # projects belong on lrm-split-skip-projects.txt, which is what that
    # list is for.
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
  # All positional args go into LOCAL variables. Without `local`, opts
  # in particular accumulates per-project flags (-Daether..., -Dmaven.
  # repo.local=...isolated/<slug>) across loop iterations: the global
  # opts the caller still references gets mutated by each call, so
  # project N inherits the flags of projects 1..N-1.
  local project=$1
  shift
  local task=$1
  shift
  local counter=$1
  shift
  local opts=$1
  shift
  local goals=${*}

  # Full path to project directory (under MAVEN_PROJECTS_DIR)
  project_dir="${root}/${MAVEN_PROJECTS_DIR}/${project}"

  # --- Variant context (compat matrix) -------------------------------------
  # When VARIANT is set, override the Maven binary, settings, local repo, log
  # root and JDK from the named variant (see variants.txt). Without VARIANT
  # every var below keeps its historical default, so behaviour is unchanged.
  local variant="${VARIANT:-}"
  local v_logroot="${root}/logs"
  local v_settings="${SETTINGS}"
  local v_iso_root="${MAVEN_TOOLS_CACHE}/.m2-isolated"
  local v_javahome=""
  if [[ -n "${variant}" ]]; then
    if ! variant_exists "${variant}"; then
      echo "${project} (${counter}/${noof_projects}) skipped: VARIANT '${variant}' not declared in variants.txt" >&2
      return
    fi
    local v_root
    v_root="$(variant_root "${variant}")"
    v_logroot="${v_root}/logs"
    v_settings="$(variant_settings "${variant}")"
    v_iso_root="${v_root}/repository/isolated"
    v_javahome="$(find_java_home "$(variant_jdk "${variant}")")"
  fi

  if ! test -r "${project_dir}/pom.xml" && eval "${ONLY_MAVEN}"; then
    echo "${project} is not a Maven project (${counter}/${noof_projects})"
    return
  fi

  test ! -d "${project_dir}" && echo "${project} does not exist" >&2 && return
  mkdir -p "${v_logroot}/${project}"

  # Variant isolation WITHOUT a second local repository. The shared cache under
  # MAVEN_TOOLS_CACHE stays in place -- a downloaded artefact is the same
  # whoever fetched it -- and only what this variant INSTALLS is kept apart,
  # through the Enhanced LRM's split prefix (split is already enabled above).
  #
  # Giving each variant its own maven.repo.local was the previous approach. It
  # cost 2.7 GB per variant, re-downloaded everything, and broke sibling
  # resolution: "clean verify" installs nothing, so a component needing a
  # sibling SNAPSHOT looked into an essentially empty repository and failed
  # with "Could not find artifact ...-SNAPSHOT". Fourteen of the twenty-one
  # failures in the first full matrix run had that single cause.
  if [[ -n "${variant}" ]]; then
    opts="${opts} -Daether.enhancedLocalRepository.localPrefix=installed/${variant}"
  fi

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

  # Inject a transient .mvn/extensions.xml with the build extensions we want:
  # mimir (Maven Central resolver cache, shared at ~/.mimir) unless
  # USE_MIMIR=false, plus Develocity when USE_DEVELOCITY=true. We *generate*
  # the file (instead of hardlinking a single template) so both can coexist.
  # Projects that ship their own *tracked* .mvn/extensions.xml are left
  # untouched -- overwriting would corrupt tracked content (e.g. surefire's
  # mostly-commented template, Maven 4 core's build-cache extensions).
  # core/maven never gets extensions (its bootstrap build breaks with them).
  ext=""
  local want_mimir="false" want_dev="false"
  [[ "${USE_MIMIR:-true}" == "true" ]] && want_mimir="true"
  [[ "${USE_DEVELOCITY:-false}" == "true" ]] && want_dev="true"
  if [[ "${project}" == "core/maven" ]]; then
    ext=" (no extension)"
  elif [[ "${want_mimir}" == "true" || "${want_dev}" == "true" ]]; then
    local own_ext="${project_dir}/.mvn/extensions.xml"
    if [[ -f "${own_ext}" ]] && \
       git -C "${project_dir}" ls-files --error-unmatch .mvn/extensions.xml >/dev/null 2>&1; then
      ext=" (extensions skipped: project ships tracked .mvn/extensions.xml)"
    else
      mkdir -p "${project_dir}/.mvn"
      # Break any pre-existing hardlink (older runs hardlinked the template
      # here) so the redirect below cannot truncate our source template.
      rm -f "${own_ext}"
      {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        # The ASF licence header is not decoration: apache-rat-plugin 0.15 does
        # not exclude .mvn/ by default, so a header-less file injected here
        # fails the component's own build with "Too many unapproved licenses",
        # which then reads as a Maven incompatibility. It cost one false
        # finding in the first compatibility matrix run
        # (plugins/tools/maven-artifact-plugin) before it was traced back to
        # our own injection.
        cat <<'LICENCE'
<!--
Licensed to the Apache Software Foundation (ASF) under one
or more contributor license agreements.  See the NOTICE file
distributed with this work for additional information
regarding copyright ownership.  The ASF licenses this file
to you under the Apache License, Version 2.0 (the
"License"); you may not use this file except in compliance
with the License.  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing,
software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied.  See the License for the
specific language governing permissions and limitations
under the License.
-->
LICENCE
        echo '<!-- GENERATED by maven-tools (transient, do not commit) -->'
        echo '<extensions>'
        if [[ "${want_mimir}" == "true" ]]; then
          printf '  <extension>\n    <groupId>eu.maveniverse.maven.mimir</groupId>\n    <artifactId>extension3</artifactId>\n    <version>%s</version>\n  </extension>\n' "${MIMIR_VERSION:-0.12.0}"
        fi
        if [[ "${want_dev}" == "true" ]]; then
          printf '  <extension>\n    <groupId>com.gradle</groupId>\n    <artifactId>develocity-maven-extension</artifactId>\n    <version>%s</version>\n  </extension>\n' "${DEVELOCITY_VERSION:-1.23}"
        fi
        echo '</extensions>'
      } > "${own_ext}"
      # Develocity also needs its config file alongside the extension.
      [[ "${want_dev}" == "true" ]] && ln -f "${root}/develocity/develocity.xml" "${project_dir}/.mvn/" 2>/dev/null || true
      local exmsg=""
      [[ "${want_mimir}" == "true" ]] && exmsg="${exmsg} mimir"
      [[ "${want_dev}" == "true" ]] && exmsg="${exmsg} develocity"
      ext=" (extensions:${exmsg} )"
    fi
  fi

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
    local iso_path="${v_iso_root}/${project//\//--}"
    mkdir -p "${iso_path}"
    opts="${opts} -Dmaven.repo.local=${iso_path}"
    ext="${ext} (isolated M2)"
  fi

  # Per-project extra Maven CLI arguments from extra-mvn-args.txt.
  # Catch-all for one-off flags like -Dsurefire.timeout=600 for projects
  # whose forked test JVMs need a leash.
  local extra_args
  extra_args=$(get_extra_mvn_args "${project}")
  if [[ -n "${extra_args}" ]]; then
    opts="${opts} ${extra_args}"
  fi

  # Per-project JDK21 override (independent of variant mechanism). For the
  # handful of projects whose source code or build enforcement requires
  # Java 21 while the rest of the reactor runs on a lower JDK.
  local proj_javahome=""
  for j21p in ${JDK21_PROJECTS:-}; do
    if [[ "${project}" == "${j21p}" ]]; then
      proj_javahome="${JDK21_HOME}"
      ext="${ext} (JDK 21)"
      break
    fi
  done

  mvn_info=""
  if [[ -n "${variant}" ]]; then
    # Variant runs use the variant's Maven, deliberately ignoring any project
    # mvnw wrapper (the whole point is testing a chosen Maven version).
    mvn="$(variant_mvn "${variant}")"
    if [[ -z "${mvn}" ]]; then
      echo "WARNING: variant ${variant}: no Maven resolved (need variants/${variant}/maven or installed $(variant_field "${variant}" 2)); using system mvn" >&2
      mvn="mvn"
    fi
    mvn_info="variant ${variant} (Maven $(variant_field "${variant}" 2))"
    [[ -n "${v_javahome}" ]] && mvn_info="${mvn_info}, JDK $(variant_jdk "${variant}")"
  elif test -r "${project_dir}/mvnw"; then
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
  # to ALL projects; without it, projects listed in FLAKY_PROJECTS get a
  # per-project override (second field in flaky-projects.txt) or
  # FLAKY_RETRY_DEFAULT; all others get 0.
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
    max_retries=$(get_flaky_retry_count "${project}")
  fi

  logs="${v_logroot}/${project}/${run_ts:-$(date +%y%m%d-%H%M)}-${task}-$$-${counter}.log"
  echo -n "${project} (${counter}/${noof_projects}), a Maven project ${mvn_info}, build (logs: '${logs}') "
  set +e
  # Per-project timing. Stage totals alone cannot distinguish "slower" from
  # "more projects", and they hide the handful of repositories that dominate a
  # phase. Recorded together with the 1-minute load average, so a slow run on a
  # busy machine can be told apart from a genuine regression.
  local _t0; _t0=$(date +%s)
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
      [[ -n "${v_javahome}" ]] && export JAVA_HOME="${v_javahome}"
      [[ -n "${proj_javahome}" ]] && export JAVA_HOME="${proj_javahome}"
      # Prefix in the ENVIRONMENT as well, so forked builds resolve from where
      # the outer build installs. On the command line alone it reached the
      # outer build only, and a component could not find what it had just
      # installed.
      [[ -n "${variant}" ]] && export MAVEN_OPTS="${MAVEN_OPTS:-} -Daether.enhancedLocalRepository.localPrefix=installed/${variant}"
      # Variant install prefix in the ENVIRONMENT, so that forked Maven
      # processes (invoker ITs, mvnd) resolve from where the outer build
      # installs. On the command line it reached the outer build only, and
      # a plugin could not find the artefact it had just installed.
      # shellcheck disable=SC2086
      ${mvn} -B -s "${v_settings}" ${opts} ${goals} 2>&1
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
  local _elapsed=$(( $(date +%s) - _t0 ))
  local _load
  _load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
  local _timings="${root}/metrics/project-timings.tsv"
  if [[ ! -f "${_timings}" ]]; then
    mkdir -p "${root}/reports"
    printf 'ended_at\ttask\tproject\tseconds\tstatus\tload1\tvariant\n' > "${_timings}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%F %T')" "${task}" "${project}" "${_elapsed}" \
    "$([[ ${status} -eq 0 ]] && echo ok || echo failed)" "${_load:-}" "${variant:-}" \
    >> "${_timings}"

  if test ${status} -ne 0; then
    echo "failed${retry_tag}${ext} [${_elapsed}s]"
    test "${PREVIEW_LOGLINES:-0}" -gt 0 && tail -"${PREVIEW_LOGLINES}" "${current_logs}"
    if eval "${FAIL_FAST:-false}"; then
      echo "Failing fast and current execution failed with status '${status}'"
      exit ${status}
    fi
  else
    echo "succeeded${retry_tag}${ext} [${_elapsed}s]"
  fi
  set -e
}