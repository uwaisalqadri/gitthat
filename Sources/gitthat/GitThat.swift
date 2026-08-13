import ArgumentParser

@main
struct GitThat: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gitthat",
        abstract: "Rewrite history without remembering how."
    )
}
