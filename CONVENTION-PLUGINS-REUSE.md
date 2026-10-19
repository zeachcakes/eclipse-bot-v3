# Reusing the Gradle convention plugins in a new monorepo

## 1. Purpose and how to use this document

This is a standalone implementation specification for a new Java/Spring Boot
multi-module monorepo. It adapts the convention-plugin architecture in db-oreo;
it is deliberately **not** an instruction to copy every existing convention.

The intended implementer is Codex working in the new repository with access to
this document, but **without** access to db-oreo. The source links are an audit
trail, not prerequisites for implementation.

The document provides:

- The decisions confirmed with the project owner.
- An explanation of the existing architecture and what is reusable.
- A target directory structure, dependency baseline, and build-file templates.
- Precise contracts for database configuration, migration, code generation, and
  generated-source verification.
- Runtime guidance for combining WebFlux, R2DBC, and blocking JDBC/jOOQ.
- An implementation sequence, test cases, commands, and completion criteria.
- A ready-to-use Codex handoff prompt in section 18.

### Reading order

1. Read sections 2–6 before creating files.
2. Implement sections 7–12 using the sequence in section 13.
3. Execute the checks in sections 14–15.
4. Use sections 16–17 when adapting the example or diagnosing failures.

## 2. Confirmed scope

These choices were explicitly confirmed with the project owner.

| Decision | Required outcome |
| --- | --- |
| Project | A new, multi-module monorepo; no target repository/path exists yet |
| Reuse model | A local included build in each repository |
| Build language | Retain the current Groovy Gradle approach |
| Java | Java 21, with no Amazon-specific vendor restriction |
| Compiler checks | Retain strict compilation, Error Prone, and NullAway |
| Unit testing | Required; no live database or container in unit tests |
| Services | Spring Boot with WebFlux and R2DBC |
| SQL access | Retain jOOQ; isolate its blocking JDBC operations from reactive event-loop threads |
| Database | An externally provided PostgreSQL database |
| Isolation | One PostgreSQL schema per service in a shared development database |
| Migrations | Flyway, invoked explicitly through Gradle |
| Code generation | Explicit jOOQ generation; output is untracked under the schema module's build directory |
| Startup migrations | Disabled; application startup must not migrate the database |
| Compatibility policy | Preserve the architecture, remove project-specific coupling, correct portability/compatibility problems |
| Codex context | This document and the target repository only |
| Other environment constraints | None currently known |

### Explicit exclusions

Do **not** implement these as part of this foundation:

- Testcontainers or database-container lifecycle services.
- Dockerfiles, Docker Compose, Docker image generation, or custom image tasks.
- Hadolint or Trivy integrations.
- Batch/data-pipeline conventions.
- Maven artifact publishing, publishing repositories, or publication metadata.
- CI workflows or CI/coverage enforcement gates.

Dependency resolution from Maven Central is still required. That is not Maven
artifact publishing. Gradle's local included-build mechanism also does not
require publishing the convention plugins.

Unit tests and local verification are required even though CI and coverage
gates are excluded. Aim for at least 80% coverage of new implementation logic
where coverage is measured, but do not add a coverage gate or claim measured
coverage without a report.

Do not silently add other source-project choices such as Guava, jOOL, Jayflake,
jqwik, Log4j2, custom Netty overrides, pgvector, security starters, or Actuator.
These are optional future decisions, not implied requirements.

### Consequence of the selected code-generation workflow

An ordinary build must **never** start PostgreSQL, migrate a database, or
regenerate jOOQ sources.

However, generated sources are not committed. Therefore:

> A fresh checkout, a schema-module clean, or a migration/configuration change
> requires an explicit schema-preparation step before building code that uses
> that schema module.

A clean checkout is not a database-independent full build. If generated sources
are missing or stale, fail with an actionable message; do not silently compile
an empty schema artifact or invoke a database task as a fallback.

## 3. What the existing structure actually does

### 3.1 Included-build architecture

The current arrangement is:

```text
Root application build
  settings.gradle
    pluginManagement.includeBuild("tools/gradle")
    application-module discovery
  gradle/libs.versions.toml

Independent included build: tools/gradle
  settings.gradle
    imports ../../gradle/libs.versions.toml
    includes convention-plugins
  build.gradle                         currently empty
  convention-plugins/build.gradle
    applies groovy-gradle-plugin
    declares external plugin implementation dependencies
  convention-plugins/src/main/groovy/*.gradle
    precompiled Groovy script plugins
```

An included build has its own settings, repositories, projects, and dependency
resolution. It does not automatically inherit the root build's version catalog.
Importing the same catalog in both builds is an essential part of this design.

`groovy-gradle-plugin` turns each precompiled script into a plugin. For example,
`java-core-conventions.gradle` makes the plugin ID
`java-core-conventions` available to consumers:

```groovy
plugins {
    id 'java-core-conventions'
}
```

Consumers do not specify a version for these local convention plugins.
Third-party plugins used inside the conventions must instead be available on
the convention build's implementation classpath.

### 3.2 Source inventory

Paths in this table refer to the source repository, relative to this document.

| Source | Observed responsibility | Target treatment |
| --- | --- | --- |
| [Root settings](../../settings.gradle) | Includes the plugin build, configures repositories and Foojay, recursively discovers subprojects | Keep the included-build wiring; use explicit module includes |
| [Root build](../../build.gradle) | Applies a project-specific group and version to all projects | Keep centrally defined identity, replace the values |
| [Included-build settings](settings.gradle) | Imports the root catalog and includes the plugin project | Retain |
| [Convention build](convention-plugins/build.gradle) | Makes external plugins, Flyway, FreeMarker, JDBC, and Testcontainers available and their supporting dependencies | Reduce to required plugins and their supporting dependencies |
| [Version catalog](../../gradle/libs.versions.toml) | Centralizes library and plugin coordinates, versions, and bundles | Replace with a minimal, aligned catalog |
| [Java convention](convention-plugins/src/main/groovy/java-core-conventions.gradle) | Java 21/Amazon, compiler checks, dependencies, test setup, Maven publication | Retain the Java/check/test concepts; remove vendor and publishing assumptions |
| [Server convention](convention-plugins/src/main/groovy/spring-boot-server-conventions.gradle) | Spring Boot, WebFlux/database libraries, database-backed test configuration, image tasks | Retain service dependencies; remove container/test/image coupling |
| [Utility convention](convention-plugins/src/main/groovy/springboot-utility-conventions.gradle) | Database defaults, shared Testcontainers service, Trivy helpers | Do not copy; replace only the necessary external-database configuration behavior |
| [Schema convention](convention-plugins/src/main/groovy/service-schema-conventions.gradle) | Flyway, jOOQ, generated-source integration, schema images, sibling-server wiring | Retain Flyway/jOOQ; redesign task wiring for explicit preparation |
| [Pipeline convention](convention-plugins/src/main/groovy/pipeline-conventions.gradle) | Project-specific pipeline dependencies and database/container commands | Omit entirely |
| [Template helper](convention-plugins/src/main/groovy/TemplateFileGenerator.groovy) and [Dockerfile template](convention-plugins/src/main/resources/templates/flyway-schema-dockerfile.ftl) | Generate migration-image Dockerfiles | Omit entirely; FreeMarker is not needed |
| [Example schema consumer](../../services/synthesiscore/schema/build.gradle) | Applies the schema convention and supplies schema/module names | Replace with the target schema extension shown below |
| [Example server consumer](../../services/synthesiscore/server/build.gradle) | Applies the server convention and supplies the application class/publication | Retain application identity; remove publication configuration |

### 3.3 Current plugin composition

