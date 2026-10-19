package com.clashofclans.eclipse.common;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatIllegalArgumentException;

import org.junit.jupiter.api.Test;

class TextTest {
    @Test
    void stripsSurroundingWhitespaceWithoutChangingTheContent() {
        assertThat(Text.requireNonBlank("  catalog item\n")).isEqualTo("catalog item");
    }

    @Test
    void rejectsBlankContent() {
        assertThatIllegalArgumentException()
                .isThrownBy(() -> Text.requireNonBlank(" \t\n"))
                .withMessage("Text must not be blank");
    }
}
