package buildlogic

import org.gradle.api.provider.Property

/** The schema module to prepare when this server is launched through Gradle. */
abstract class SchemaPreparationExtension {
    abstract Property<String> getSchemaProjectPath()
}
