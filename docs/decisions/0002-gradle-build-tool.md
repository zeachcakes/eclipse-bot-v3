---
status: accepted
date: 2026-09-23
decision-makers: Kanishk Gupta
---

# Gradle with the Groovy DSL as the build tool for Java

## Context and Problem Statement

[ADR 0001](0001-language-runtimes.md) makes Java one of the bot's base runtimes but does not choose a build tool. The Java code needs one to compile, test and package. Which build tool do we use, and where does its version come from?

## Decision Outcome

Use Gradle through the Gradle Wrapper committed to the repository:

* Gradle 9.7.1, `bin` distribution. `gradle/wrapper/gradle-wrapper.properties` pins the distribution's SHA-256, so the wrapper refuses a tampered download.
* Groovy DSL: `settings.gradle` and `build.gradle`.
* A multi-project build. The root project applies only the `base` plugin, and each part of the bot becomes a subproject listed in `settings.gradle`.
* Gradle is not pinned in `mise.toml`. The wrapper is the only source of the Gradle version, and it runs on the JDK that mise pins. Upgrade with `./gradlew wrapper --gradle-version <version> --gradle-distribution-sha256-sum <sha256>`.

### Consequences

* Good, because contributors and CI need no global Gradle install. `./gradlew` downloads and verifies the pinned version.
* Good, because the root `build` task already exists, so CI can call `./gradlew build` before any subproject lands.
* Bad, because the Groovy DSL gives weaker IDE completion and type checks than the Kotlin DSL.
* Open: this ADR does not decide whether Gradle also drives the Python and Node.js builds. It also does not choose frameworks or a datastore.
