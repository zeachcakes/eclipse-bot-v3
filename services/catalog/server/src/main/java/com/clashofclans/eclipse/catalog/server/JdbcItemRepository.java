package com.clashofclans.eclipse.catalog.server;

import static com.clashofclans.eclipse.catalog.jooq.tables.Item.ITEM;

import java.util.Objects;
import java.util.function.IntSupplier;
import org.jooq.DSLContext;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.support.TransactionOperations;
import org.springframework.transaction.support.TransactionTemplate;
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Scheduler;

/** Runs the complete imperative JDBC transaction away from reactive request threads. */
@Repository
public class JdbcItemRepository {
    private final IntSupplier countQuery;
    private final TransactionOperations transactions;
    private final Scheduler scheduler;

    @Autowired
    public JdbcItemRepository(
            DSLContext dsl,
            @Qualifier("jdbcTransactionManager") JdbcTransactionManager transactionManager,
            @Qualifier("jdbcScheduler") Scheduler scheduler) {
        this(() -> dsl.fetchCount(ITEM), new TransactionTemplate(transactionManager), scheduler);
    }

    // Keep SQL and scheduling controllable in unit tests without a database or agent instrumentation.
    JdbcItemRepository(IntSupplier countQuery, TransactionOperations transactions, Scheduler scheduler) {
        this.countQuery = countQuery;
        this.transactions = transactions;
        this.scheduler = scheduler;
    }

    public Mono<Integer> countItems() {
        return Mono.fromCallable(() -> Objects.requireNonNull(
                        transactions.execute(status -> countQuery.getAsInt())))
                .subscribeOn(scheduler);
    }
}
