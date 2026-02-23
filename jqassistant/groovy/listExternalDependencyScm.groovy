#!/usr/bin/env groovy

logger.info("Creating report for concept '{}' in '{}' (#{} rows)", concept.id, reportDirectory, result.rows.size())

// --- deps.dev cache ---
// Simple properties file cache: key = "group:artifact:version", value = "sourceRepo|homepage"
File cacheDir = new File(reportDirectory, "deps-dev-cache")
cacheDir.mkdirs()
File cacheFile = new File(cacheDir, "deps-dev.properties")
Properties cache = new Properties()
if (cacheFile.exists()) {
    cacheFile.withInputStream { cache.load(it) }
    logger.info("Loaded {} cached deps.dev entries", cache.size())
}

// --- OpenSSF Scorecard cache ---
// Cache: key = "owner/repo", value = "score|date|Maintained|Code-Review|Vulnerabilities|Security-Policy|Dependency-Update-Tool|Branch-Protection|License"
File scorecardCacheDir = new File(reportDirectory, "scorecard-cache")
scorecardCacheDir.mkdirs()
File scorecardCacheFile = new File(scorecardCacheDir, "scorecard.properties")
Properties scorecardCache = new Properties()
if (scorecardCacheFile.exists()) {
    scorecardCacheFile.withInputStream { scorecardCache.load(it) }
    logger.info("Loaded {} cached Scorecard entries", scorecardCache.size())
}

/**
 * Query deps.dev API for source repository and homepage.
 * Returns [sourceRepo: url, homepage: url] or nulls.
 * Uses file-based cache to avoid repeated API calls.
 */
def lookupDepsDev(String group, String artifact, String version, Properties cache, File cacheFile) {
    def cacheKey = "${group}:${artifact}:${version}"
    if (cache.containsKey(cacheKey)) {
        def cached = cache.getProperty(cacheKey)
        def parts = cached.split(/\|/, -1)
        return [sourceRepo: parts[0] ?: null, homepage: parts[1] ?: null]
    }

    def sourceRepo = null
    def homepage = null
    try {
        def encoded = URLEncoder.encode("${group}:${artifact}", "UTF-8")
        def apiUrl = "https://api.deps.dev/v3alpha/systems/maven/packages/${encoded}/versions/${URLEncoder.encode(version, "UTF-8")}"
        def conn = new URL(apiUrl).openConnection()
        conn.setRequestProperty("Accept", "application/json")
        conn.connectTimeout = 5000
        conn.readTimeout = 10000
        if (conn.responseCode == 200) {
            def body = conn.inputStream.text
            // Parse SOURCE_REPO and HOMEPAGE from JSON using regex
            // Links look like: {"label":"SOURCE_REPO","url":"https://..."}
            def linkPattern = ~/"label"\s*:\s*"([^"]+)"\s*,\s*"url"\s*:\s*"([^"]+)"/
            linkPattern.matcher(body).each { match ->
                if (match[1] == "SOURCE_REPO") sourceRepo = match[2]
                if (match[1] == "HOMEPAGE") homepage = match[2]
            }
        }
    } catch (Exception ex) {
        // Silently skip on error, will be retried next run (not cached)
        return [sourceRepo: null, homepage: null]
    }

    // Cache the result (even if null, to avoid re-querying)
    cache.setProperty(cacheKey, "${sourceRepo ?: ''}|${homepage ?: ''}")
    cacheFile.withOutputStream { cache.store(it, "deps.dev lookup cache") }
    return [sourceRepo: sourceRepo, homepage: homepage]
}

// Scorecard checks we want to extract (order matters for cache value format)
def SCORECARD_CHECKS = ['Maintained', 'Code-Review', 'Vulnerabilities', 'Security-Policy',
                         'Dependency-Update-Tool', 'Branch-Protection', 'License']

/**
 * Query the OpenSSF Scorecard API for a GitHub repository.
 * Returns a map with 'score' (overall), 'date', and per-check scores, or nulls on failure.
 * Uses file-based cache to avoid repeated API calls.
 */
