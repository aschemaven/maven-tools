# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Maven Support & Care Tools - an automation toolkit for managing, building, and analyzing the Apache Maven multi-repository ecosystem. Uses the `repo` tool to manage 100+ Apache Maven repositories (manifest hosted at [maven-sources](https://github.com/apache/maven-sources)). Repositories are checked out into the `./maven` directory (a symlink to external storage) with `.repo` at `maven/.repo`.

## Prerequisites

- JDK 21
- Maven 3.9.9+
- `repo` tool (multi-repository management)

## Common Commands

### Repository Setup

```bash
# Initialize and sync repositories from maven-sources manifest
./bin/repo-start

# Execute command across all repos (from maven/ directory)
cd maven && repo forall -c "${PWD}/../bin/gh-subscribe"

# Execute on subset (by group)
cd maven && repo forall -r 'core' -c "${PWD}/../bin/some-script"
```

### Building Projects

```bash
# Build all projects
./bin/run-maven clean install

# Build with fail-fast and log preview on failures
FAIL_FAST=true PREVIEW_LOGLINES=50 ./bin/run-maven clean install

# Build specific projects only
PROJECTS="core/maven core/maven-resolver" ./bin/run-maven clean install

# Enable Develocity build scans
USE_DEVELOCITY=true ./bin/run-maven clean install
```

### jQAssistant Analysis

```bash
# Reset store and scan all projects
./bin/run-jqa reset scan

# Run analysis (after scanning)
./bin/run-jqa analyze

# Use remote Neo4j (bolt protocol)
./bin/run-jqa -r bolt://localhost:7687 scan

# Other commands
./bin/run-jqa list-rules
./bin/run-jqa list-plugins
./bin/run-jqa effective-configuration
```

## Architecture

### Key Components

- **`bin/run-maven`**: Batch Maven executor for multiple projects. Uses `common-functions.sh` for shared logic. Generates per-project logs in `logs/`.

- **`bin/run-jqa`**: jQAssistant orchestration. Supports local file-based Neo4j store (default) or remote Bolt connection (`-r` flag).

- **`bin/common-functions.sh`**: Shared shell library. Provides `exec_mvn()` function, handles Maven wrapper detection, log generation.

- **`jqassistant/rules/`**: Custom Cypher-based constraints for code quality analysis.

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MAVEN_PROJECTS_DIR` | Directory containing Maven project checkouts | `maven` |
| `PROJECTS` | Space-separated list of project paths | Contents of `${MAVEN_PROJECTS_DIR}/.repo/project.list` |
| `USE_DEVELOCITY` | Enable Develocity build scans | `false` |
| `MAVEN_LRM_SPLIT` | Enable Maven Resolver Enhanced LRM split layout (`installed/cached` x `releases/snapshots`) under `${maven.repo.local}` | `true` |
| `FAIL_FAST` | Exit on first build failure | `false` |
| `PREVIEW_LOGLINES` | Lines of log to show on failure | `0` |
| `SETTINGS` | Maven settings file path | `${PWD}/settings.xml` |
| `JQA_VERSION` | jQAssistant plugin version | `2.9.0`                                                |

### Build Logs

All Maven execution output goes to `logs/<project>/<task>-<pid>-<counter>.log`. Console output is minimal (success/failure per project).

## jQAssistant Integration

Uses Neo4j graph database to analyze code structure across all Maven projects:

- **Central store mode** (default): `jqassistant/store/` or `bolt://localhost:7687` (remote with `-r`)
- **Rules**: `jqassistant/rules/apache-maven-rules.xml`
- **Config**: `.jqassistant.yml` (includes Git plugin for repository analysis)

## CI/CD

GitHub Actions workflow (`.github/workflows/maven-repo-reactor-build.yml`):
- Scheduled nightly builds on main branch
- Manual trigger with branch selection
- Uploads build logs and jQAssistant store as artifacts

## Before triaging a red matrix cell: read the queue

`~/wrk/maven/maven-bugfixing/` holds the analysis backlog, and much of it is
about components this harness builds. Several entries carry a `Component::`
field naming the project path, so a red cell can be matched to an existing
analysis directly:

```bash
grep -rl "Component:: .core/3.x/its-3" ~/wrk/maven/maven-bugfixing/{queue,plans,in-progress,waiting}
grep -ril "<keyword>"                  ~/wrk/maven/maven-bugfixing/queue
```

This is not optional diligence. On 2026-10-09 a day went into re-deriving a
root cause that `queue/workspace-split-lrm-localprefix.adoc` had analysed on
2026-06-09, down to the refuted intermediate hypothesis — the split local
repository layout leaking into forked integration tests. The queue even
recorded which obvious countermeasure does *not* work. Four parallel agents
reproduced it from scratch instead.

Two entries that explain recurring red cells, as examples of what is in there:

| Entry | Explains |
|---|---|
| `queue/workspace-split-lrm-localprefix.adoc` | fork/outer disagreement on local-repo layout |
| `queue/m4-shared-verifier-mavencling.adoc` | `core/3.x/its-3` against every Maven 4 column |

Entries whose `Repository::` names a repo with several checkouts here (`apache/maven`
has three: `core/3.x/maven-3`, `core/maven`, `core/maven-4.0.x`) carry no
`Component::` field yet — those need a judgement call, so search by keyword.
