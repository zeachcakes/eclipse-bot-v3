package com.clashofclans.eclipse.catalog.server;

import static org.assertj.core.api.Assertions.assertThat;

import com.zaxxer.hikari.HikariDataSource;
import io.r2dbc.spi.Connection;
import io.r2dbc.spi.ConnectionFactory;
import io.r2dbc.spi.ConnectionFactoryMetadata;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import org.jooq.DSLContext;
import org.junit.jupiter.api.Test;
import org.reactivestreams.Publisher;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.autoconfigure.context.ConfigurationPropertiesAutoConfiguration;
import org.springframework.boot.env.YamlPropertySourceLoader;
import org.springframework.boot.jdbc.autoconfigure.DataSourceInitializationAutoConfiguration;
import org.springframework.boot.jooq.autoconfigure.JooqAutoConfiguration;
import org.springframework.boot.jooq.autoconfigure.SpringTransactionProvider;
import org.springframework.boot.r2dbc.autoconfigure.R2dbcAutoConfiguration;
import org.springframework.boot.r2dbc.autoconfigure.R2dbcInitializationAutoConfiguration;
import org.springframework.boot.r2dbc.autoconfigure.R2dbcProperties;
import org.springframework.boot.r2dbc.autoconfigure.R2dbcTransactionManagerAutoConfiguration;
import org.springframework.boot.sql.init.AbstractScriptDatabaseInitializer;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.r2dbc.connection.R2dbcTransactionManager;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.ReactiveTransactionManager;
import reactor.core.scheduler.Scheduler;

class JdbcConfigurationTest {
    @Test
    void bindsApplicationCredentialsAndSupportsBothTransactionModelsWithoutStartupSql() {
        var dataSources = new ArrayList<HikariDataSource>();
        var schedulers = new ArrayList<Scheduler>();
        new ApplicationContextRunner()
                .withConfiguration(AutoConfigurations.of(
                        ConfigurationPropertiesAutoConfiguration.class,
                        R2dbcAutoConfiguration.class,
                        R2dbcTransactionManagerAutoConfiguration.class,
                        JooqAutoConfiguration.class,
                        DataSourceInitializationAutoConfiguration.class,
                        R2dbcInitializationAutoConfiguration.class))
                .withUserConfiguration(JdbcConfiguration.class, JdbcItemRepository.class)
                .withBean(ConnectionFactory.class, NoDatabaseConnectionFactory::new)
                .withInitializer(context -> {
                    try {
                        var sources = new YamlPropertySourceLoader().load(
                                "application", new ClassPathResource("application.yaml"));
                        sources.forEach(context.getEnvironment().getPropertySources()::addLast);
                    } catch (IOException failure) {
                        throw new UncheckedIOException(failure);
                    }
                })
                .withPropertyValues(
                        "CATALOG_DB_URL=jdbc:postgresql://127.0.0.1:1/unused_test_database",
                        "CATALOG_R2DBC_URL=r2dbc:postgresql://127.0.0.1:1/unused_test_database",
                        "CATALOG_APP_DB_USER=catalog_application",
                        "CATALOG_APP_DB_PASSWORD=application-test-value",
                        "CATALOG_DB_USER=catalog_migration",
                        "CATALOG_DB_PASSWORD=migration-test-value")
                .run(context -> {
                    assertThat(context).hasNotFailed();
                    assertThat(context).hasSingleBean(HikariDataSource.class);
                    assertThat(context).hasSingleBean(PlatformTransactionManager.class);
                    assertThat(context).hasSingleBean(ReactiveTransactionManager.class);
                    assertThat(context).hasSingleBean(DSLContext.class);
                    assertThat(context).hasSingleBean(JdbcItemRepository.class);

                    var scheduler = context.getBean("jdbcScheduler", Scheduler.class);
                    schedulers.add(scheduler);
                    assertThat(scheduler.isDisposed()).isFalse();

                    var dataSource = context.getBean(HikariDataSource.class);
                    dataSources.add(dataSource);
                    assertThat(dataSource.getJdbcUrl())
                            .isEqualTo("jdbc:postgresql://127.0.0.1:1/unused_test_database");
                    assertThat(dataSource.getUsername()).isEqualTo("catalog_application");
                    assertThat(dataSource.getPassword()).isEqualTo("application-test-value");
                    assertThat(dataSource.getSchema()).isEqualTo("catalog");
                    // A no-argument HikariDataSource stays lazy until its first getConnection().
                    assertThat(dataSource.getHikariPoolMXBean()).isNull();

                    var jdbc = context.getBean("jdbcTransactionManager", JdbcTransactionManager.class);
                    assertThat(jdbc.getDataSource()).isSameAs(dataSource);
                    var reactive = context.getBean(
                            "connectionFactoryTransactionManager", R2dbcTransactionManager.class);
                    assertThat(reactive.getConnectionFactory())
                            .isSameAs(context.getBean(ConnectionFactory.class));
                    var provider = context.getBean(DSLContext.class).configuration().transactionProvider();
                    assertThat(provider).isInstanceOf(SpringTransactionProvider.class)
                            .hasFieldOrPropertyWithValue("transactionManager", jdbc);

                    var r2dbc = context.getBean(R2dbcProperties.class);
                    assertThat(r2dbc.getUsername()).isEqualTo("catalog_application");
                    assertThat(r2dbc.getPassword()).isEqualTo("application-test-value");
                    assertThat(r2dbc.getProperties()).containsEntry("schema", "catalog");
                    assertThat(context.getEnvironment().getProperty("spring.flyway.enabled"))
                            .isEqualTo("false");
                    assertThat(context.getEnvironment().getProperty("spring.sql.init.mode"))
                            .isEqualTo("never");
                    assertThat(context).doesNotHaveBean(AbstractScriptDatabaseInitializer.class);
                });
        assertThat(dataSources).hasSize(1);
        assertThat(dataSources.getFirst().isClosed()).isTrue();
        assertThat(schedulers).hasSize(1);
        assertThat(schedulers.getFirst().isDisposed()).isTrue();
    }

    private static final class NoDatabaseConnectionFactory implements ConnectionFactory {
        @Override
        public Publisher<? extends Connection> create() {
            throw new AssertionError("A unit test must not request a database connection");
        }

        @Override
        public ConnectionFactoryMetadata getMetadata() {
            return () -> "PostgreSQL";
        }
    }
}
