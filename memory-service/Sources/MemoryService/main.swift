import Foundation
import Hummingbird

// Top-level executable entry. (Using main.swift instead of @main since @main
// cannot coexist with a file named main.swift.)
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    let config = try AppConfig.fromEnvironment()
    if arguments.isEmpty {
        let app = try await buildApp(config: config)
        try await app.runService()
    } else {
        try await EmbeddingIndexCommand.run(arguments, config: config)
    }
} catch {
    FileHandle.standardError.write(Data("memory-service: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
