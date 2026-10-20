---
status: accepted
date: 2026-10-20
decision-makers: Kanishk Gupta
---

# Layered convention plugins in the tools/gradle build

Updated by [ADR 0010](0010-centralized-development-workflow.md): the convention
build now includes Jupiter regression tests for database-settings resolution.
The layered plugin architecture remains unchanged.

## Context and Problem Statement

Every Java module in the bot needs the same compiler checks and test setup. Services also share their Spring Boot setup, and schema modules share their Flyway and jOOQ setup. [ADR 0005](0005-convention-plugins-included-build.md) puts convention plugins in an included build, but does not say how the plugins are built, split and versioned.

Another repository already has working convention plugins in a `tools/gradle` included build. They are tied to that repository, though: an Amazon-only JDK, Maven publishing, Testcontainers, Docker image and scan tasks, a pipeline convention, a shared root database service with default credentials, and jOOQ generation wired into compilation. How do we reuse that architecture without that coupling?

## Considered Options

* Copy the other repository's convention plugins unchanged.
* Adapt its architecture: a local included build with three layered Groovy precompiled script plugins.
* Publish shared convention plugins to a repository and apply them by version.
* Write the plugins as binary plugin classes instead of precompiled scripts.

## Decision Outcome

Chosen option: "Adapt its architecture", because it keeps a layout that already works and drops everything that only makes sense in the other repository.

* Copying unchanged would bring that coupling along. The other repository's utility and pipeline plugins are wired into its remaining plugins, so they cannot simply be deleted after copying.
* Publishing needs an artifact repository and a release process, which this project does not have.
* [ADR 0004](0004-gradle-version-catalog-and-convention-plugins.md) and ADR 0005 already chose Groovy precompiled script plugins, which use the same Groovy DSL as the module build files.

### Build layout

* `tools/gradle` is a separate Gradle build. Its root project is `build-logic`, with one project, `convention-plugins`. The root `settings.gradle` adds it with `pluginManagement { includeBuild('tools/gradle') }`. The root build's subproject discovery skips `tools/gradle`, because it has its own `settings.gradle`.
* Gradle names an included build after its directory, not its root project. From the root build, its tasks are `:gradle:convention-plugins:<task>`. To run it on its own, use `./gradlew -p tools/gradle :convention-plugins:<task>`.
* `tools/gradle/settings.gradle` imports the root version catalog with `from(files('../../gradle/libs.versions.toml'))`, because an included build does not inherit it. The root build gets the catalog automatically and does not import it again.
* Each plugin is a precompiled script at `convention-plugins/src/main/groovy/<plugin-id>.gradle`, compiled by `groovy-gradle-plugin`. Modules apply plugins by ID, without a version.
* Scripts only wire things together. Any other logic goes in Groovy classes in the `buildlogic` package next to them: the `schemaDatabase` extension, the `verifyGeneratedJooq` task type, database-settings resolution, the generated-source fingerprint, and the Flyway and jOOQ adapters. Gradle creates extension and task types itself, so those must be classes. The other helpers are plain code that can be unit-tested.
* Third-party plugins used by the scripts (Error Prone, Spring Boot, Flyway, jOOQ) are `implementation` dependencies of `convention-plugins`, with versions from the catalog. That is the only place their versions appear. A catalog entry alone does not put a plugin on the scripts' classpath.
* A module that a tool loads as a plugin at run time goes on the same classpath as the tool. Flyway only finds `flyway-database-postgresql` through the class loader that loaded `flyway-core`, so that module is also an `implementation` dependency of `convention-plugins`.
* Scripts read the catalog with `extensions.getByType(VersionCatalogsExtension).named('libs')`, because the generated `libs` accessors do not exist inside precompiled plugins.
* `convention-plugins` and the modules compile with the same Java toolchain, Java 25 (LTS), which is the JDK that mise pins ([ADR 0001](0001-language-runtimes.md)). Gradle itself must run on that JDK, because the plugin classes are compiled for it.
* The conventions work with the configuration cache, except the database tasks described in [ADR 0007](0007-per-service-database-schemas.md).
* As updated by ADR 0010, `convention-plugins` has Jupiter unit tests for database-settings resolution. The modules that apply the conventions still exercise their wiring in `./gradlew check`.

### Plugins

There are exactly three public plugins, and the other two build on the Java one:

```text
java-core-conventions
  + java-library
  + net.ltgt.errorprone

spring-boot-server-conventions
  + java-core-conventions
  + org.springframework.boot

service-schema-conventions
  + java-core-conventions
  + nu.studer.jooq
  + org.flywaydb.flyway
```