def lookupScorecard(String owner, String repo, List checkNames, Properties scCache, File scCacheFile) {
    def cacheKey = "${owner}/${repo}"
    if (scCache.containsKey(cacheKey)) {
        def cached = scCache.getProperty(cacheKey)
        if (cached == 'ERROR') {
            return null
        }
        def parts = cached.split(/\|/, -1)
        if (parts.length >= 2 + checkNames.size()) {
            def result = [score: parts[0] ? parts[0].toFloat() : null, date: parts[1] ?: null, checks: [:]]
            checkNames.eachWithIndex { name, i ->
                result.checks[name] = parts[2 + i] ? parts[2 + i].toFloat() : null
            }
            return result
        }
    }

    try {
        def apiUrl = "https://api.securityscorecards.dev/projects/github.com/${owner}/${repo}"
        def conn = new URL(apiUrl).openConnection()
        conn.setRequestProperty("Accept", "application/json")
        conn.connectTimeout = 10000
        conn.readTimeout = 15000
        if (conn.responseCode == 200) {
            def body = conn.inputStream.text

            // Extract overall score
            def scoreMatcher = body =~ /"score"\s*:\s*([0-9.]+)/
            def score = scoreMatcher.find() ? scoreMatcher[0][1].toFloat() : null

            // Extract date
            def dateMatcher = body =~ /"date"\s*:\s*"([^"]+)"/
            def date = dateMatcher.find() ? dateMatcher[0][1] : null

            // Extract per-check scores
            // JSON pattern: {"name":"CheckName",...,"score":N,...}
            def checks = [:]
            checkNames.each { checkName ->
                def checkPattern = ~/"name"\s*:\s*"${checkName}"[^}]*?"score"\s*:\s*(-?[0-9]+)/
                def m = checkPattern.matcher(body)
                checks[checkName] = m.find() ? m[0][1].toFloat() : null
            }

            // Build cache value: score|date|check1|check2|...
            def cacheValue = "${score ?: ''}|${date ?: ''}"
            checkNames.each { cacheValue += "|${checks[it] != null ? checks[it] : ''}" }
            scCache.setProperty(cacheKey, cacheValue)
            scCacheFile.withOutputStream { scCache.store(it, "OpenSSF Scorecard cache") }

            return [score: score, date: date, checks: checks]
        } else {
            // Cache errors (404 = not scored, etc.) to avoid re-querying
            scCache.setProperty(cacheKey, "ERROR")
            scCacheFile.withOutputStream { scCache.store(it, "OpenSSF Scorecard cache") }
            return null
        }
    } catch (Exception ex) {
        // Network error: don't cache, allow retry next run
        return null
    }
}

/**
 * Normalize a raw SCM URL to an https URL suitable for linking.
 * Handles scm: prefixes, git@host: SSH syntax, http->https upgrade,
 * and strips trailing .git.
 */
def normalizeUrl(String raw) {
    if (!raw || raw == 'n/a') return null
    def url = raw
    // Strip SCM prefixes
    url = url.replaceFirst(/^scm:(git|svn|hg):/, '')
    // Convert git@ SSH syntax to https (GitHub, GitLab, Bitbucket)
    def sshMatcher = url =~ /^git@([^:]+):(.+)/
    if (sshMatcher.matches()) {
        url = "https://${sshMatcher[0][1]}/${sshMatcher[0][2]}"
    }
    // Upgrade http to https for well-known hosts
    if (url.startsWith('http://github.com')) {
        url = url.replace('http://github.com', 'https://github.com')
    }
    if (url.startsWith('http://gitlab.com')) {
        url = url.replace('http://gitlab.com', 'https://gitlab.com')
    }
    if (url.startsWith('http://svn.apache.org')) {
        url = url.replace('http://svn.apache.org', 'https://svn.apache.org')
    }
    // Apache Gitbox/git-wip-us → GitHub mirror
    // Handles: gitbox.apache.org/repos/asf?p=NAME and gitbox.apache.org/repos/asf/NAME
    def gitboxMatcher = url =~ /https?:\/\/(?:gitbox|git-wip-us)\.apache\.org\/repos\/asf[\/?](?:p=)?([a-zA-Z0-9_.-]+)/
    if (gitboxMatcher.find()) {
        url = "https://github.com/apache/${gitboxMatcher[0][1]}"
    }
    // GitHub submodule paths → repo root (e.g. jline/jline3/jline-reader → jline/jline3)
    // Only strip if the path segment after owner/repo is NOT a known GitHub path (tree, blob, issues, etc.)
    def subpathMatcher = url =~ /^(https:\/\/github\.com\/[^\/]+\/[^\/]+)\/(?!tree\/|blob\/|issues|pulls|releases|actions|wiki)(.+)/
    if (subpathMatcher.matches()) {
        url = subpathMatcher[0][1]
    }
    // Strip trailing .git
    url = url.replaceFirst(/\.git$/, '')
    // Strip trailing /
    url = url.replaceFirst(/\/$/, '')
    // Strip GitHub /tree/... suffixes (tag/branch paths that may be stale)
    url = url.replaceFirst(/\/tree\/.*$/, '')
    return url
}

