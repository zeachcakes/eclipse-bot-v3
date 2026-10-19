package com.clashofclans.eclipse.catalog.server;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayDeque;
import java.util.concurrent.atomic.AtomicInteger;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionStatus;
import org.springframework.transaction.support.SimpleTransactionStatus;
import org.springframework.transaction.support.TransactionTemplate;
import reactor.core.scheduler.Scheduler;
import reactor.core.scheduler.Schedulers;
import reactor.test.StepVerifier;

class JdbcItemRepositoryTest {
    @Test
    void defersTheWholeTransactionUntilScheduledSubscriptionAndReturnsTheResult() {
        var work = new ArrayDeque<Runnable>();
        Scheduler scheduler = Schedulers.fromExecutor(work::add);
        var transactions = new RecordingTransactionManager();
        var queries = new AtomicInteger();
        try {
            var repository = new JdbcItemRepository(() -> {
                assertThat(transactions.active).isTrue();
                queries.incrementAndGet();
                return 7;
            }, new TransactionTemplate(transactions), scheduler);

            var result = repository.countItems();
            assertThat(work).isEmpty();
            assertThat(queries).hasValue(0);
            assertThat(transactions.started).isZero();

            StepVerifier.create(result)
                    .then(() -> {
                        assertThat(queries).hasValue(0);
                        assertThat(transactions.started).isZero();
                        assertThat(work).hasSize(1);
                        work.removeFirst().run();
                    })
                    .expectNext(7)
                    .verifyComplete();

            assertThat(queries).hasValue(1);
            assertThat(transactions.started).isEqualTo(1);
            assertThat(transactions.committed).isEqualTo(1);
            assertThat(transactions.rolledBack).isZero();
            assertThat(transactions.active).isFalse();
        } finally {
            scheduler.dispose();
        }
    }

    @Test
    void propagatesTheOriginalFailureAndRollsBackInsideTheScheduledWork() {
        var work = new ArrayDeque<Runnable>();
        Scheduler scheduler = Schedulers.fromExecutor(work::add);
        var transactions = new RecordingTransactionManager();
        var failure = new IllegalStateException("query failed");
        try {
            var repository = new JdbcItemRepository(() -> {
                assertThat(transactions.active).isTrue();
                throw failure;
            }, new TransactionTemplate(transactions), scheduler);

            StepVerifier.create(repository.countItems())
                    .then(() -> {
                        assertThat(transactions.started).isZero();
                        work.removeFirst().run();
                    })
                    .expectErrorSatisfies(error -> assertThat(error).isSameAs(failure))
                    .verify();

            assertThat(transactions.started).isEqualTo(1);
            assertThat(transactions.committed).isZero();
            assertThat(transactions.rolledBack).isEqualTo(1);
            assertThat(transactions.active).isFalse();
        } finally {
            scheduler.dispose();
        }
    }

    private static final class RecordingTransactionManager implements PlatformTransactionManager {
        private boolean active;
        private int started;
        private int committed;
        private int rolledBack;

        @Override
        public TransactionStatus getTransaction(@Nullable TransactionDefinition definition) {
            active = true;
            started++;
            return new SimpleTransactionStatus();
        }

        @Override
        public void commit(TransactionStatus status) {
            assertThat(active).isTrue();
            committed++;
            active = false;
        }

        @Override
        public void rollback(TransactionStatus status) {
            assertThat(active).isTrue();
            rolledBack++;
            active = false;
        }
    }
}
