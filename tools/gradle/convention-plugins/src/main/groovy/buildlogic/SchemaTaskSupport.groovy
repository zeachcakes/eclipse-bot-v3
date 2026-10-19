package buildlogic

import org.gradle.api.GradleException
import org.gradle.api.Project

import java.util.regex.Pattern

/** Project-local adaptation of Flyway/jOOQ's eager APIs; never called for ordinary compilation. */
final class SchemaTaskSupport {
    private SchemaTaskSupport() {}

    static DatabaseConnectionSettings connection(Project project, DatabaseSchemaExtension schema) {
        if (project.gradle.startParameter.configurationCacheRequested) {
            throw new GradleException('Database preparation does not support the configuration cache. Run with --no-configuration-cache.')
        }
        String key = schema.connectionKey.get()
        String prefix = key.toUpperCase(Locale.ROOT)
        Map properties = [:]
        Map environment = [:]
        ['url', 'user', 'password'].each { suffix ->
            String propertyName = "${key}.db.${suffix}"
            String environmentName = "${prefix}_DB_${suffix.toUpperCase(Locale.ROOT)}"
            def property = project.providers.gradleProperty(propertyName)
            def variable = project.providers.environmentVariable(environmentName)
            if (property.present) {
                properties[propertyName] = property.get()
            }
            if (variable.present) {
                environment[environmentName] = variable.get()
            }
        }
        DatabaseConnectionSettings.resolve(project.path, key, properties, environment)
    }

    static void rejectFlywayOverrides(Project project, Object extension, Object task = null) {
        // Flyway 11.16 applies generic properties after the task fields. Reject the entire
        // override channel, including future settings, without displaying any supplied values.
        Set<String> names = new TreeSet<>()
        names.addAll(project.providers.environmentVariablesPrefixedBy('FLYWAY_').get().keySet())
        names.addAll(project.providers.systemPropertiesPrefixedBy('flyway.').get().keySet())
        names.addAll(project.providers.gradlePropertiesPrefixedBy('flyway.').get().keySet())
        names.addAll(project.properties.keySet().findAll { it.startsWith('flyway.') })
        if (extension.configFiles || (task != null && task.configFiles)) {
            names.add('flyway.configFiles')
        }
        // These are the implicit files loaded by the pinned Flyway Gradle plugin.
        if (new File(System.getProperty('user.home'), 'flyway.conf').isFile() ||
            new File('flyway.conf').isFile() || new File(project.rootDir, 'flyway.conf').isFile() ||
            new File(project.projectDir, 'flyway.conf').isFile()) {
            names.add('default flyway.conf')
        }
        if (!names.empty) {
            throw new GradleException("${project.path}: generic Flyway overrides are not allowed: ${names.join(', ')}. " +
                'Use the per-service database settings and schemaDatabase extension.')
        }
    }

    static void configureFlyway(Object target, String schema, File migrations) {
        target.driver = 'org.postgresql.Driver'
        target.locations = ["filesystem:${migrations.absolutePath}"] as String[]
        target.schemas = [schema] as String[]
        target.defaultSchema = schema
        target.table = 'flyway_schema_history'
        target.createSchemas = false
        target.validateOnMigrate = true
        target.validateMigrationNaming = true
        target.outOfOrder = false
        target.baselineOnMigrate = false
        target.cleanDisabled = true
        target.configurations = ['flywayMigration'] as String[]
    }

    static Map generationConfiguration(Object configuration, String jooqVersion, String flywayVersion) {
        def generator = configuration.generator
        def database = generator.database
        def flags = generator.generate
        [schema: database.inputSchema, generatedPackage: generator.target.packageName,
            jooqVersion: jooqVersion, flywayVersion: flywayVersion,
            generator: generator.name, database: database.name,
            includes: database.includes, excludes: database.excludes,
            records: flags.records, pojos: flags.pojos, immutablePojos: flags.immutablePojos,
            fluentSetters: flags.fluentSetters, indexes: flags.indexes, deprecated: flags.deprecated]
    }

    static String generatedSourcePattern(String directory) {
        directory.replace('\\', '/').split('/').collect { Pattern.quote(it) }.join('[/\\\\]') + '[/\\\\].*'
    }
}
