// swift-tools-version: 6.1
// §10 spike: what can a build tool plugin actually see and do?
// Run ./run-spike.sh and diff reality against EXPECTED.md.
import PackageDescription

let package = Package(
    name: "BuildPluginSpike",
    platforms: [.macOS(.v13)],
    targets: [
        // Dependency target. Also uses the build plugin itself, so we can
        // probe whether App's plugin invocation sees ModuleA's generated
        // output (question (c): ordering / cross-target generated files).
        .target(name: "ModuleA", plugins: ["SpikeBuildPlugin"]),

        // App target: depends on ModuleA, uses the plugin. Its generated
        // file carries the probe report, which App prints at runtime.
        .executableTarget(
            name: "App",
            dependencies: ["ModuleA"],
            plugins: ["SpikeBuildPlugin"]
        ),

        // The probe the plugin's build command runs.
        .executableTarget(name: "spike-probe"),

        .plugin(
            name: "SpikeBuildPlugin",
            capability: .buildTool(),
            dependencies: ["spike-probe"]
        ),

        // Contrast case: command plugins DO get the PackageManager proxy,
        // including symbol graph extraction (SE-0332). Run via:
        //   swift package spike-symbolgraph
        .plugin(
            name: "SpikeSymbolGraphCommand",
            capability: .command(
                intent: .custom(
                    verb: "spike-symbolgraph",
                    description: "Demonstrates getSymbolGraph availability from a command plugin (and only there)."
                )
            )
        ),
    ]
)
