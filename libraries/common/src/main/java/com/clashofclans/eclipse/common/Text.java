package com.clashofclans.eclipse.common;

/** Shared validation for text values whose surrounding whitespace is insignificant. */
public final class Text {
    private Text() {}

    public static String requireNonBlank(String value) {
        String normalized = value.strip();
        if (normalized.isEmpty()) {
            throw new IllegalArgumentException("Text must not be blank");
        }
        return normalized;
    }
}
