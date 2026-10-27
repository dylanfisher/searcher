// Breaks the public-path-log rule of scripts/arch. Never compiled.
import os

func logMissing(_ url: URL, logger: Logger) {
    logger.error("no file at \(url.path, privacy: .public)")
}