```text
java-core-conventions
  + java
  + net.ltgt.errorprone
  + maven-publish

springboot-utility-conventions
  + java-core-conventions
  + database/container/scan helpers

spring-boot-server-conventions
  + java-core-conventions
  + springboot-utility-conventions
  + application
  + org.springframework.boot

service-schema-conventions
  + springboot-utility-conventions
  + nu.studer.jooq
  + org.flywaydb.flyway

pipeline-conventions
  + springboot-utility-conventions
  + application
  + org.springframework.boot
```

This is why copying only the convention-plugin directory is insufficient.
Conversely, deleting the utility script without changing its consumers would
leave unresolved plugin IDs and missing properties/services.

## 4. Target design and intentional differences

Keep only three public convention plugins:

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

`java-library` provides the normal Java tasks plus `api`/`implementation`
separation. This is useful because generated schema types expose jOOQ types to
their consumers. It does not publish anything by itself.

Use `bootRun` and `bootJar` for applications. The target does not need the
source's custom `start` alias or the `application` plugin.

| Existing assumption | Required target behavior |
| --- | --- |
| Recursive scanning for every nested build file | Explicitly include intentional modules; never discover caches, fixtures, or the included plugin build as application modules |
| Amazon-only toolchain | Java 21 from any suitable vendor |
| Multiple project-specific group/package prefixes | One documented base namespace, with explicit per-module generated packages |
| NullAway configured for `net.ltgt` | Configure it for the target application's actual package prefix |
| Versionless core test dependencies relying on another convention's BOM | Supply a JUnit BOM in the Java convention itself |
| Shared root extension holding a database service | Per-schema configuration; no global mutable connection state |
| Oreo database host/user/password defaults | No connection defaults; resolve explicitly provided per-service settings |
| `generateJooq` wired into compilation | Set `generateSchemaSourceOnCompilation = false`; compile only verified existing output |
| Schema plugin mutating a sibling server project | Declare the server-to-schema project dependency in the server build file |
| Flyway using classpath migrations | Use the module's SQL migration directory directly, avoiding a compilation/code-generation cycle |
| Flyway clean enabled in the source | Keep clean disabled; no automatic repair, baseline, reset, or deletion |
| Database-backed behavior attached to `test` | Unit tests remain database-free |
| Runtime and generator jOOQ versions not explicitly aligned | Pin and verify the same jOOQ version in all relevant classpaths |
| Server dependencies inheriting migration tooling | Keep Flyway/JDBC generation tooling out of the schema module's exported runtime dependencies |
| Docker/scan/cache-deletion tasks | Do not port them |

Project-local adaptation of the eager Flyway/jOOQ configuration APIs is
acceptable. Cross-project `afterEvaluate` mutation, nested Gradle invocations,
shell-based credential passing, and root-global database state are not.

## 5. Dependency and compatibility baseline

This is a reproducible starting baseline, not a claim that these are the latest
versions or that a security assessment has been completed.

| Component | Target starting version | Reason |
| --- | --- | --- |
| Gradle wrapper | `9.1.0` | Current source wrapper |
| Java runtime/toolchain | `21`, any vendor | Confirmed requirement; also satisfies the jOOQ plugin's JDK minimum |
| Spring Boot plugin and BOM | `4.0.3` | Current source baseline |
| Error Prone Gradle plugin | `4.3.0` | Current source baseline |
| Error Prone compiler | `2.44.0` | Current source baseline; validate on Java 21 |
| NullAway | `0.12.12` | Current source baseline |
| JSpecify | `1.0.0` | Nullability annotations |
| jOOQ Gradle plugin | `10.1.1` | Version used by the source's actual plugin implementation dependency |
| jOOQ runtime/codegen/metadata | `3.19.30` | Align with the Spring Boot 4.0.3 BOM rather than the source's `3.19.25` override |
| Flyway Gradle plugin/core/PostgreSQL support | `11.16.0` | Retain the source's migration-tool version, isolated from application BOM management |
| PostgreSQL JDBC driver | `42.7.10` | Spring Boot 4.0.3 BOM alignment |
| R2DBC PostgreSQL | BOM-managed (`1.1.1.RELEASE` in Boot 4.0.3) | Avoid an independent reactive-driver override |
| JUnit BOM/Jupiter | `6.0.3` | Spring Boot 4.0.3 alignment; still uses the JUnit Platform and Jupiter APIs |
| AssertJ | `3.27.7` | Spring Boot 4.0.3 alignment |
| PostgreSQL server for the reference acceptance environment | Plain PostgreSQL 17 | A reference development baseline; provisioned outside this project, without requiring pgvector |

Important compatibility details:

1. The Spring Boot 4.0.3 documentation supports Gradle 9.x and Java 21.
2. jOOQ Gradle plugin 10.x documents Gradle 8.6+, JDK 21+, and jOOQ 3.16+.
3. The jOOQ plugin defaults to a different jOOQ version than this target.
    Set `jooq.version` explicitly.
4. That setting alone does not align the jOOQ JAXB/metadata classes used by the
    plugin's own configuration DSL. The build-logic dependency recipe below also
    replaces its default `org.jooq` dependencies.
5. Boot 4.0.3 manages Flyway `11.14.1`, but this foundation uses `11.16.0` solely
    as build-time migration tooling. Do not import Boot's enforced platform into
    the convention-build implementation classpath and accidentally downgrade it.
6. A generator/runtime mismatch can compile successfully in one module and fail
    in another. Verify resolved dependencies, not only catalog declarations.
7. Do not carry over source Netty/Log4j BOM overrides by habit. Use Boot's
    dependency management unless a separately justified requirement changes it.

The implementer must validate this combination. If a reproducible incompatibility
requires changing a pin, record the evidence, change related pins together, and
rerun the relevant checks. Do not silently upgrade the entire stack.

## 6. Project identity and target layout

The real project identity has not been selected. Use these working values if
the owner has not supplied replacements:

| Setting | Working value |
| --- | --- |
| Root project name | `new-project` |
| Group | `com.example.foundation` |
| Base Java package | `com.example.foundation` |
| Initial version | `0.1.0-SNAPSHOT` |
| Example service | `catalog` |
| Example database schema | `catalog` |
| Example connection key | `catalog` |
| Generated package | `com.example.foundation.catalog.jooq` |

These are coherent example values, not new business requirements. Replace the
identity consistently, including source directories, NullAway configuration,
the main class, and generated packages.

```text
new-project/
  README.md
  .gitignore
  settings.gradle
  build.gradle
  gradle.properties
  gradlew
  gradlew.bat
  gradle/
    libs.versions.toml
    wrapper/
      gradle-wrapper.jar
      gradle-wrapper.properties
  tools/
    gradle/
      settings.gradle
      build.gradle
      convention-plugins/                 optional, empty
        build.gradle
        src/
          main/
            groovy/
              java-core-conventions.gradle
              spring-boot-server-conventions.gradle
              service-schema-conventions.gradle
              buildlogic/
                DatabaseSchemaExtension.groovy
                DatabaseConnectionSettings.groovy
                GeneratedSchemaState.groovy
                VerifyGeneratedJooq.groovy
          test/groovy/buildlogic/          pure helper unit tests
          functionalTest/groovy/buildlogic/ isolated Gradle TestKit tests
  libraries/
    common/
      build.gradle
      src/main/java/com/example/foundation/common/
      src/test/java/com/example/foundation/common/
  services/
    catalog/
      schema/
        build.gradle
        src/main/resources/db/migration/V1__create_item.sql
        build/generated-src/jooq/main/     generated, ignored
        build/jooq/generation-state.json   generated, ignored
      server/
        build.gradle
        src/main/java/com/example/foundation/catalog/server/
          CatalogApplication.java
          JdbcConfiguration.java
        src/main/resources/application.yaml
        src/test/java/com/example/foundation/catalog/server/
```

