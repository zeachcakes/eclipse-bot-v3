package com.clashofclans.eclipse.catalog.server;

import com.zaxxer.hikari.HikariDataSource;
import javax.sql.DataSource;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.support.JdbcTransactionManager;
import reactor.core.scheduler.Scheduler;
import reactor.core.scheduler.Schedulers;

@Configuration(proxyBeanMethods = false)
public class JdbcConfiguration {
    @Bean(destroyMethod = "close")
    @ConfigurationProperties("app.jdbc")
    public HikariDataSource jooqDataSource() {
        return new HikariDataSource();
    }

    @Bean
    public JdbcTransactionManager jdbcTransactionManager(DataSource dataSource) {
        return new JdbcTransactionManager(dataSource);
    }

    @Bean(destroyMethod = "dispose")
    public Scheduler jdbcScheduler() {
        return Schedulers.newBoundedElastic(10, 1_000, "catalog-jdbc");
    }
}
