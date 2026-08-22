// FlightRegistrationPlugin
//
// Attached to an app (or module) target, this plugin plans one build command
// that runs flight-registration-gen over the target's own sources plus the
// sources of every recursive source-module dependency that sits atop
// FlightCore, producing FlightRegistration.generated.swift with a single
// flightRegisterAll(_:).
//
// Why source scanning and not symbol graphs: symbol graphs are compiler
// outputs that do not exist when a build tool plugin's commands are planned,
// and the PackageManager symbol-graph service is only exposed to *command*
// plugins (SE-0332). SE-0325 gives build tool plugins the package graph —
// including dependency targets' source files — and the plugin sandbox allows
// reading them. Full findings: SPIKE-FINDINGS.md.
//
// Sandbox notes (spike question (b)): no network; writes restricted to this
// plugin's work directory (both the manifest and the generated file live
// there); reads of package/dependency sources are permitted.

import Foundation
import PackagePlugin

@main
struct FlightRegistrationPlugin: BuildToolPlugin {

    // Shape shared with Sources/flight-registration-gen.
    struct Manifest: Codable {
        struct Module: Codable {
            let name: String
            let files: [String]
        }
        let targetModuleName: String
        let modules: [Module]
        let output: String
        // Where flight.yaml lives (the package owning the target), for the
        // Flight Config §5 compile-time @ConfigValue key check.
        let packageDirectory: String?
    }

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sourceModule = target.sourceModule else { return [] }

        // The target itself, plus every recursive source-module dependency
        // that (transitively) depends on FlightCore. That predicate keeps
        // swift-log, swift-service-lifecycle, and friends out of the scan.
        var modulesInScope: [SourceModuleTarget] = [sourceModule]
        for dependency in target.recursiveTargetDependencies {
            guard let dependencyModule = dependency.sourceModule else { continue }
            guard dependencyModule.name != "FlightCore" else { continue }
            let dependsOnFlightCore = dependency.recursiveTargetDependencies
                .contains { $0.name == "FlightCore" }
            if dependsOnFlightCore {
                modulesInScope.append(dependencyModule)
            }
        }

        var inputFiles: [URL] = []
        var manifestModules: [Manifest.Module] = []
        for module in modulesInScope {
            let swiftFiles = module.sourceFiles(withSuffix: ".swift").map(\.url)
            guard !swiftFiles.isEmpty else { continue }
            inputFiles.append(contentsOf: swiftFiles)
            manifestModules.append(
                Manifest.Module(name: module.moduleName, files: swiftFiles.map(\.path))
            )
        }

        let workDirectory = context.pluginWorkDirectoryURL
        let outputURL = workDirectory.appendingPathComponent("FlightRegistration.generated.swift")
        let manifestURL = workDirectory.appendingPathComponent("flight-manifest.json")

        // flight.yaml participates in the build when present: it is an input
        // of the generator's @ConfigValue key check, so editing it must
        // re-plan the codegen command.
        let packageDirectory = context.package.directoryURL
        let baseConfigURL = packageDirectory.appendingPathComponent("flight.yaml")
        if FileManager.default.fileExists(atPath: baseConfigURL.path) {
            inputFiles.append(baseConfigURL)
        }

        let manifest = Manifest(
            targetModuleName: sourceModule.moduleName,
            modules: manifestModules,
            output: outputURL.path,
            packageDirectory: packageDirectory.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL)

        return [
            .buildCommand(
                displayName: "Flight registration codegen for \(target.name)",
                executable: try context.tool(named: "flight-registration-gen").url,
                arguments: [manifestURL.path],
                inputFiles: inputFiles + [manifestURL],
                outputFiles: [outputURL]
            )
        ]
    }
}
