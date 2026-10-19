package buildlogic

import groovy.json.JsonOutput
import groovy.json.JsonLexer
import groovy.json.JsonToken

import static groovy.json.JsonTokenType.*

import java.nio.charset.StandardCharsets
import java.security.MessageDigest

/** Pure, deterministic representation of migration inputs and generated Java output. */
final class GeneratedSchemaState {
    static final int FORMAT_VERSION = 1
    private static final Set<String> STATE_FIELDS = ['formatVersion', 'inputFingerprint', 'files'] as Set
    private static final Set<String> SECRET_FIELDS = ['url', 'jdbcurl', 'user', 'jdbcuser', 'username', 'password', 'jdbcpassword'] as Set

    private GeneratedSchemaState() {}

    static String inputFingerprint(Map generationConfiguration, Map migrationFiles) {
        Map canonical = [
            configuration: canonicalValue(generationConfiguration),
            migrations: fileHashes(migrationFiles, '.sql')
        ]
        sha256(JsonOutput.toJson(canonical).getBytes(StandardCharsets.UTF_8))
    }

    static Map<String, String> manifest(Map generatedJavaFiles) {
        Map<String, String> files = fileHashes(generatedJavaFiles, '.java')
        if (files.isEmpty()) {
            throw new IllegalArgumentException('Generated Java output is empty or missing.')
        }
        files
    }

    static Map create(Map generationConfiguration, Map migrationFiles, Map generatedJavaFiles) {
        [formatVersion: FORMAT_VERSION,
            inputFingerprint: inputFingerprint(generationConfiguration, migrationFiles),
            files: manifest(generatedJavaFiles)]
    }

    static String encode(Map state) {
        JsonOutput.toJson(validatedState(state)) + '\n'
    }

    static Map decode(String encoded) {
        if (encoded == null || encoded.trim().isEmpty()) {
            throw new IllegalArgumentException('Generation state is missing or malformed.')
        }
        Map parsed
        try {
            JsonLexer lexer = new JsonLexer(new StringReader(encoded))
            if (requiredToken(lexer).type != OPEN_CURLY) {
                throw new IllegalArgumentException()
            }
            parsed = readObject(lexer, 1)
            if (lexer.hasNext()) {
                throw new IllegalArgumentException()
            }
        } catch (RuntimeException ignored) {
            // JSON parser diagnostics echo input text, so do not attach the exception.
            throw new IllegalArgumentException('Generation state is malformed.')
        }
        validatedState(parsed)
    }

    /** This format only needs objects, strings, and numbers; require complete, unambiguous JSON. */
    private static Map readObject(JsonLexer lexer, int depth) {
        if (depth > 2) {
            throw new IllegalArgumentException()
        }
        Map result = [:]
        JsonToken key = requiredToken(lexer)
        if (key.type == CLOSE_CURLY) {
            return result
        }
        while (true) {
            if (key.type != STRING || result.containsKey(key.value) || requiredToken(lexer).type != COLON) {
                throw new IllegalArgumentException()
            }
            JsonToken value = requiredToken(lexer)
            if (value.type == OPEN_CURLY) {
                result[key.value] = readObject(lexer, depth + 1)
            } else if (value.type == STRING) {
                result[key.value] = value.value
            } else if (value.type == NUMBER && value.text ==~ /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/) {
                result[key.value] = value.value
            } else {
                throw new IllegalArgumentException()
            }
            JsonToken separator = requiredToken(lexer)
            if (separator.type == CLOSE_CURLY) {
                return result
            }
            if (separator.type != COMMA) {
                throw new IllegalArgumentException()
            }
            key = requiredToken(lexer)
        }
    }

    private static JsonToken requiredToken(JsonLexer lexer) {
        if (!lexer.hasNext()) {
            throw new IllegalArgumentException()
        }
        lexer.next()
    }

    static void verify(Map state, Map generationConfiguration, Map migrationFiles, Map generatedJavaFiles) {
        Map validState = validatedState(state)
        if (validState.inputFingerprint != inputFingerprint(generationConfiguration, migrationFiles)) {
            throw new IllegalArgumentException('Generation inputs changed since the last successful preparation.')
        }
        if (validState.files != manifest(generatedJavaFiles)) {
            throw new IllegalArgumentException('Generated Java files changed since the last successful preparation.')
        }
    }

