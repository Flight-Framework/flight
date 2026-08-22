import Foundation
import PackagePlugin

@main
struct SpikeBuildPlugin: BuildToolPlugin {

    struct Payload: Codable {
        let targetName: String
        let ownSources: [String]
        let dependencySources: [String]
        let siblingGeneratedGuesses: [String]
        let outsideWriteProbe: String
        let outsideReadProbe: String
        let output: String
    }

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sourceModule = target.sourceModule else { return [] }

        let ownSources = sourceModule.sourceFiles(withSuffix: ".swift").map(\.url.path)

        // (a): enumerate dependency targets' sources via the SE-0325 package
        // graph — the exact access Flight's registration generator relies on.
        var dependencySources: [String] = []
        for dependency in target.recursiveTargetDependencies {
            guard let module = dependency.sourceModule else { continue }
            dependencySources.append(
                contentsOf: module.sourceFiles(withSuffix: ".swift").map(\.url.path)
            )
        }

        let workDirectory = context.pluginWorkDirectoryURL

        // (c): guess the sibling target's work directory by name substitution.
        // Deliberately a heuristic — if even a correct guess isn't readable or
        // populated at this target's command time, per-target generated-output
        // chaining is off the table, which is the question.
        let siblingName = target.name == "App" ? "ModuleA" : "App"
        let siblingGuess = workDirectory.path.replacingOccurrences(
            of: "/\(target.name)/",
            with: "/\(siblingName)/"
        ) + "/SpikeGenerated.swift"

        let payload = Payload(
            targetName: target.name,
            ownSources: ownSources,
            dependencySources: dependencySources,
            siblingGeneratedGuesses: [siblingGuess],
            outsideWriteProbe: context.package.directoryURL
                .appendingPathComponent("spike-escape-attempt.txt").path,
            outsideReadProbe: "/etc/hosts",
            output: workDirectory.appendingPathComponent("SpikeGenerated.swift").path
        )

        let payloadURL = workDirectory.appendingPathComponent("spike-payload.json")
        try JSONEncoder().encode(payload).write(to: payloadURL)

        return [
            .buildCommand(
                displayName: "spike-probe for \(target.name)",
                executable: try context.tool(named: "spike-probe").url,
                arguments: [payloadURL.path],
                inputFiles: (ownSources + dependencySources).map { URL(fileURLWithPath: $0) },
                outputFiles: [URL(fileURLWithPath: payload.output)]
            )
        ]
    }
}