Do not copy any source `.gradle`, `build`, Maven cache, IDE cache, generated plugin classes, database credentials, or generated jOOQ sources.

## 7. Build bootstrap and complete simple-file templates

The snippets in this section define the simple build files. Section 10 specifies the database plugin and helper behavior that Codex must implement and test; it must not leave that behavior as placeholders.

### 7.1 Wrapper and Java installation

Require a locally available Java 21 JDK and run Gradle itself with it. The toolchain declaration alone does not install a JDK.

Generate the wrapper using a trusted Gradle installation, either before adding settings that reference not-yet-created projects or after scaffolding them:

```bash
gradle wrapper --gradle-version 9.1.0 --distribution-type bin
./gradlew --version
```

Commit both launcher scripts, the wrapper JAR, and its properties file. Obtain the distribution checksum from Gradle's official release checksum endpoint and set `distributionSha256Sum`; do not invent a checksum or handcraft the JAR. Preserve the executable bit on the Unix launcher.

The distribution URL is:

```properties
distributionUrl=https\://services.gradle.org/distributions/gradle-9.1.0-bin.zip
```

The source uses Foojay toolchain downloading. The minimal target does not need that extra settings plugin when Java 21 is installed. If automatic provisioning is later required, configure and test it separately for both the root build and the independent included build.

### 7.2 Root `settings.gradle`

```groovy
pluginManagement {
    includeBuild('tools/gradle')
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
    }
}

rootProject.name = 'new-project'

include(':libraries:common')
include(':services:catalog:schema')
include(':services:catalog:server')
```

Gradle automatically imports the root `gradle/libs.versions.toml` as `libs`.
Do not add a second `from(...)` import for that automatic root catalog.
Google's repository and `mavenLocal()` are unnecessary for the selected scope.

### 7.3 Root `gradle.properties`

```properties
projectGroup=com.example.foundation
projectVersion=0.1.0-SNAPSHOT
baseJavaPackage=com.example.foundation
```

These are non-secret identity settings. Do not put database credentials here.
Do not enable configuration caching for this foundation until the complete database adapter is proven compatible with it.

### 7.4 Root `build.gradle`

```groovy
def foundationGroup = providers.gradleProperty('projectGroup').get()
def foundationVersion = providers.gradleProperty('projectVersion').get()

allprojects {
    group = foundationGroup
    version = foundationVersion
}
```

Do not apply Java, Spring Boot, or the schema convention to the root or to intermediate directory projects. Apply conventions only in actual modules.

### 7.5 `tools/gradle/settings.gradle`

```groovy
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
    versionCatalogs {
        libs {
            from(files('../../gradle/libs.versions.toml'))
        }
    }
}

rootProject.name = 'build-logic'
include('convention-plugins')
```

This relative catalog path is correct for the specified directory structure.
If the build-logic directory moves, adjust this path and the root `includeBuild` path together.

### 7.6 Root `gradle/libs.versions.toml`

### 7.7 Convention-project `build.gradle`

```groovy
plugins {
    id 'groovy-gradle-plugin'
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

sourceSets {
    functionalTest {
        compileClasspath += sourceSets.main.output
        runtimeClasspath += sourceSets.main.output
    }
}

configurations {
    functionalTestImplementation.extendsFrom(testImplementation)
    functionalTestRuntimeOnly.extendsFrom(testRuntimeOnly)
}

dependencies {
    implementation libs.errorprone.plugin
    implementation libs.spring.boot.plugin
    implementation libs.flyway.plugin

    implementation(libs.jooq.plugin) {
        exclude group: 'org.jooq'
    }
    implementation libs.jooq.codegen

    testImplementation platform(libs.junit.bom)
    testImplementation libs.junit.jupiter
    testImplementation libs.assertj
    testRuntimeOnly libs.junit.launcher
    functionalTestImplementation gradleTestKit()
}

gradlePlugin {
    testSourceSets(sourceSets.functionalTest)
}

tasks.withType(Test).configureEach {
    useJUnitPlatform()
}

tasks.register('functionalTest', Test) {
    testClassesDirs = sourceSets.functionalTest.output.classesDirs
    classpath = sourceSets.functionalTest.runtimeClasspath
    shouldRunAfter(tasks.named('test'))
}

tasks.named('check') {
    dependsOn(tasks.named('functionalTest'))
}
```

The jOOQ exclusion is local to the plugin dependency. Adding the explicitly pinned codegen dependency restores its metadata/runtime classes at the intended version. Verify the resulting classpath rather than assuming the exclusion worked.

There is no `maven-publish` or plugin-publishing plugin. There is also no need for FreeMarker or any Testcontainers dependency.

### 7.8 Root `.gitignore` additions

```gitignore
.gradle/
**/.gradle/
**/build/
.env
.env.*
!.env.example
```

Merge these with an existing ignore file rather than replacing unrelated rules.
Gradle does not automatically read `.env` files; this foundation does not add a dotenv loader.

## 8. Java convention

Create `java-core-conventions.gradle`:

```groovy
import javax.lang.model.SourceVersion

plugins {
    id 'java-library'
    id 'net.ltgt.errorprone'
}

def basePackage = providers.gradleProperty('baseJavaPackage').get()
if (!SourceVersion.isName(basePackage)) {
    throw new GradleException('baseJavaPackage must be a valid Java package name')
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

configurations.configureEach {
    exclude group: 'junit', module: 'junit'
}

dependencies {
    errorprone libs.errorprone.core
    errorprone libs.nullaway
    compileOnlyApi libs.jspecify

    testImplementation platform(libs.junit.bom)
    testImplementation libs.junit.jupiter
    testImplementation libs.assertj
    testRuntimeOnly libs.junit.launcher
}

tasks.withType(JavaCompile).configureEach {
    options.encoding = 'UTF-8'
    options.compilerArgs.addAll([
        '-Xlint:all',
        '-Xlint:-processing',
        '-Werror',
        '-parameters'
    ])
    options.errorprone {
        disableWarningsInGeneratedCode.set(true)
        error('NullAway')
        option('NullAway:AnnotatedPackages', basePackage)
    }
}

tasks.withType(Test).configureEach {
    useJUnitPlatform()
}
```

Required behavior:

- A standalone common-library module can compile and test without a Spring Boot convention supplying dependency versions.
- Compiler warnings fail compilation, except explicitly justified generated-code exceptions scoped as described in section 10.
- NullAway checks application packages, not a package copied from a plugin's own namespace.
- A deliberate nullness violation in a fixture fails compilation.
- Use Jupiter tests initially; do not add JUnit 4, Vintage, or jqwik by default.
- Do not inherit the source's custom test-name filters. Test discovery must not silently omit valid Jupiter tests.
- Do not globally enable dynamic Java agent loading just to suppress a warning. If tests later need instrumentation, configure that tool explicitly.

The common-library build file is simply:

```groovy
plugins {
    id 'java-core-conventions'
}
```

Add a small meaningful Java class and a hermetic Jupiter test so this module actually exercises compilation and test discovery.

## 9. Spring Boot server convention

Create `spring-boot-server-conventions.gradle`:

```groovy
plugins {
    id 'java-core-conventions'
    id 'org.springframework.boot'
}

dependencies {
    implementation platform(libs.spring.boot.bom)
    implementation libs.spring.webflux
    implementation libs.spring.r2dbc
    implementation libs.spring.jooq
    implementation libs.hikari
    runtimeOnly libs.postgresql
    runtimeOnly libs.r2dbc.postgresql

    testImplementation libs.spring.test
    testImplementation libs.reactor.test
}
```

The server module declares its own relationships and identity:

```groovy
plugins {
    id 'spring-boot-server-conventions'
}

dependencies {
    implementation project(':libraries:common')
    implementation project(':services:catalog:schema')
}

springBoot {
    mainClass = 'com.example.foundation.catalog.server.CatalogApplication'
}
```
The convention must not:

- Set a hardcoded organization group or main class.
- Automatically search for a sibling schema project.
- Read database credentials during Gradle configuration.
- Add database actions or database properties to the `test` task.
- Add Flyway runtime dependencies, publishing configuration, or custom Docker tasks.

The Spring Boot plugin itself may expose standard upstream tasks such as `bootBuildImage`. Their presence is not a custom Docker integration. Do not configure, invoke, or attach them to any foundation workflow.

Boot's default logging stack is sufficient for this scope. A future Log4j2 decision should be implemented as a deliberate dependency change, not as a partially copied module-replacement rule.

## 10. Schema convention: implementation contract

This section is normative. Codex must implement the schema plugin and its helpers, not merely copy these contracts into comments.

### 10.1 Public module API

Create a `buildlogic.DatabaseSchemaExtension` with three Gradle `Property<String>` values:

| Property | Example | Validation |
| --- | --- | --- |
| `schemaName` | `catalog` | Required; match `[a-z][a-z0-9_]*` |
| `generatedPackage` | `com.example.foundation.catalog.jooq` | Required; valid Java package under the configured base package |
| `connectionKey` | `catalog` | Required; match `[a-z][a-z0-9_]*` |

Register it as `schemaDatabase`. Do not default these values from a parent project name or from `public`.

The module build file is:

```groovy
plugins {
    id 'service-schema-conventions'
}

schemaDatabase {
    schemaName = 'catalog'
    generatedPackage = 'com.example.foundation.catalog.jooq'
    connectionKey = 'catalog'
}
```

Validate structural configuration after the consuming module has supplied it. It is appropriate to fail configuration for an absent/invalid schema name or package. An absent database password must **not** make `help` fail.

Use provider-backed properties. Where the Flyway/jOOQ DSL requires eager strings, a small project-local `afterEvaluate` adapter may transfer finalized non-secret schema/package values. Register tasks independently of that adapter. Do not use this hook to read credentials, connect to PostgreSQL, execute tasks, or mutate another project.

### 10.2 Applied plugins and classpaths

Apply:

```groovy
plugins {
    id 'java-core-conventions'
    id 'nu.studer.jooq'
    id 'org.flywaydb.flyway'
}
```

Create a resolvable, non-consumable configuration named `flywayMigration`.

Declare:

| Configuration | Dependency | Purpose |
| --- | --- | --- |
| `api` | `libs.jooq.runtime` | Expose the jOOQ API used in generated public types |
| `jooqGenerator` | `libs.postgresql` | JDBC driver for introspection |
| `flywayMigration` | `libs.postgresql` | JDBC driver for migration execution |
| `flywayMigration` | `libs.flyway.postgresql` | PostgreSQL database support for Flyway |

The jOOQ plugin supplies its generator dependency when its version is configured. Flyway core comes from the build-logic plugin dependency.

Configure Flyway to use only the dedicated `flywayMigration` configuration, not the module's compilation/test/runtime configurations. This isolates the tooling and avoids introducing dependencies on generated/compiled application classes.

Do not add Spring starters, R2DBC, database containers, or migration tooling to the schema module's `api`/`implementation`/`runtimeOnly` configurations. Its normal resources may contain SQL migrations, but the server must not run them automatically.

### 10.3 Connection settings and secret handling

Implement `buildlogic.DatabaseConnectionSettings` as a small reusable resolver and validator. The resolution algorithm must be independently unit-testable using supplied maps/values, without reading the process environment or the filesystem inside the pure helper.

For `connectionKey = 'catalog'`:

| Value | Gradle property | Environment variable |
| --- | --- | --- |
| JDBC URL | `catalog.db.url` | `CATALOG_DB_URL` |
| Migration username | `catalog.db.user` | `CATALOG_DB_USER` |
| Migration password | `catalog.db.password` | `CATALOG_DB_PASSWORD` |

Derive the environment prefix by uppercasing the connection key with `Locale.ROOT`. For example, `order_management` becomes `ORDER_MANAGEMENT`.

Resolution rules:

1. An explicitly present per-service Gradle property takes precedence.
2. Otherwise use the matching environment variable.
3. Otherwise fail with the missing setting names.
4. A present-but-empty property is an error, not a request to fall back.
5. There are no global `DB_*` fallbacks and no embedded credentials/default server address.
6. Resolve these values only during execution of a requested database task. Use Gradle providers at the boundary.
7. Require a PostgreSQL JDBC URL. Reject credentials embedded in the URL; credentials must remain separate values. Do not log the URL in errors.
8. Reject missing/blank URLs and usernames and empty passwords. Preserve password content exactly; do not trim it.
9. Errors identify the module and setting names, not the supplied values.
10. Never produce a default `toString()` or diagnostic representation that contains a password.

Prefer environment variables or a protected user-level Gradle properties file. Do not put passwords in a tracked file or in `-P...password=...` command-line arguments. Do not print resolved settings.

Gradle and jOOQ may create transient local files, including generator XML, that contain connection data. Keep build/cache directories ignored, avoid debug logging and uploading those files, and treat local artifacts as sensitive. Do not promise that passwords never exist in process memory or local tool files.

### 10.4 Flyway configuration

Use these values:

| Setting | Required value |
| --- | --- |
| Driver | `org.postgresql.Driver` |
| Locations | One absolute `filesystem:` location for this module's `src/main/resources/db/migration` |
| `schemas` | Only the configured service schema |
| `defaultSchema` | The configured service schema |
| History table | `flyway_schema_history` in that service schema |
| `createSchemas` | `false`; provision the schema outside Gradle |
| `validateOnMigrate` | `true` |
| `validateMigrationNaming` | `true` |
| `outOfOrder` | `false` |
| `baselineOnMigrate` | `false` |
| `cleanDisabled` | `true` |
| Configurations | Only `flywayMigration` |

The database and service schema must already exist. Use a migration role with rights to that schema, not an administrative account managing the whole shared database.

Set connection values on the actual Flyway task/extension before its task action executes. Do not set them to empty strings at configuration time and hope the tool guesses correctly.

Do not allow generic Flyway environment/system-property/config-file overrides to silently redirect the target or disable safety settings. The adapter must either reject conflicting overrides with a safe error or demonstrate, through tests against the pinned plugin, that the per-service values and safety policy remain authoritative.

Do not attach `flywayClean`, `flywayRepair`, or `flywayBaseline` to preparation, build, or application startup. If `flywayClean` is explicitly invoked, it must fail rather than delete data. Administrative repair/baseline workflows require a separate owner-approved procedure.

### 10.5 jOOQ configuration

Create the `main` jOOQ configuration with:

| Setting | Required value |
| --- | --- |
| Version | `libs.versions.jooq`, explicitly set |
| Edition | OSS |
| `generateSchemaSourceOnCompilation` | `false` |
| Logging | `WARN`, not the source's `DEBUG` setting |
| JDBC driver | `org.postgresql.Driver` |
| Connection values | The same per-module resolved settings used by Flyway |
| Generator | `org.jooq.codegen.DefaultGenerator` |
| Database | `org.jooq.meta.postgres.PostgresDatabase` |
| Input schema | Only the configured service schema |
| Includes | The service's tables; `.*` for the example |
| Excludes | `flyway_schema_history` |
| Records | `true` |
| POJOs | `true` |
| Immutable POJOs | `true` |
| Fluent setters | `true` |
| Index metadata | `false` |
| Deprecated members | `false` |
| Target package | `schemaDatabase.generatedPackage` |
| Target directory | Absolute module path for `build/generated-src/jooq/main` |

Keep the output directory fixed at configuration time so Gradle and the jOOQ plugin agree on source/output locations. Populate execution-only connection values without relying on configuration-time database access.