/**
 * Classify the hosting platform from a URL.
 */
def classifyPlatform(String url) {
    if (!url) return 'unknown'
    if (url.contains('github.com')) return 'GitHub'
    if (url.contains('gitlab')) return 'GitLab'
    if (url.contains('bitbucket.org')) return 'Bitbucket'
    if (url.contains('gitbox.apache.org') || url.contains('git-wip-us.apache.org')) return 'Apache Gitbox'
    if (url.contains('svn.apache.org') || url.contains('svn.sourceforge.net')) return 'SVN'
    if (url.contains('code.google.com')) return 'Google Code'
    return 'other'
}

// Collect all rows with normalized URLs
def entries = result.rows.collect { row ->
    def depGroup = row.columns['depGroup'].value
    def depArtifact = row.columns['depArtifact'].value
    def versions = row.columns['versions'].value
    def usedByProjects = row.columns['usedByProjects'].value
    def scmUrl = row.columns['scmUrl']?.value ?: ''
    def platform = row.columns['platform']?.value ?: ''
    def urlSource = row.columns['urlSource']?.value ?: ''
    def normalizedUrl = normalizeUrl(scmUrl)
    def homepage = null

    def versionList = versions instanceof Iterable ? versions.toList() : [versions.toString()]

    // If urlSource is 'project-url', treat it as homepage, not SCM
    if (urlSource == 'project-url') {
        homepage = normalizedUrl
        normalizedUrl = null
        platform = 'unknown'
    }

    [depGroup: depGroup, depArtifact: depArtifact, versions: versionList,
     usedByProjects: usedByProjects, scmUrl: scmUrl, normalizedUrl: normalizedUrl,
     platform: platform, urlSource: urlSource, homepage: homepage]
}

// --- Manual SCM overrides ---
// Load manually curated SCM URLs for dependencies where automated lookup fails.
// File lives in jqassistant/groovy/ relative to project base directory.
Properties overrides = new Properties()
// reportDirectory is target/jqassistant/report/groovy-reports, so go up 4 levels to project root
File reportDir = reportDirectory instanceof File ? reportDirectory : new File(reportDirectory.toString())
File projectRoot = reportDir.parentFile.parentFile.parentFile.parentFile
File overrideFile = new File(projectRoot, "jqassistant/groovy/scm-overrides.properties")
if (overrideFile.exists()) {
    overrideFile.withInputStream { overrides.load(it) }
    logger.info("Loaded {} SCM overrides from {}", overrides.size(), overrideFile.name)
} else {
    logger.warn("SCM overrides file not found: {}", overrideFile.absolutePath)
}

// Enrich missing entries via deps.dev, then apply manual overrides
def enrichedCount = 0
def overrideCount = 0
entries.each { e ->
    if (!e.normalizedUrl) {
        // Try deps.dev first
        def version = e.versions.last()
        def depsResult = lookupDepsDev(e.depGroup, e.depArtifact, version, cache, cacheFile)
        if (depsResult.sourceRepo) {
            e.normalizedUrl = normalizeUrl(depsResult.sourceRepo)
            e.platform = classifyPlatform(e.normalizedUrl)
            e.urlSource = 'deps.dev'
            enrichedCount++
        }
        if (depsResult.homepage && !e.homepage) {
            e.homepage = normalizeUrl(depsResult.homepage)
        }
    }
    // Apply manual override (highest priority, overwrites POM/deps.dev URLs)
    def overrideKey = "${e.depGroup}:${e.depArtifact}"
    def overrideUrl = overrides.getProperty(overrideKey)?.trim()
    if (overrideUrl && overrideUrl != 'NONE') {
        e.normalizedUrl = normalizeUrl(overrideUrl)
        e.platform = classifyPlatform(e.normalizedUrl)
        e.urlSource = 'override'
        overrideCount++
    } else if (overrideUrl == 'NONE') {
        e.normalizedUrl = null
        e.urlSource = 'override-none'
    }
}
logger.info("Enriched {} entries via deps.dev (cache size: {}), {} via manual overrides", enrichedCount, cache.size(), overrideCount)

// --- AsciiDoc report ---
File adocOutput = new File(reportDirectory, "external-dependency-scm.adoc")
adocOutput.delete()
adocOutput.append("""= External Dependency SCM Overview

External dependencies of the Apache Maven ecosystem with their source repository URLs,
generated on ${new Date()}.

[cols="3,3,1,1,2,1,4", options="header"]
|===
| Group | Artifact | Versions | Used By | Platform | Source | SCM URL

""")

