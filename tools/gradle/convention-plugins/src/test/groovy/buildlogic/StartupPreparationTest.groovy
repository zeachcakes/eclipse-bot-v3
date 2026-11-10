package buildlogic

import org.gradle.testkit.runner.GradleRunner
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir

import java.nio.file.Files
import java.nio.file.Path

import static org.gradle.testkit.runner.TaskOutcome.FAILED
import static org.junit.jupiter.api.Assertions.assertEquals
import static org.junit.jupiter.api.Assertions.assertFalse
import static org.junit.jupiter.api.Assertions.assertNull
import static org.junit.jupiter.api.Assertions.assertTrue

class StartupPreparationTest {
    @TempDir
    Path projectDirectory

    @Test
    void startupPreparesOnlyItsSchemaBeforeVerificationAndCompilationEvenInParallel() {
        fixture()

        def result = runner(':server:bootRun', '--dry-run').build()
        List<String> orderedTasks = [
            ':schema:validateSchemaDatabase',
            ':schema:flywayMigrate',
            ':schema:verifySchemaTables',
            ':schema:generateJooq',
            ':schema:verifyGeneratedJooq',
            ':schema:compileJava',
            ':server:compileJava',
            ':server:bootRun',
        ]
        int previous = -1
        orderedTasks.each { String task ->
            int position = result.output.indexOf("${task} SKIPPED")
            assertTrue(position > previous, "Expected ${task} after the preceding stage:\n${result.output}")
            previous = position
        }
        assertFalse(result.output.contains(':unrelated:flywayMigrate'))
        assertFalse(result.output.contains(':unrelated:generateJooq'))
    }

    @Test
    void ordinaryBuildDoesNotScheduleMigrationsGenerationOrDatabaseChecks() {
        fixture()

        def result = runner(':server:build', '--dry-run').build()

        assertTrue(result.output.contains(':schema:verifyGeneratedJooq SKIPPED'))
        ['validateSchemaDatabase', 'flywayMigrate', 'verifySchemaTables', 'generateJooq', 'prepareSchema'].each {
            assertFalse(result.output.contains(":schema:${it} SKIPPED"), result.output)
        }
    }

    @Test
    void migrationFailurePreventsGenerationCompilationAndStartup() {
        fixture()
        simulatePreparationFailure('flywayMigrate')

        def result = runner(':server:bootRun').buildAndFail()

        assertEquals(FAILED, result.task(':schema:flywayMigrate').outcome)
        assertNull(result.task(':schema:generateJooq'))
        assertNull(result.task(':schema:compileJava'))
        assertNull(result.task(':server:bootRun'))
        assertTrue(result.output.contains('Simulated flywayMigrate failure'))
    }

    @Test
    void generationFailurePreventsVerificationCompilationAndStartup() {
        fixture()
        simulatePreparationFailure('generateJooq')

        def result = runner(':server:bootRun').buildAndFail()

        assertEquals(FAILED, result.task(':schema:generateJooq').outcome)
        assertNull(result.task(':schema:verifyGeneratedJooq'))
        assertNull(result.task(':schema:compileJava'))
        assertNull(result.task(':server:bootRun'))
        assertTrue(result.output.contains('Simulated generateJooq failure'), result.output)
    }

    private void fixture() {
        write('settings.gradle', '''
            pluginManagement { repositories { gradlePluginPortal(); mavenCentral() } }
            dependencyResolutionManagement { repositories { mavenCentral() } }
            rootProject.name = 'startup-fixture'
            include('schema', 'server', 'unrelated')
        ''')
        write('gradle.properties', 'baseJavaPackage=example\n')
        Files.createDirectories(projectDirectory.resolve('gradle'))
        Files.copy(Path.of(System.getProperty('test.versionCatalog')),
            projectDirectory.resolve('gradle/libs.versions.toml'))
        ['schema', 'unrelated'].each { String module ->
            write("${module}/build.gradle", """
                plugins { id 'service-schema-conventions' }
                schemaDatabase {
                    schemaName = '${module}'
                    connectionKey = '${module}'
                    generatedPackage = 'example.${module}.jooq'
                    requiredTables = ['item']
                }
            """)
        }
        write('server/build.gradle', '''
            plugins { id 'spring-boot-server-conventions' }
            dependencies { implementation project(':schema') }
            schemaPreparation { schemaProjectPath = ':schema' }
            springBoot { mainClass = 'example.Application' }
        ''')
        write('server/src/main/java/example/Application.java', '''
            package example;
            public class Application { public static void main(String[] args) {} }
        ''')
    }

    // Replace external work only in the fixture. The actual plugin dependency graph still
    // decides whether a failed preparation stage can reach verification or service startup.
    private void simulatePreparationFailure(String failedTask) {
        projectDirectory.resolve('schema/build.gradle').toFile().append("""
            // The synthetic action does not execute jOOQ, so it needs no downloaded generator classpath.
            afterEvaluate { configurations.jooqGenerator.dependencies.clear() }
            ['validateSchemaDatabase', 'flywayMigrate', 'verifySchemaTables', 'generateJooq'].each { taskName ->
                tasks.named(taskName) {
                    actions.clear()
                    doLast {
                        if (name == '${failedTask}') {
                            throw new GradleException('Simulated ${failedTask} failure')
                        }
                    }
                }
            }
        """)
    }

    private GradleRunner runner(String... arguments) {
        GradleRunner.create()
            .withProjectDir(projectDirectory.toFile())
            .withPluginClasspath()
            .withArguments(arguments.toList() + ['--parallel', '--no-configuration-cache', '--stacktrace'])
    }

    private void write(String relativePath, String text) {
        Path path = projectDirectory.resolve(relativePath)
        Files.createDirectories(path.parent)
        Files.writeString(path, text.stripIndent())
    }
}