The jOOQ plugin already adds its output directory to the matching Java source set. With automatic generation disabled, do not re-add it using a task-output provider that inadvertently recreates a compile-to-generate dependency.

Treat the external database as an undeclared, mutable input:

- Explicit generation must actually execute after migration.
- Do not mark all generator inputs as declared merely because SQL files exist.
- Disable output-based up-to-date skipping and build-cache reuse for database preparation/generation tasks.
- Do not cache credentials or serialize them into a reusable configuration cache. Configuration-cache support is not a completion claim for this version.

### 10.6 Required tasks and dependency graph

Register/configure these tasks in each schema module:

| Task | Responsibility |
| --- | --- |
| `validateSchemaDatabase` | Validate required connection settings; no network connection |
| `flywayInfo` | Explicitly inspect this service's migration state |
| `flywayValidate` | Explicitly validate this service's migration history |
| `flywayMigrate` | Explicitly apply migrations to this service's schema |
| `generateJooq` | Migrate, then introspect and generate Java sources |
| `prepareSchema` | Friendly lifecycle task depending on `generateJooq` |
| `verifyGeneratedJooq` | Check existing output/state; never contact the database |

Required graph:

```text
prepareSchema
  -> generateJooq
      -> flywayMigrate
          -> validateSchemaDatabase

flywayInfo     -> validateSchemaDatabase
flywayValidate -> validateSchemaDatabase

compileJava -> verifyGeneratedJooq
check       -> verifyGeneratedJooq
```

There must be **no** dependency from `compileJava`, `test`, `check`, `jar`, `bootJar`, `build`, or `bootRun` to migration or generation.

`verifyGeneratedJooq` must run after `generateJooq` if both are present in the same task graph. Use an ordering relationship, not a dependency that schedules generation. Thus `prepareSchema build` works, while `build` alone never prepares the schema.

The server depends on the schema's normal Java artifact through an explicit project dependency. Do not mutate the server's `bootRun` task from the schema plugin.

### 10.7 Generated-source state and failure behavior

Implement `buildlogic.GeneratedSchemaState` for deterministic, pure fingerprint and comparison logic. Implement `buildlogic.VerifyGeneratedJooq` as the thin Gradle task handling isolated file access and clear failures.

Store successful preparation state in:

```text
services/<service>/schema/build/jooq/generation-state.json
```

The state must include:

- A format version, initially `1`.
- A SHA-256 fingerprint of generation inputs.
- A sorted manifest of generated Java files with relative paths and SHA-256 content hashes.

The input fingerprint must deterministically cover:

1. Service schema and generated package.
2. The selected jOOQ and Flyway versions.
3. Generator selection/filter/flag configuration from section 10.5.
4. Every SQL migration's normalized relative path and content hash, sorted by relative path.

Use a canonical encoding with unambiguous field boundaries, such as a deterministically serialized structure. Do not hash concatenated strings without delimiters. Do not include timestamps, absolute checkout paths, credentials, or machine-specific state.

Successful preparation:

1. Validate configuration.
2. Invalidate any previous successful-generation marker before migration changes the database.
3. Run Flyway migration.
4. Remove only the configured module-local generated-source output before regenerating, so deleted tables do not leave old Java files behind.
5. Generate sources.
6. Verify that nonempty Java output exists.
7. Compute the input fingerprint and generated-file manifest.
8. Atomically replace the state file only after all preceding steps succeed.

If migration or generation fails, preserve the original failure and leave no valid successful-generation marker. Do not catch an error and return a success-shaped result.

`verifyGeneratedJooq` must:

- Run even if `compileJava` would otherwise be up to date.
- Fail if the marker is missing, malformed, unsupported, or mismatched.
- Fail if the generated Java output is empty, missing, changed, or has a different file set.
- Fail if migrations, the generated package, relevant generation flags, or the pinned tool versions changed.
- Explain that the module's `prepareSchema` command is required.
- Never read connection settings or connect to a database.

Do not mark missing inputs as `@SkipWhenEmpty`; that would turn an invalid schema artifact into a successful skipped task.

This marker proves consistency with the last local preparation, not that the external database has never drifted. `flywayValidate` and controlled migration ownership remain necessary.

### 10.8 Generated-code compiler exceptions

Keep strict checks on handwritten Java.

Exclude only the exact generated jOOQ source directory from Error Prone/NullAway analysis, using a correctly escaped path pattern. Confirm it works on supported path formats and does not exclude handwritten source directories.

If jOOQ output triggers unavoidable javac serial/deprecation warnings, apply only the necessary lint exceptions to the schema module and document them. Do not remove `-Werror` from every module or suppress NullAway project-wide.

## 11. PostgreSQL ownership and example integration

Database provisioning is outside this foundation. Before live acceptance, the owner must supply:

- A reachable, non-production PostgreSQL instance.
- A shared development database, such as `new_project_dev`.
- A pre-created schema named `catalog`, owned/managed by a catalog migration role.
- A separate application role with only the runtime permissions it needs.
- Connection endpoints and credentials through an approved local mechanism.

Do not have Codex install a server, create containers, use an existing production database, or assume privileged credentials.

Create the example `V1__create_item.sql` with:

```sql
CREATE TABLE catalog.item (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL
);
```

The schema name is intentionally qualified. For a second service, create a different schema and its own migration directory/history.

Keep migrations immutable after they have been applied to a shared database.
Add a new versioned migration rather than changing an applied migration or
automatically invoking repair.

The initial migration should generate at least:

```text
com/example/foundation/catalog/jooq/Tables.java
com/example/foundation/catalog/jooq/tables/Item.java
com/example/foundation/catalog/jooq/tables/records/ItemRecord.java
```

Also verify the requested immutable POJO output. Exact additional generated files
depend on the pinned generator, but Flyway's history table and other services'
tables must not become application-generated types.

## 12. Runtime: WebFlux, R2DBC, and JDBC/jOOQ

### 12.1 These are two distinct database access paths

The selected stack deliberately retains:

- R2DBC for non-blocking database operations.
- JDBC/jOOQ for blocking SQL operations using the generated model.

Adding the R2DBC starter does not make JDBC-based jOOQ queries reactive.
Additionally, when Spring Boot sees an R2DBC `ConnectionFactory`, its normal
JDBC `DataSource` auto-configuration backs off. Merely setting both
`spring.datasource.*` and `spring.r2dbc.*` is therefore not sufficient.

Provide an explicit JDBC data source and JDBC transaction manager, and let
Boot's jOOQ auto-configuration use them. Do not introduce an ad hoc `DSLContext`
that bypasses Spring's transaction integration without a deliberate design.

The transaction manager is a second, separate concern: Boot 4.0.3's JDBC
transaction-manager auto-configuration backs off when any `TransactionManager`
already exists, including a reactive one. Its R2DBC transaction-manager
auto-configuration only checks for an existing `ReactiveTransactionManager`.
An explicit JDBC manager therefore allows both models to coexist reliably.

### 12.2 Main class

```java
package com.example.foundation.catalog.server;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class CatalogApplication {
    public static void main(String[] args) {
        SpringApplication.run(CatalogApplication.class, args);
    }
}
```

### 12.3 Explicit JDBC data source and transaction manager

```java
package com.example.foundation.catalog.server;

import javax.sql.DataSource;

import com.zaxxer.hikari.HikariDataSource;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.support.JdbcTransactionManager;

@Configuration(proxyBeanMethods = false)
public class JdbcConfiguration {
    @Bean
    @ConfigurationProperties("app.jdbc")
    public HikariDataSource jooqDataSource() {
        return new HikariDataSource();
    }

    @Bean
    public JdbcTransactionManager jdbcTransactionManager(DataSource dataSource) {
        return new JdbcTransactionManager(dataSource);
    }
}
```

