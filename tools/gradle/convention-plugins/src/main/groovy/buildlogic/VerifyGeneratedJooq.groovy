package buildlogic

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.MapProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.TaskAction
import org.gradle.work.DisableCachingByDefault

/** Always verifies existing output, including when Java compilation is up to date. */
@DisableCachingByDefault(because = 'Verification must inspect the current source tree on every invocation')
abstract class VerifyGeneratedJooq extends DefaultTask {
    @Internal abstract DirectoryProperty getGeneratedDirectory()
    @Internal abstract DirectoryProperty getMigrationDirectory()
    @Internal abstract RegularFileProperty getStateFile()
    @Internal abstract MapProperty<String, Object> getGenerationConfiguration()
    @Internal abstract Property<String> getSchemaProjectPath()
    @Internal abstract Property<String> getPreparationTaskPath()

    @TaskAction
    void verify() {
        try {
            Map state = GeneratedSchemaState.decode(stateFile.get().asFile.getText('UTF-8'))
            GeneratedSchemaState.verify(state, generationConfiguration.get(),
                SchemaFiles.read(migrationDirectory.get().asFile, '.sql'),
                SchemaFiles.read(generatedDirectory.get().asFile, '.java'))
        } catch (IOException | IllegalArgumentException failure) {
            throw new GradleException("Generated jOOQ sources for ${schemaProjectPath.get()} are missing or stale.\n" +
                "Configure this service's database settings and run:\n./gradlew ${preparationTaskPath.get()}")
        }
    }
}