* `java-core-conventions` sets the Java toolchain, UTF-8 sources and `-Xlint:all -Werror -parameters`. It applies Error Prone with NullAway as an error for the `baseJavaPackage` namespace in `gradle.properties`, and rejects an invalid `baseJavaPackage`. It adds JSpecify and its own JUnit BOM, Jupiter, AssertJ and JUnit Platform launcher, so a Java-only library needs neither Spring Boot nor its BOM. It excludes JUnit 4 (`junit:junit`) everywhere. It uses `java-library`, because schema modules expose jOOQ types through `api`.
* Tests are plain Jupiter tests. There is no JUnit 4, Vintage or jqwik by default, no custom test-name filter, and no globally enabled dynamic agent loading.
* `spring-boot-server-conventions` adds the Spring Boot plugin and BOM, WebFlux, R2DBC, JDBC-backed jOOQ, Hikari, the PostgreSQL JDBC and R2DBC drivers, and Spring Boot and Reactor test support. Each server sets its own main class and declares its own dependency on its schema module. Boot's standard tasks, such as `bootBuildImage`, exist but are not part of any workflow. Boot's default logging is used.
* `service-schema-conventions` adds Flyway and jOOQ for one service schema, configured through the `schemaDatabase` extension. ADR 0007 describes it.
* Conventions are applied only in real modules, never in the root project or in directory-only projects such as `services`. The root `build.gradle` only sets the group and version from `projectGroup` and `projectVersion` in `gradle.properties`.
* A convention never sets a group or main class, searches for sibling projects, changes another project, reads database settings during configuration, adds database work to `test`, or adds publishing or Docker tasks.

### Not carried over from the other repository

The Amazon-only toolchain, the utility and pipeline conventions, Maven publishing, Testcontainers, Docker image tasks and their FreeMarker Dockerfile template, Hadolint and Trivy tasks, the `application` plugin and its custom `start` task, the shared root database service and its default connection settings, and jOOQ generation during compilation.

Guava, jOOL, jqwik, Log4j2, Netty version overrides, pgvector, Spring Security and Actuator are not added by default either. Each needs its own decision.

### Version alignment

* The jOOQ plugin's own `org.jooq` dependencies are excluded and `jooq-codegen` is pinned from the catalog, so the plugin's DSL, the generator and the runtime all use one jOOQ version. The jOOQ plugin defaults to a different jOOQ version, so `service-schema-conventions` sets `jooq.version` explicitly.
* Flyway is build tooling only. Its version comes from the catalog, not from the version Spring Boot manages. Spring Boot's platform stays off the plugin build's classpath, so it cannot downgrade Flyway.
* The PostgreSQL JDBC driver is pinned in the catalog. The R2DBC driver uses the version Spring Boot manages.
* Error Prone hooks into `javac` internals, so check it against the toolchain whenever the JDK changes. Error Prone and NullAway versions move together: NullAway 0.12 does not load with Error Prone 2.50.0.
* Related pins change together. Check what actually resolves, not only what the catalog declares:

```sh
./gradlew -p tools/gradle :convention-plugins:dependencyInsight --configuration runtimeClasspath --dependency org.jooq
./gradlew -p tools/gradle :convention-plugins:dependencyInsight --configuration runtimeClasspath --dependency flyway-core
./gradlew :services:catalog:schema:dependencyInsight --configuration jooqGenerator --dependency org.jooq
./gradlew :services:catalog:server:dependencyInsight --configuration runtimeClasspath --dependency org.jooq
```

### Consequences

* Good, because a new module needs one `plugins {}` block with one plugin ID, and no copied build logic.
* Good, because each plugin and library version is declared once.
* Good, because a Java-only library builds and tests without Spring Boot or a database.
* Good, because logic beyond wiring lives in small typed classes that can be unit-tested.
* Bad, because helper unit tests do not cover every applied convention; modules that apply the plugins still need to exercise their wiring.
* Bad, because Gradle must run on the toolchain's JDK. A Gradle daemon on an older JDK, including one an IDE starts, cannot load the plugin classes.
* Bad, because every module that applies any convention gets the whole plugin build on its build-script classpath, including the Spring Boot, Flyway and jOOQ plugins.
* Bad, because the VS Code Gradle extension checks precompiled scripts against the wrong classpath and reports false "unable to resolve class" errors. `.vscode/settings.json` treats those scripts as plain Groovy to hide the errors, so they get no Gradle completion either.
* Bad, because another repository can reuse these plugins only by copying and adapting the build, as this one did. Shared distribution is a separate decision.

## More Information

* Plugin build: [settings](../../tools/gradle/settings.gradle), [build script](../../tools/gradle/convention-plugins/build.gradle), and [plugin scripts and helpers](../../tools/gradle/convention-plugins/src/main/groovy).
* Gradle documentation: [composite builds](https://docs.gradle.org/current/userguide/composite_builds.html), [version catalogs](https://docs.gradle.org/current/userguide/version_catalogs.html) and [precompiled script plugins](https://docs.gradle.org/current/userguide/implementing_gradle_plugins_precompiled.html).
* [jOOQ Gradle plugin documentation](https://github.com/etiennestuder/gradle-jooq-plugin/blob/v10.1.1/README.md).
