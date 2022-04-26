import Darwin
import Foundation
import PathKit

@main
extension Generator {
    /// The entry point for the `generator` tool.
    static func main() {
        let logger = DefaultLogger()

        do {
            let arguments = try parseArguments(CommandLine.arguments)
            let project = try readProject(path: arguments.specPath)

            try Generator(logger: logger).generate(
                buildMode: arguments.buildMode,
                project: project,
                projectRootDirectory: arguments.projectRootDirectory,
                internalDirectoryName: "rules_xcodeproj",
                workspaceOutputPath: arguments.workspaceOutputPath,
                outputPath: arguments.outputPath
            )
        } catch {
            logger.logError(error.localizedDescription)
            exit(1)
        }
    }

    struct Arguments {
        let specPath: Path
        let outputPath: Path
        let workspaceOutputPath: Path
        let projectRootDirectory: Path
        let buildMode: BuildMode
    }

    static func parseArguments(_ arguments: [String]) throws -> Arguments {
        guard CommandLine.arguments.count == 5 else {
            throw UsageError(message: """
Usage: \(CommandLine.arguments[0]) <path/to/project.json> \
<path/to/output/project.xcodeproj> <workspace/relative/output/path> \
(xcode|bazel)
""")
        }

        let workspaceOutput = CommandLine.arguments[3]
        let workspaceOutputComponents = workspaceOutput.split(separator: "/")

        // Generate a relative path to the project root
        // e.g. "examples/ios/iOS App.xcodeproj" -> "../.."
        // e.g. "project.xcodeproj" -> ""
        let projectRoot = (0..<(workspaceOutputComponents.count-1))
            .map { _ in ".." }
            .joined(separator: "/")

        guard
            let buildMode = BuildMode(rawValue: CommandLine.arguments[4])
        else {
            throw UsageError(message: """
ERROR: build_mode wasn't one of the supported values: xcode, bazel
""")
        }

        return Arguments(
            specPath: Path(CommandLine.arguments[1]),
            outputPath: Path(CommandLine.arguments[2]),
            workspaceOutputPath: Path(workspaceOutput),
            projectRootDirectory: Path(projectRoot),
            buildMode: buildMode
        )
    }

    static func readProject(path: Path) throws -> Project {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode(Project.self, from: try path.read())
        } catch let error as DecodingError {
            // Return a more detailed error message
            throw PreconditionError(message: error.message)
        }
    }
}

private extension DecodingError {
    var message: String {
        guard let context = context else {
            return "An unknown decoding error occurred."
        }

        return """
At codingPath [\(context.codingPathString)]: \(context.debugDescription)
"""
    }

    private var context: Context? {
        switch self {
        case .typeMismatch(_, let context): return context
        case .valueNotFound(_, let context): return context
        case .keyNotFound(_, let context): return context
        case .dataCorrupted(let context): return context
        @unknown default: return nil
        }
    }
}

private extension DecodingError.Context {
    var codingPathString: String {
        return codingPath.map(\.stringValue).joined(separator: ", ")
    }
}
