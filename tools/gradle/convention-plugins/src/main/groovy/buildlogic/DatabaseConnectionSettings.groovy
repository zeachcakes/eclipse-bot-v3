package buildlogic

import java.nio.charset.StandardCharsets

/** Resolves execution-time inputs without reading Gradle, the filesystem, or the process environment. */
final class DatabaseConnectionSettings {
    final String url
    final String user
    final String password

    private DatabaseConnectionSettings(String url, String user, String password) {
        this.url = url
        this.user = user
        this.password = password
    }

    static DatabaseConnectionSettings resolve(String modulePath, String connectionKey,
            Map properties, Map environment) {
        if (connectionKey == null || !(connectionKey ==~ /[a-z][a-z0-9_]*/)) {
            throw new IllegalArgumentException("Invalid schemaDatabase.connectionKey for ${modulePath}.")
        }
        String prefix = connectionKey.toUpperCase(Locale.ROOT)
        Map<String, String> values = [:]
        List<String> invalidSettings = []
        ['url', 'user', 'password'].each { String name ->
            String propertyName = "${connectionKey}.db.${name}"
            String environmentName = "${prefix}_DB_${name.toUpperCase(Locale.ROOT)}"
            Object supplied = properties.containsKey(propertyName) ? properties[propertyName] : environment[environmentName]
            String value = supplied instanceof CharSequence ? supplied.toString() : null
            boolean invalid = value == null || (name == 'password' ? value.isEmpty() : value.trim().isEmpty())
            if (!invalid && name == 'url') {
                invalid = !isPostgresqlUrlWithoutCredentials(value)
            }
            if (invalid) {
                invalidSettings.add("${propertyName} / ${environmentName}".toString())
            } else {
                values[name] = value
            }
        }
        if (!invalidSettings.isEmpty()) {
            throw new IllegalArgumentException("Missing or invalid database settings for ${modulePath}: ${invalidSettings.join(', ')}. " +
                'Use a PostgreSQL JDBC URL with credentials supplied separately.')
        }
        new DatabaseConnectionSettings(values.url, values.user, values.password)
    }

    private static boolean isPostgresqlUrlWithoutCredentials(String url) {
        if (!url.startsWith('jdbc:postgresql:') || url.any { Character.isWhitespace((char) it) || Character.isISOControl((char) it) }) {
            return false
        }
        String target = url.substring('jdbc:postgresql:'.length())
        if (target.isEmpty() || target.startsWith('?') || target.contains('#')) {
            return false
        }
        try {
            if (target.startsWith('//')) {
                String authority = target.substring(2).split(/[\/?]/, 2)[0]
                if (authority.isEmpty() || URLDecoder.decode(authority, StandardCharsets.UTF_8).contains('@')) {
                    return false
                }
            }
            int queryStart = target.indexOf('?')
            if (queryStart >= 0) {
                String query = target.substring(queryStart + 1)
                for (String parameter : query.split(/[&;]/)) {
                    String name = URLDecoder.decode(parameter.split('=', 2)[0], StandardCharsets.UTF_8).toLowerCase(Locale.ROOT)
                    if (name in ['user', 'username', 'password', 'sslpassword']) {
                        return false
                    }
                }
            }
            return true
        } catch (IllegalArgumentException ignored) {
            // URLDecoder's exception can contain the supplied URL. Never expose it as a cause.
            return false
        }
    }

    @Override
    String toString() {
        'DatabaseConnectionSettings[redacted]'
    }
}