    private static Map validatedState(Map state) {
        if (state == null || state.keySet() != STATE_FIELDS) {
            throw new IllegalArgumentException('Generation state has missing or unexpected fields.')
        }
        Object version = state.formatVersion
        if (!(version instanceof Integer || version instanceof Long || version instanceof BigInteger) || version != FORMAT_VERSION) {
            throw new IllegalArgumentException('Generation state format is unsupported.')
        }
        if (!isHash(state.inputFingerprint) || !(state.files instanceof Map) || state.files.isEmpty()) {
            throw new IllegalArgumentException('Generation state fingerprint or output manifest is malformed.')
        }
        SortedMap<String, String> files = new TreeMap<>()
        state.files.each { path, contentHash ->
            String normalized = normalizedRelativePath(path)
            if (normalized != path || !normalized.endsWith('.java') || !isHash(contentHash)) {
                throw new IllegalArgumentException('Generation state output manifest is malformed.')
            }
            files[normalized] = contentHash
        }
        [formatVersion: FORMAT_VERSION, inputFingerprint: state.inputFingerprint, files: files]
    }

    private static boolean isHash(Object value) {
        value instanceof String && value ==~ /[a-f0-9]{64}/
    }

    private static Map<String, String> fileHashes(Map inputs, String suffix) {
        if (inputs == null) {
            throw new IllegalArgumentException('Generation file inputs are missing.')
        }
        SortedMap<String, String> hashes = new TreeMap<>()
        inputs.each { path, content ->
            String normalized = normalizedRelativePath(path)
            if (normalized.endsWith(suffix)) {
                if (hashes.containsKey(normalized)) {
                    throw new IllegalArgumentException('Generation file inputs contain duplicate normalized paths.')
                }
                if (!(content instanceof byte[])) {
                    throw new IllegalArgumentException('Generation file content must be supplied as bytes.')
                }
                hashes[normalized] = sha256((byte[]) content)
            }
        }
        hashes
    }

    private static String normalizedRelativePath(Object path) {
        if (!(path instanceof String) || path.isEmpty()) {
            throw new IllegalArgumentException('Generation file paths must be nonempty relative paths.')
        }
        String normalized = path.replace('\\', '/')
        if (normalized.startsWith('/') || normalized ==~ /^[A-Za-z]:.*$/ || normalized.indexOf('\u0000') >= 0) {
            throw new IllegalArgumentException('Generation file paths must be relative to their input directory.')
        }
        List<String> parts = normalized.split('/', -1).toList()
        if (parts.contains('..') || parts.contains('')) {
            throw new IllegalArgumentException('Generation file paths must not contain parent traversal or empty segments.')
        }
        parts.removeAll { it == '.' }
        if (parts.isEmpty()) {
            throw new IllegalArgumentException('Generation file paths must name files.')
        }
        parts.join('/')
    }

    private static Object canonicalValue(Object value) {
        if (value instanceof Map) {
            SortedMap<String, Object> result = new TreeMap<>()
            value.each { key, nested ->
                if (!(key instanceof String)) {
                    throw new IllegalArgumentException('Generation configuration keys must be strings.')
                }
                String normalizedKey = key.replaceAll(/[^A-Za-z]/, '').toLowerCase(Locale.ROOT)
                if (SECRET_FIELDS.contains(normalizedKey) || normalizedKey.endsWith('password')) {
                    throw new IllegalArgumentException('Connection settings must not be included in generation fingerprints.')
                }
                result[key] = canonicalValue(nested)
            }
            return result
        }
        if (value instanceof Set) {
            return value.collect { canonicalValue(it) }.sort { JsonOutput.toJson(it) }
        }
        if (value instanceof List) {
            return value.collect { canonicalValue(it) }
        }
        if (value == null || value instanceof String || value instanceof Boolean || value instanceof Number) {
            if ((value instanceof Double && !Double.isFinite(value)) || (value instanceof Float && !Float.isFinite(value))) {
                throw new IllegalArgumentException('Generation configuration must contain finite numbers.')
            }
            return value
        }
        throw new IllegalArgumentException('Generation configuration must contain only plain data.')
    }

    private static String sha256(byte[] content) {
        MessageDigest.getInstance('SHA-256').digest(content).encodeHex().toString()
    }
}
