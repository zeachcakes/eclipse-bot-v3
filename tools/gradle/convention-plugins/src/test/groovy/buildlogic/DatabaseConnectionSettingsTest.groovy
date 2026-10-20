package buildlogic

import org.junit.jupiter.api.Test

import static org.junit.jupiter.api.Assertions.assertEquals
import static org.junit.jupiter.api.Assertions.assertFalse
import static org.junit.jupiter.api.Assertions.assertNull
import static org.junit.jupiter.api.Assertions.assertThrows
import static org.junit.jupiter.api.Assertions.assertTrue

class DatabaseConnectionSettingsTest {
    @Test
    void environmentOverridesLegacyPropertiesWithoutChangingPasswordContents() {
        Map<String, String> environment = validEnvironment()
        environment.CATALOG_DB_PASSWORD = '  environment-$ecret\t  '

        def settings = DatabaseConnectionSettings.resolve(':services:catalog:schema', 'catalog',
            legacyProperties(), environment)

        assertEquals(environment.CATALOG_DB_URL, settings.url)
        assertEquals(environment.CATALOG_DB_USER, settings.user)
        assertEquals(environment.CATALOG_DB_PASSWORD, settings.password)
    }

    @Test
    void presentEmptyOrNullEnvironmentSettingsNeverFallBackToLegacyProperties() {
        ['CATALOG_DB_URL', 'CATALOG_DB_USER', 'CATALOG_DB_PASSWORD'].each { String name ->
            ['', null].each { value ->
                Map<String, String> environment = validEnvironment()
                environment[name] = value

                def failure = assertThrows(IllegalArgumentException) {
                    DatabaseConnectionSettings.resolve(':services:catalog:schema', 'catalog',
                        legacyProperties(), environment)
                }

                assertTrue(failure.message.contains(name))
            }
        }
    }

    @Test
    void whitespaceEnvironmentUrlOrUserDoesNotFallBack() {
        ['CATALOG_DB_URL', 'CATALOG_DB_USER'].each { String name ->
            Map<String, String> environment = validEnvironment()
            environment[name] = ' \t '

            def failure = assertThrows(IllegalArgumentException) {
                DatabaseConnectionSettings.resolve(':services:catalog:schema', 'catalog',
                    legacyProperties(), environment)
            }

            assertTrue(failure.message.contains(name))
        }
    }

    @Test
    void legacyPropertiesRemainAFallbackForAbsentEnvironmentSettings() {
        Map<String, String> properties = legacyProperties()

        def settings = DatabaseConnectionSettings.resolve(':services:catalog:schema', 'catalog',
            properties, [:])

        assertEquals(properties['catalog.db.url'], settings.url)
        assertEquals(properties['catalog.db.user'], settings.user)
        assertEquals(properties['catalog.db.password'], settings.password)
    }

    @Test
    void fallbackIsResolvedPerSettingWhenOnlySomeEnvironmentKeysExist() {
        def settings = DatabaseConnectionSettings.resolve(':services:catalog:schema', 'catalog',
            legacyProperties(), [CATALOG_DB_USER: 'environment_migration'])

        assertEquals('jdbc:postgresql://legacy.invalid/legacy_db', settings.url)
        assertEquals('environment_migration', settings.user)
        assertEquals('legacy-secret', settings.password)
    }

    @Test
    void invalidEnvironmentUrlsAreRejectedWithoutExposingCredentialsOrParserCauses() {
        [
            'jdbc:postgresql://private-user:private-password@private-host/private-db',
            'jdbc:postgresql://private-host/private-db?%private-password=value',
        ].each { String url ->
            Map<String, String> environment = validEnvironment()
            environment.CATALOG_DB_URL = url

            def failure = assertThrows(IllegalArgumentException) {
                DatabaseConnectionSettings.resolve(':services:catalog:schema', 'catalog',
                    legacyProperties(), environment)
            }

            assertTrue(failure.message.contains('CATALOG_DB_URL'))
            environment.values().each { String value ->
                assertFalse(failure.message.contains(value))
            }
            assertFalse(failure.message.contains('private-password'))
            assertNull(failure.cause)
        }
    }

    @Test
    void resolvedSettingsHaveARedactedStringRepresentation() {
        def settings = DatabaseConnectionSettings.resolve(':services:catalog:schema', 'catalog',
            [:], validEnvironment())

        assertEquals('DatabaseConnectionSettings[redacted]', settings.toString())
    }

    private static Map<String, String> validEnvironment() {
        [
            CATALOG_DB_URL: 'jdbc:postgresql://environment.invalid/environment_db',
            CATALOG_DB_USER: 'environment_migration',
            CATALOG_DB_PASSWORD: 'environment-secret',
        ]
    }

    private static Map<String, String> legacyProperties() {
        [
            'catalog.db.url': 'jdbc:postgresql://legacy.invalid/legacy_db',
            'catalog.db.user': 'legacy_migration',
            'catalog.db.password': 'legacy-secret',
        ]
    }
}