The data source must be managed and closed by Spring. Let Boot supply the
reactive transaction manager for the R2DBC connection factory. Validate property
binding, both transaction-manager types, and the jOOQ `DSLContext`/Spring
transaction provider with a focused context test using isolated doubles.
Do not replace missing database infrastructure with a success fallback.

### 12.4 Runtime configuration

Use this `application.yaml` shape:

```yaml
spring:
  application:
    name: catalog
  main:
    web-application-type: reactive
  r2dbc:
    url: ${CATALOG_R2DBC_URL}
    username: ${CATALOG_APP_DB_USER}
    password: ${CATALOG_APP_DB_PASSWORD}
    properties:
      schema: catalog
  jooq:
    sql-dialect: postgres
  flyway:
    enabled: false
  sql:
    init:
      mode: never

app:
  jdbc:
    jdbc-url: ${CATALOG_DB_URL}
    username: ${CATALOG_APP_DB_USER}
    password: ${CATALOG_APP_DB_PASSWORD}
    schema: catalog
```

Use separate migration and application credentials:

| Purpose | Settings |
| --- | --- |
| Gradle migration/generation | `CATALOG_DB_URL`, `CATALOG_DB_USER`, `CATALOG_DB_PASSWORD` |
| Application JDBC | Same database endpoint, but `CATALOG_APP_DB_USER` and `CATALOG_APP_DB_PASSWORD` |
| Application R2DBC | `CATALOG_R2DBC_URL`, with the application credentials |

Do not derive a general R2DBC URL by blindly replacing `jdbc` with `r2dbc`.
Driver URL parameters and connection options need not be interchangeable.

For the reference local database, the non-secret URL shapes are:

```text
jdbc:postgresql://localhost:5432/new_project_dev
r2dbc:postgresql://localhost:5432/new_project_dev
```

Do not embed passwords or enable a development profile automatically.
Disabling startup migration does not remove the application's need for valid
runtime connection settings.

### 12.5 Isolate blocking jOOQ calls

An illustrative repository method is:

```java
public Mono<Integer> countItems() {
    return Mono.fromCallable(() -> dsl.fetchCount(ITEM))
        .subscribeOn(Schedulers.boundedElastic());
}
```

Here `dsl` is an injected JDBC-backed `DSLContext`, `ITEM` is the generated
table constant, and `Mono`/`Schedulers` are Reactor types.

Requirements:

- Start the JDBC operation inside `fromCallable` or an equivalent deferred boundary.
- Move the blocking subscription to a bounded blocking-work scheduler.
- Do not use `Mono.just(dsl.fetchCount(...))`; that executes the query before scheduling.
- Do not call `.block()` on the WebFlux request path.
- Keep a JDBC transaction's entire blocking unit of work inside the scheduled boundary. Explicitly select `jdbcTransactionManager` for imperative transactional methods or a JDBC `TransactionTemplate`.
- Select the reactive transaction manager for R2DBC operations. In the pinned Boot configuration its default bean name is `connectionFactoryTransactionManager`; verify that name if the configuration is customized. Do not use ambiguous, unqualified transactional declarations.
- Do not assume a reactive R2DBC transaction and a JDBC transaction are one atomic transaction merely because they use the same database/schema.
- Use fake query collaborators and a controllable scheduler in unit tests; verify deferral and failure propagation without a real database or timing assumptions.

Implement one small example adapter that references generated jOOQ code, with
tests, so the server-to-schema compilation and the blocking boundary are actually
exercised. A business API, authentication model, and deployment architecture are
not part of this foundation.

## 13. Implementation sequence for Codex

### Phase A: establish the target safely

1. Confirm the target working directory before writing. This guide does not identify an existing target path.
2. Inspect any existing files and preserve unrelated changes.
3. Record the selected identity or use section 6's working values.
4. Scaffold only the in-scope directories/files.
5. Generate the wrapper and verify Java/Gradle versions.

### Phase B: prove the included build and Java baseline

1. Create settings, the shared catalog, and the convention-project build.
2. Write failing tests for the connection resolver and generated-state logic.
3. Implement those pure helpers.
4. Implement the Java convention.
5. Add and run the common-library sample/test.
6. Prove a fixture can resolve each local plugin ID.

### Phase C: implement schema behavior without a live database

1. Write functional tests for the extension and task graph.
2. Implement the schema extension, plugin, and verification task.
3. Test missing configuration, bad configuration, stale output, and failure invalidation.
4. Confirm `help` and task listing work without database credentials.
5. Confirm an unprepared schema compile fails clearly without scheduling migrations or generation.
6. Confirm the generated-source flags and classpaths match this specification.

### Phase D: implement the service baseline

1. Implement the server convention and explicit module dependencies.
2. Add the application class, JDBC data source/transaction-manager configuration, and runtime YAML.
3. Add the deferred jOOQ adapter and hermetic unit tests.
4. Test the reactive/JDBC configuration with doubles, not Testcontainers.
5. Check that no excluded dependency or custom task was introduced.

### Phase E: validate with an owner-provided database

1. Obtain an approved non-production database/schema and scoped credentials.
2. Run migration and generation explicitly.
3. Compile the generated model and package the service.
4. Verify migration repeatability, schema isolation, and resolved dependency versions.
5. Verify application context/runtime connectivity only through an explicit manual acceptance step, not through the unit-test task.
6. Report any unavailable external prerequisite as a blocker; do not substitute an embedded database or container.

### Phase F: document and hand off

1. Add the commands, environment-variable contract, module onboarding steps, and generated-source lifecycle to the target README.
2. Record actual verification results and any remaining blockers.
3. Do not claim completion based solely on successful `help` or mocked tests.

## 14. Test specification

### 14.1 Pure unit tests

Keep these in the build-logic project's normal test source set. Supply in-memory
inputs; do not use network, process environment mutation, real credentials,
filesystem access, clocks, or random identifiers.

| Area | Required cases |
| --- | --- |
| Connection precedence | Property overrides environment; environment works when property is absent |
| Missing values | Each required setting missing; all missing; error lists names only |
| Invalid values | Present-empty property does not fall back; non-PostgreSQL URL; embedded credentials |
| Secret treatment | Password spaces preserved; exceptions and object representation do not reveal values |
| Namespace validation | Valid/invalid schema, key, Java package, and package prefix |
| Fingerprint stability | Identical logical inputs in different collection order produce the same result |
| Fingerprint sensitivity | Migration add/change/delete/rename; package/schema/tool-version/flag changes |
| Output manifest | Added/removed/modified Java file; empty output |
| State decoding | Missing fields, malformed state, unsupported format |
| Error behavior | Original failure propagated; no successful result after preparation failure |

### 14.2 Isolated Gradle TestKit tests

Keep these in `functionalTest`, separate from pure unit tests.

Use temporary fixture directories and Gradle TestKit's plugin-under-test
classpath. Every fixture consuming these conventions must provide its own
settings, required catalog, and non-secret identity properties.

Dependency downloads belong to dependency setup, not to assertions about
database behavior. Once dependencies are available, run functional fixtures
offline with isolated local outputs. Never contact a live database in this suite.

Required assertions:

