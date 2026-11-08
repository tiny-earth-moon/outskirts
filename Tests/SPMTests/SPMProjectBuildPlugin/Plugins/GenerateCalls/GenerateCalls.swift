import PackagePlugin

@main
struct GenerateCalls: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target _: Target) throws -> [Command] {
        let output = context.pluginWorkDirectoryURL.appending(path: "GeneratedCalls.swift")
        return [
            .buildCommand(
                displayName: "Generate calls",
                executable: try context.tool(named: "GeneratorTool").url,
                arguments: [output.path],
                outputFiles: [output]
            ),
        ]
    }
}
