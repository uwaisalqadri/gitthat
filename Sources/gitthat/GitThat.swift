import ArgumentParser

@main
struct GitThat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gitthat",
        abstract: "Rewrite history without remembering how.",
        subcommands: [CommitCommand.self]
    )
}