1. All three plugin IDs resolve.
2. The included build can be built/tested independently.
3. Java 21 is selected without a vendor restriction.
4. The Java-only fixture resolves Jupiter/Launcher versions without Boot.
5. A valid class compiles; a deliberate NullAway violation fails.
6. `help`, `projects`, and schema task listing need no database credentials.
7. `compileJava --dry-run` has verification but no Flyway/generation tasks.
8. `prepareSchema --dry-run` has validation, migration, and generation in order.
9. Missing generated output fails compile with the exact preparation task path.
10. A valid fixture-generated tree/state passes verification without DB settings.
11. Changed migrations or generated files fail verification.
12. A failed preparation leaves no valid success marker. Use controlled fake execution in the test fixture, not a production "skip database" feature.
13. `prepareSchema build` ordering does not verify before generation.
14. Two schema modules retain independent schemas, connection keys, outputs, task dependencies, and state files.
15. Secrets do not appear in captured output, exceptions, or stored state.
16. Conflicting Flyway overrides cannot redirect execution or enable cleaning.
17. No custom container, image, scan, publishing, pipeline, or cache-purge tasks are introduced.
18. Excluding generated code from static analysis does not exclude handwritten application code.

Share fixture construction and assertions rather than duplicating whole
settings/catalog/build scripts across tests.

### 14.3 Application unit tests

Use plain Jupiter/AssertJ and Reactor test support, with fake database-facing
collaborators:

- The jOOQ operation is deferred until subscription.
- Success and failure propagate through the reactive boundary.
- Scheduling can be controlled without sleeps or real JDBC.
- Data source property binding uses the application-role settings.
- R2DBC and JDBC/jOOQ configuration can coexist.
- Both imperative and reactive transaction managers exist, and jOOQ uses the Spring transaction provider associated with the JDBC manager.
- Startup SQL initialization and Flyway migration remain disabled.

Avoid an unqualified full `@SpringBootTest` that tries to connect to the external
database during a normal unit-test run.

### 14.4 Controlled database acceptance

This is an explicit manual integration check against the provided development
database, not part of `test` or `check`.

Verify:

- Migration creates the example table and history only in the service schema.
- A second migrate does not reapply an already applied migration.
- Generation uses the intended schema and excludes Flyway history/other schemas.
- The generated code compiles against the resolved runtime jOOQ version.
- A second service can be prepared without modifying the first service's schema.
- A migration/generation failure is visible and invalidates local generation state.
- A normal build after successful preparation performs no database work.

Use only approved disposable development data for failure scenarios.

## 15. Command runbook and expected outcomes

Commands below run from the target repository root. On Windows use the wrapper
launcher appropriate for the shell.

### 15.1 No database required

```bash
./gradlew --version
./gradlew help projects
./gradlew -p tools/gradle :convention-plugins:test :convention-plugins:functionalTest
./gradlew :libraries:common:test
./gradlew :services:catalog:schema:tasks --all
./gradlew :services:catalog:schema:compileJava --dry-run
./gradlew :services:catalog:schema:prepareSchema --dry-run
```

Expected:

- Gradle 9.1.0 runs on Java 21.
- The explicit modules are listed; build logic is a separate included build.
- Local plugins compile and tests pass.
- No database credential is required merely to configure/list the build.
- Compile has a verification dependency, not migration/generation.
- Preparation has the dependency order specified in section 10.

First-time wrapper and dependency downloads still require access to the
configured distribution/artifact repositories. "No database required" does not
mean "works offline with an empty dependency cache."

### 15.2 Expected failure before preparation

```bash
./gradlew :services:catalog:schema:compileJava
```

Expected: nonzero exit with a message such as:

```text
Generated jOOQ sources for :services:catalog:schema are missing or stale.
Configure the catalog database settings and run:
./gradlew :services:catalog:schema:prepareSchema
```

No migration, generator, container, or connection attempt may occur.

### 15.3 Explicit preparation

Set the non-secret endpoint and migration-role username in the environment.
Provide `CATALOG_DB_PASSWORD` through the approved secret-entry mechanism;
do not paste a real password into the command history or this document.

Then:

```bash
./gradlew :services:catalog:schema:flywayInfo
./gradlew :services:catalog:schema:prepareSchema
./gradlew :services:catalog:schema:flywayValidate
```

Expected:

- Settings are validated without printing credentials.
- Flyway touches only `catalog`.
- Java files appear under the module's generated-source directory.
- A valid generation-state file is written only after success.

### 15.4 Compile, test, and package after preparation

```bash
./gradlew :services:catalog:schema:verifyGeneratedJooq
./gradlew :libraries:common:test :services:catalog:server:test
./gradlew :services:catalog:server:bootJar
```

Expected: all pass with no migration/generation and no live database access by
unit tests. These commands should still work after removing migration
credentials from the environment, provided generated output remains valid.

If application context tests require real credentials, fix their isolation;
do not reintroduce database behavior into the test convention.

### 15.5 Clean rebuild

Use separate commands to make the lifecycle obvious:

```bash
./gradlew clean
./gradlew :services:catalog:schema:prepareSchema
./gradlew build
```

`clean` removes generated output/state. For multiple services, explicitly prepare
each schema needed by the build. Do not add an automatic root preparation
dependency to hide this requirement.

### 15.6 Dependency alignment checks

```bash
./gradlew -p tools/gradle :convention-plugins:dependencyInsight \
  --configuration runtimeClasspath --dependency org.jooq

./gradlew -p tools/gradle :convention-plugins:dependencyInsight \
  --configuration runtimeClasspath --dependency flyway-core

./gradlew :services:catalog:schema:dependencyInsight \
  --configuration jooqGenerator --dependency org.jooq

./gradlew :services:catalog:server:dependencyInsight \
  --configuration runtimeClasspath --dependency org.jooq

./gradlew :services:catalog:schema:dependencies \
  --configuration flywayMigration
```

Expected:

- jOOQ metadata/codegen/runtime resolve consistently to `3.19.30`.
- Build-time Flyway core/PostgreSQL support resolve to `11.16.0`.
- The server does not inherit Flyway tooling or Testcontainers from the schema.
- Driver versions match the intended baseline.

Also inspect the server runtime dependencies for unexpected WebMVC/JPA,
Testcontainers, or unrequested source-project libraries.

### 15.7 Explicit application smoke check

Only after owner-provided runtime connection settings and a prepared schema:

```bash
./gradlew :services:catalog:server:bootRun
```

This is a manual application launch, not a unit test. Verify both connection
paths using controlled development data and stop the application afterward.
It must not migrate the database at startup.

## 16. Adding a second service

For an example service named `orders`:

1. Add explicit includes for `:services:orders:schema` and
    `:services:orders:server`.
2. Create the two module build files using the same convention IDs.
3. Set:
    - `schemaName = 'orders'`
    - `connectionKey = 'orders'`
    - `generatedPackage = 'com.example.foundation.orders.jooq'`
4. Provide independent `ORDERS_DB_*` migration settings and
    `ORDERS_APP_DB_*` / `ORDERS_R2DBC_URL` runtime settings.
5. Provision the `orders` schema and roles outside Gradle.
6. Add only orders-owned migrations to its schema module.
7. Declare the orders server's explicit dependency on its schema module.
8. Set the orders main class and runtime schema selection.
9. Prepare orders explicitly, then build/test it.

The JDBC endpoints can identify the same development database. The schema,
ownership, history, generated package, output, and task state must remain
separate.

Do not add cross-service database ownership or cross-schema generation as an
implicit extension. If it becomes required, make it a new architecture decision.

## 17. Troubleshooting and boundaries