entries.each { e ->
    def scmLink
    if (e.normalizedUrl) {
        if (e.normalizedUrl.startsWith('http://') || e.normalizedUrl.startsWith('https://')) {
            scmLink = "${e.normalizedUrl}[${e.normalizedUrl}]"
        } else {
            scmLink = "${e.normalizedUrl}"
        }
    } else {
        scmLink = '_not available_'
    }

    def centralUrl = "https://central.sonatype.com/artifact/${e.depGroup}/${e.depArtifact}"
    def artifactLink = "${centralUrl}[${e.depArtifact}]"
    def versionStr = e.versions.join(', ')

    def sourceLabel = e.urlSource ?: '-'
    adocOutput.append("| `${e.depGroup}` | ${artifactLink} | ${versionStr} | ${e.usedByProjects} | ${e.platform} | ${sourceLabel} | ${scmLink}\n")
}
adocOutput.append("\n|===\n")

// --- Unresolved dependencies: query Maven projects that use them ---
def unresolved = entries.findAll { !it.normalizedUrl }
if (unresolved) {
    adocOutput.append("""

== Unresolved Dependencies

The following ${unresolved.size()} dependencies have no known source repository.
For each, the Maven projects that declare them are listed.

""")

    unresolved.each { e ->
        def centralUrl = "https://central.sonatype.com/artifact/${e.depGroup}/${e.depArtifact}"
        adocOutput.append("=== ${centralUrl}[`${e.depGroup}:${e.depArtifact}`]\n\n")

        def cypherQuery = """
            MATCH (p:Maven:Project)-[:HAS_EFFECTIVE_MODEL]->(em)
            MATCH (em)-[:DECLARES_DEPENDENCY]->(d)-[:TO_ARTIFACT]->(a)
            WHERE a.group = \$depGroup AND a.name = \$depArtifact
            RETURN DISTINCT p.groupId AS projectGroup, p.artifactId AS projectArtifact,
                   p.version AS projectVersion, a.version AS depVersion
            ORDER BY projectGroup, projectArtifact
        """
        def params = [depGroup: e.depGroup, depArtifact: e.depArtifact]

        try {
            def queryResult = store.executeQuery(cypherQuery, params)
            adocOutput.append("[cols=\"3,3,2,2\", options=\"header\"]\n|===\n")
            adocOutput.append("| Project Group | Project Artifact | Project Version | Dependency Version\n\n")
            queryResult.each { row ->
                def pGroup = row.get("projectGroup", String.class)
                def pArtifact = row.get("projectArtifact", String.class)
                def pVersion = row.get("projectVersion", String.class)
                def dVersion = row.get("depVersion", String.class)
                adocOutput.append("| `${pGroup}` | `${pArtifact}` | ${pVersion} | ${dVersion}\n")
            }
            adocOutput.append("|===\n\n")
            queryResult.close()
        } catch (Exception ex) {
            logger.warn("Failed to query projects for {}:{}: {}", e.depGroup, e.depArtifact, ex.message)
            adocOutput.append("_Could not retrieve project list._\n\n")
        }
    }
}

// --- OpenSSF Scorecard enrichment ---
// Collect unique GitHub repos and look up their scorecards
def githubRepos = [:] // key: "owner/repo", value: list of entries
entries.each { e ->
    if (e.normalizedUrl && e.normalizedUrl.contains('github.com')) {
        def ghMatcher = e.normalizedUrl =~ /https:\/\/github\.com\/([^\/]+)\/([^\/]+)/
        if (ghMatcher.find()) {
            def repoKey = "${ghMatcher[0][1]}/${ghMatcher[0][2]}"
            if (!githubRepos.containsKey(repoKey)) {
                githubRepos[repoKey] = []
            }
            githubRepos[repoKey] << e
        }
    }
}
logger.info("Found {} unique GitHub repositories for Scorecard lookup", githubRepos.size())

def scorecardResults = [:] // key: "owner/repo", value: scorecard result map
def scorecardCount = 0
githubRepos.keySet().sort().each { repoKey ->
    def parts = repoKey.split('/')
    def sc = lookupScorecard(parts[0], parts[1], SCORECARD_CHECKS, scorecardCache, scorecardCacheFile)
    if (sc) {
        scorecardResults[repoKey] = sc
        scorecardCount++
    }
}
logger.info("Retrieved {} Scorecard results (cache size: {})", scorecardCount, scorecardCache.size())

