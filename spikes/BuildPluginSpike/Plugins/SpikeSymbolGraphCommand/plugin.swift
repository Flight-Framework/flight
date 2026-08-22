import Foundation
import PackagePlugin

// The contrast case for spike question (a): the PackageManager proxy — and
// with it getSymbolGraph — exists ONLY in command plugins (SE-0332). A build
// tool plugin's createBuildCommands has no `packageManager` to call; try
// adding one to SpikeBuildPlugin and watch it fail to compile. That compile
// failure plus this command succeeding is the whole finding.
@main
struct SpikeSymbolGraphCommand: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        for target in context.package.targets {
            guard target.sourceModule != nil else { continue }
            do {
                let result = try packageManager.getSymbolGraph(
                    for: target,
                    options: .init(minimumAccessLevel: .internal)
                )
                print("symbol graph for \(target.name): \(result.directoryPath)")
                let files = (try? FileManager.default.contentsOfDirectory(
                    atPath: result.directoryPath.string
                )) ?? []
                for file in files {
                    print("  \(file)")
                }
            } catch {
                print("symbol graph for \(target.name) FAILED: \(error)")
            }
        }
    }
}