| Symptom | Likely cause / action |
| --- | --- |
| Convention plugin not found | Check root `pluginManagement.includeBuild`, the included project, and script filenames |
| `libs` unavailable in build logic | Import the catalog in the included build's settings |
| Catalog imported more than once | Do not manually re-import the automatically created root `libs` catalog |
| Third-party plugin unavailable in a precompiled script | Add its implementation artifact to the convention build; a catalog alias alone is insufficient |
| No matching Java 21 installation | Install/provide Java 21; do not silently select Java 17 or reintroduce an Amazon requirement |
| Java-only tests cannot resolve Jupiter/Launcher | Ensure the Java convention supplies the JUnit BOM |
| `help` requires a password | Connection resolution is happening too early |
| `build` starts migration/generation | Check `generateSchemaSourceOnCompilation`, source-directory providers, and task dependencies |
| Fresh build cannot find generated types | Explicit preparation is required; the verification task should report this before compilation |
| Stale classes remain after dropping a table | Generation did not clean its own output or the manifest check is incomplete |
| Flyway cannot handle PostgreSQL | Check the dedicated migration classpath and database-support module |
| Flyway wants compiled schema classes | Use filesystem SQL locations and isolate the migration classpath |
| Flyway targets the wrong schema/database | Check per-service keys and reject conflicting generic Flyway overrides |
| jOOQ XML/configuration or linkage mismatch | Inspect plugin DSL, generator, and application classpaths together |
| No JDBC `DataSource`/`DSLContext` with R2DBC present | Add/verify the explicit JDBC data source; R2DBC causes JDBC auto-configuration to back off |
| JDBC transactions are absent or the transaction manager is ambiguous | Declare the explicit JDBC manager, verify the reactive manager also exists, and select the appropriate one |
| WebFlux requests block | Ensure the JDBC call is deferred and scheduled outside event-loop threads |
| Tests require DB credentials | Replace database operations/full application startup with isolated doubles |
| Database state changed but fingerprint did not | The fingerprint describes source/output consistency, not live DB drift; explicitly validate/prepare against the controlled schema |

Do not treat a successful dependency-resolution check as proof of database
connectivity or generator compatibility. Do not treat an application launch as
proof that its tests are isolated.

This guide does not define production migration orchestration, secret-manager
integration, centralized plugin distribution, deployment, database backups,
authentication, or CI. Those are follow-on decisions, not missing steps to fill
with guessed implementations.

## 18. Codex handoff prompt

Copy the following prompt together with this entire document into the target
Codex session:

```text
Implement the Gradle convention-plugin foundation specified in the attached
"Reusing the Gradle convention plugins in a new monorepo" document.

You have the document and the target repository; do not assume access to db-oreo.
Confirm the target directory before writing. Preserve unrelated existing work.
If project identity is still unspecified, use the document's coherent example
identity and make every replacement point clear in the README.

Confirmed scope:
- Local included build at tools/gradle, using Groovy precompiled script plugins.
- Java 21, any vendor; strict compiler checks, Error Prone, NullAway, unit tests.
- Spring Boot services using WebFlux and R2DBC, plus isolated blocking JDBC/jOOQ.
- External PostgreSQL with one schema per service.
- Explicit Flyway migration and jOOQ generation.
- Untracked generated sources with missing/stale-output verification.
- No automatic migration or generation during ordinary build/test/run tasks.
- No Flyway migration at application startup.

Do not implement Testcontainers, containers/images, Hadolint/Trivy, pipelines,
Maven publishing, CI workflows, or coverage gates.

Treat the document's schema-plugin contracts, task graph, secret-handling rules,
version alignment, and failure behavior as requirements. Implement the helpers
and tests; do not leave contracts as comments, TODOs, or no-op tasks.

Work test-first. Separate pure helper tests from isolated Gradle TestKit tests.
Use explicit module dependencies and no root-global database service/state.
Do not expose passwords or use production databases.

Run all available database-free checks. Run live migration/generation checks only
after an approved external development database and scoped credentials are
provided. If they are unavailable, finish the database-free implementation and
report the exact unverified acceptance steps; do not fabricate success or add a
container/embedded database as a substitute.

Update the target README with actual setup, module onboarding, environment
variables, preparation/build commands, and limitations. Report changed files,
commands and results, dependency resolutions, and any remaining blockers.
```

### Definition of done

The target is complete only when:

- The three conventions resolve from the local included build.
- The Java-only library builds/tests independently of Spring Boot and PostgreSQL.
- Build-logic unit and functional tests pass.
- The external database preparation path has been exercised successfully.
- Generated models compile and the example service packages successfully.
- Normal builds/tests do not connect to PostgreSQL or run migrations/generation.
- Missing/stale output and failed preparation produce the specified errors.
- Runtime R2DBC and JDBC/jOOQ coexist without blocking the reactive event loop.
- Per-service schema/connection/state isolation is demonstrated.
- No excluded feature was introduced.
- The README accurately records the setup and actual verification.

If live database acceptance is blocked, distinguish "implementation and
database-free checks completed" from "end-to-end verified."

## 19. Primary references

These references explain the external mechanisms used by the specification.
The pinned metadata is especially important when newer documentation describes
a later release.

- [Gradle 9.1 composite builds and plugin included builds](https://docs.gradle.org/9.1.0/userguide/composite_builds.html)
- [Gradle 9.1 version catalogs](https://docs.gradle.org/9.1.0/userguide/version_catalogs.html)
- [Gradle 9.1 precompiled script plugins](https://docs.gradle.org/9.1.0/userguide/implementing_gradle_plugins_precompiled.html)
- [Gradle 9.1 wrapper guidance](https://docs.gradle.org/9.1.0/userguide/gradle_wrapper.html)
- [Gradle 9.1.0 distribution checksum](https://services.gradle.org/distributions/gradle-9.1.0-bin.zip.sha256)
- [Spring Boot 4.0.3 dependency BOM](https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-dependencies/4.0.3/spring-boot-dependencies-4.0.3.pom)
- [Spring Boot 4.0.3 system requirements source](https://github.com/spring-projects/spring-boot/blob/v4.0.3/documentation/spring-boot-docs/src/docs/antora/modules/ROOT/pages/system-requirements.adoc)
- [Spring Boot 4.0 SQL and R2DBC documentation](https://docs.spring.io/spring-boot/4.0/reference/data/sql.html)
- [Spring Boot 4.0.3 JDBC-based jOOQ starter metadata](https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-starter-jooq/4.0.3/spring-boot-starter-jooq-4.0.3.pom)
- [Spring Boot 4.0.3 JDBC transaction-manager conditions](https://github.com/spring-projects/spring-boot/blob/v4.0.3/module/spring-boot-jdbc/src/main/java/org/springframework/boot/jdbc/autoconfigure/DataSourceTransactionManagerAutoConfiguration.java)
- [Spring Boot 4.0.3 R2DBC transaction-manager conditions](https://github.com/spring-projects/spring-boot/blob/v4.0.3/module/spring-boot-r2dbc/src/main/java/org/springframework/boot/r2dbc/autoconfigure/R2dbcTransactionManagerAutoConfiguration.java)
- [Spring Boot 4.0.3 jOOQ and Spring transaction integration](https://github.com/spring-projects/spring-boot/blob/v4.0.3/module/spring-boot-jooq/src/main/java/org/springframework/boot/jooq/autoconfigure/JooqAutoConfiguration.java)
- [jOOQ Gradle plugin 10.1.1 documentation](https://github.com/etiennestuder/gradle-jooq-plugin/blob/v10.1.1/README.md)
- [jOOQ Gradle plugin 10.1.1 source-set/task wiring](https://github.com/etiennestuder/gradle-jooq-plugin/blob/v10.1.1/src/main/groovy/nu/studer/gradle/jooq/JooqPlugin.java)
- [Flyway Gradle plugin 11.16.0 metadata](https://repo.maven.apache.org/maven2/org/flywaydb/flyway-gradle-plugin/11.16.0/flyway-gradle-plugin-11.16.0.pom)
- [Flyway 11.16.0 Gradle task configuration source](https://github.com/flyway/flyway/blob/flyway-11.16.0/flyway-plugins/flyway-gradle-plugin/src/main/java/org/flywaydb/gradle/task/AbstractFlywayTask.java)
- [Reactor 3.8.3 guidance for wrapping blocking calls](https://github.com/reactor/reactor-core/blob/v3.8.3/docs/modules/ROOT/pages/faq.adoc)
