package buildlogic

import org.gradle.api.GradleException

import java.sql.Connection

/** Inspect tables without modifying them or trying to repair migration history. */
final class RequiredSchemaTables {
    private RequiredSchemaTables() {}

    static void verify(Connection connection, String schema, List<String> requiredTables) {
        Set<String> missing = new TreeSet<>(requiredTables)
        connection.setReadOnly(true)
        connection.prepareStatement('SELECT table_name FROM information_schema.tables WHERE table_schema = ? AND table_type = \'BASE TABLE\'').withCloseable { statement ->
            statement.setString(1, schema)
            statement.executeQuery().withCloseable { tables ->
                while (tables.next()) {
                    missing.remove(tables.getString(1))
                }
            }
        }
        if (!missing.empty) {
            throw new GradleException("Required tables are missing in schema ${schema}: ${missing.join(', ')}. " +
                'Check database provisioning and migration history. Applied migrations will not be replayed and tables will not be recreated.')
        }
    }
}
