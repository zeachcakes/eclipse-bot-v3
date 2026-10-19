package buildlogic

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption

/** Filesystem boundary; fingerprints themselves remain pure and relocatable. */
final class SchemaFiles {
    private SchemaFiles() {}

    static Map<String, byte[]> read(File directory, String suffix) {
        Map<String, byte[]> files = new TreeMap<>()
        if (!directory.isDirectory()) {
            return files
        }
        Path root = directory.toPath()
        Files.walk(root).withCloseable { paths ->
            paths.filter { Files.isRegularFile(it) && it.fileName.toString().endsWith(suffix) }
                .forEach { path -> files[root.relativize(path).toString().replace('\\', '/')] = Files.readAllBytes(path) }
        }
        files
    }

    static void invalidate(File stateFile) {
        Files.deleteIfExists(stateFile.toPath())
    }

    static void record(File stateFile, Map configuration, File migrations, File output) {
        Map state = GeneratedSchemaState.create(configuration, read(migrations, '.sql'), read(output, '.java'))
        Path parent = stateFile.toPath().parent
        Files.createDirectories(parent)
        Path temporary = Files.createTempFile(parent, 'generation-state-', '.tmp')
        try {
            Files.writeString(temporary, GeneratedSchemaState.encode(state))
            // A failed move leaves the old marker invalid, never a partial success marker.
            Files.move(temporary, stateFile.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally {
            Files.deleteIfExists(temporary)
        }
    }
}
