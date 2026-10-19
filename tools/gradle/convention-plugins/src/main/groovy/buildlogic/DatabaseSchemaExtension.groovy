package buildlogic

import org.gradle.api.provider.Property

import javax.lang.model.SourceVersion

/** Public per-schema configuration. Connection secrets deliberately do not live in this extension. */
abstract class DatabaseSchemaExtension {
    abstract Property<String> getSchemaName()

    abstract Property<String> getGeneratedPackage()

    abstract Property<String> getConnectionKey()

    static void validateNamespace(String modulePath, String schemaName, String connectionKey,
            String generatedPackage, String basePackage) {
        List<String> invalidSettings = []
        if (schemaName == null || !(schemaName ==~ /[a-z][a-z0-9_]*/)) {
            invalidSettings.add('schemaDatabase.schemaName')
        }
        if (connectionKey == null || !(connectionKey ==~ /[a-z][a-z0-9_]*/)) {
            invalidSettings.add('schemaDatabase.connectionKey')
        }
        boolean validBase = isJavaPackage(basePackage)
        if (!validBase) {
            invalidSettings.add('baseJavaPackage')
        }
        if (!isJavaPackage(generatedPackage) || (validBase && generatedPackage != basePackage && !generatedPackage.startsWith(basePackage + '.'))) {
            invalidSettings.add('schemaDatabase.generatedPackage')
        }
        if (!invalidSettings.isEmpty()) {
            throw new IllegalArgumentException("Missing or invalid schema configuration for ${modulePath}: ${invalidSettings.join(', ')}. " +
                'Schema names and connection keys must match [a-z][a-z0-9_]*; generatedPackage must be a Java package within baseJavaPackage.')
        }
    }

    private static boolean isJavaPackage(String value) {
        value != null && !value.isEmpty() && SourceVersion.isName(value, SourceVersion.RELEASE_25)
    }
}
