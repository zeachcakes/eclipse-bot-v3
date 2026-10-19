---
status: accepted
date: 2026-09-27
decision-makers: Kanishk Gupta
---

# Convention plugins in an included build, and automatic subproject discovery

## Context and Problem Statement

[ADR 0004](0004-gradle-version-catalog-and-convention-plugins.md) keeps the convention plugins that `gradle init` generated in `buildSrc/`. Any change under `buildSrc/` invalidates the whole build, and the generated `buildlogic.*` plugins were a starting point, not plugins we wrote for this bot. [ADR 0002](0002-gradle-build-tool.md) also lists every subproject in `settings.gradle` by hand. Where do our own convention plugins live, and how does the root build find its subprojects?

## Decision Outcome

* Convention plugins live in a separate Gradle build at `tools/gradle`, whose only project is `convention-plugins`. The root `settings.gradle` adds it with `includeBuild('tools/gradle')` inside `pluginManagement {}`, so subprojects apply its plugins by ID in their `plugins {}` block, with no version.
* Plugins are Groovy precompiled script plugins in `convention-plugins/src/main/groovy/<plugin-id>.gradle`. The project's `build.gradle` applies `groovy-gradle-plugin`; without it, Gradle compiles nothing there.
* Plugins still read the catalog with `versionCatalogs.named('libs')`, which reads the catalog of the project that applies them. The plugin build's own `build.gradle` uses `libs.<alias>` for plugin dependencies, so `tools/gradle/settings.gradle` imports the catalog with `from(files('../../gradle/libs.versions.toml'))`.
* `buildSrc/` and the generated `buildlogic.java-common-conventions`, `buildlogic.java-application-conventions` and `buildlogic.java-library-conventions` plugins are deleted.
* The root `settings.gradle` discovers subprojects instead of listing them. Every directory below the root with a `build.gradle` is a subproject named after its path: `services/api/build.gradle` becomes `:services:api`. The walk:
  * skips hidden directories and `build`, `docs`, `gradle`, `node_modules` and `src`, which never hold a subproject;
  * skips any directory with its own `settings.gradle`, because that is a separate build, such as `tools/gradle`;
  * calls `listFiles()` in the settings script itself. Groovy's `File.traverse` lists directories inside the Groovy runtime, where the configuration cache does not see the reads, so new subprojects were missed.

### Consequences

* Good, because a change to a convention plugin rebuilds only the plugin build, not the whole build.
* Good, because a new subproject needs only a directory with a `build.gradle`, and no `include` line.
* Bad, because the configuration cache tracks every directory the walk lists. A new file in one of them, such as a new top-level file, forces one reconfigure. Skipping `src` keeps source edits from doing that.
* Bad, because the project name is the last path segment. `services/api` and `libs/api` both become projects named `api`, and their published coordinates can clash.