// --- Scorecard AsciiDoc section ---
adocOutput.append("""

== OpenSSF Scorecard Results

Security scorecards for ${githubRepos.size()} unique GitHub repositories,
retrieved from the https://securityscorecards.dev[OpenSSF Scorecard] API.

[cols="4,1,1,1,1,1,1,1,1", options="header"]
|===
| Repository | Score | Maintained | Code Review | Vulnerabilities | Security Policy | Dep Updates | Branch Prot | License

""")

githubRepos.keySet().sort().each { repoKey ->
    def sc = scorecardResults[repoKey]
    def repoUrl = "https://github.com/${repoKey}"
    def repoLink = "${repoUrl}[${repoKey}]"
    if (sc) {
        def fmt = { val -> val != null ? (val == Math.floor(val) ? "${val.intValue()}" : String.format(Locale.US, "%.1f", val)) : '-' }
        adocOutput.append("| ${repoLink} | *${fmt(sc.score)}* | ${fmt(sc.checks['Maintained'])} | ${fmt(sc.checks['Code-Review'])} | ${fmt(sc.checks['Vulnerabilities'])} | ${fmt(sc.checks['Security-Policy'])} | ${fmt(sc.checks['Dependency-Update-Tool'])} | ${fmt(sc.checks['Branch-Protection'])} | ${fmt(sc.checks['License'])}\n")
    } else {
        adocOutput.append("| ${repoLink} | _n/a_ | | | | | | |\n")
    }
}
adocOutput.append("\n|===\n")

// Summary statistics
if (scorecardResults) {
    def scores = scorecardResults.values().collect { it.score }.findAll { it != null }
    def avgScore = scores ? (scores.sum() / scores.size()) : 0
    def lowScore = scores.findAll { it < 4.0 }
    def highScore = scores.findAll { it >= 7.0 }
    adocOutput.append("""
=== Summary

* *${scores.size()}* repositories scored (${githubRepos.size() - scores.size()} not available)
* Average score: *${String.format(Locale.US, "%.1f", avgScore)}* / 10
* High scores (>= 7.0): *${highScore.size()}*
* Low scores (< 4.0): *${lowScore.size()}*
""")
}

// --- YAML report ---
File yamlOutput = new File(reportDirectory, "external-dependency-scm.yaml")
yamlOutput.delete()
yamlOutput.append("# External Dependency SCM Overview\n")
yamlOutput.append("# Generated: ${new Date()}\n\n")
yamlOutput.append("dependencies:\n")

entries.each { e ->
    yamlOutput.append("  - group: \"${e.depGroup}\"\n")
    yamlOutput.append("    artifact: \"${e.depArtifact}\"\n")
    yamlOutput.append("    versions:\n")
    e.versions.each { v ->
        yamlOutput.append("      - \"${v}\"\n")
    }
    yamlOutput.append("    used-by-projects: ${e.usedByProjects}\n")
    yamlOutput.append("    platform: \"${e.platform}\"\n")
    yamlOutput.append("    url-source: \"${e.urlSource}\"\n")
    if (e.normalizedUrl) {
        yamlOutput.append("    scm-url: \"${e.normalizedUrl}\"\n")
    } else {
        yamlOutput.append("    scm-url: null\n")
    }
    if (e.homepage) {
        yamlOutput.append("    homepage: \"${e.homepage}\"\n")
    }
    if (e.scmUrl && e.scmUrl != 'n/a' && e.scmUrl != e.normalizedUrl) {
        yamlOutput.append("    scm-url-raw: \"${e.scmUrl}\"\n")
    }
    // Add scorecard data if available for this entry's GitHub repo
    if (e.normalizedUrl && e.normalizedUrl.contains('github.com')) {
        def ghM = e.normalizedUrl =~ /https:\/\/github\.com\/([^\/]+)\/([^\/]+)/
        if (ghM.find()) {
            def rk = "${ghM[0][1]}/${ghM[0][2]}"
            def sc = scorecardResults[rk]
            if (sc) {
                yamlOutput.append("    scorecard:\n")
                yamlOutput.append("      score: ${sc.score}\n")
                yamlOutput.append("      date: \"${sc.date}\"\n")
                yamlOutput.append("      checks:\n")
                sc.checks.each { name, val ->
                    yamlOutput.append("        ${name}: ${val != null ? val : 'null'}\n")
                }
            }
        }
    }
}
