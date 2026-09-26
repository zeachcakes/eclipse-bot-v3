---
status: accepted
date: 2026-09-26
decision-makers: Kanishk Gupta
---

# Gradle version catalog and convention plugins for Java services

## Context and Problem Statement

[ADR 0002](0002-gradle-build-tool.md) makes the Java build a multi-project Gradle build, where each part of the bot becomes a subproject. The bot will have several services, and each service has its own `build.gradle`. If every build file declares its own dependency versions and its own Java, repository and test setup, the services drift apart. Where do dependency versions live, and how do services share build configuration?

## Decision Outcome

Generate the build layout with `./gradlew init --type java-application --split-project --dsl groovy --test-framework junit-jupiter --java-version 25`, from Gradle 9.7.1. Keep its version catalog, convention plugins and `gradle.properties`, and delete the sample `app`, `list` and `utilities` subprojects.

* `gradle/libs.versions.toml` is the version catalog. Every dependency and plugin version for the Gradle build lives there. Build scripts reference entries as `libs.<alias>` and never write a version inline.
* `buildSrc/` holds convention plugins written as Groovy precompiled script plugins:
  * `buildlogic.java-common-conventions` applies `java`, uses Maven Central, sets the Java 25 toolchain, and adds JUnit Jupiter on the JUnit Platform.
  * `buildlogic.java-application-conventions` adds the `application` plugin. Services apply it.
  * `buildlogic.java-library-conventions` adds the `java-library` plugin. Shared libraries apply it.
* Precompiled script plugins cannot use the generated `libs` accessors. They look entries up with `versionCatalogs.named('libs').findLibrary('<alias>')`, which reads the catalog of the project that applies the plugin. `buildSrc/settings.gradle` also imports the catalog, so `buildSrc/build.gradle` can use `libs.<alias>` for plugin dependencies.
* `settings.gradle` applies the `org.gradle.toolchains.foojay-resolver-convention` plugin. Its version stays inline, because the version catalog is not available in the settings `plugins {}` block. The Temurin 25 JDK from mise satisfies the toolchain, so the resolver normally downloads nothing.
* `gradle.properties` turns on the configuration cache.
* `gradle init` also rewrites `.gitignore`, `.gitattributes` and the wrapper files, and drops the wrapper's `distributionSha256Sum`. Those changes were reverted. Do the same if `init` is ever run again.

### Consequences

* Good, because a version bump is a one-line change in `gradle/libs.versions.toml` that every service picks up.
* Good, because a new service needs only a `build.gradle` that applies one convention plugin, plus an `include` in `settings.gradle`.
* Bad, because any change under `buildSrc/` invalidates the whole build. If that slows builds down, move the convention plugins to a `build-logic` included build.
* Bad, because convention plugins use the string-based catalog API, so a wrong alias fails at configuration time, not at compile time.
* Open: the catalog covers only code that Gradle builds. How Python and Node.js pin their dependencies, and whether Gradle drives those builds, is still open from ADR 0002.
