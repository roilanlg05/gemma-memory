import Foundation
import Hummingbird

// Top-level executable entry. (Using main.swift instead of @main since @main
// cannot coexist with a file named main.swift.)
let app = try await buildApp(config: AppConfig.fromEnvironment())
try await app.runService()
