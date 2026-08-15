import ArgumentParser

@main
struct GitThat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gitthat",
        abstract: "Rewrite history without remembering how.",
        subcommands: [
            CommitCommand.self,
            RewriteCommand.self,
            UndoCommand.self,
            CheckSubjectCommand.self,
            EditMessageCommand.self, // hidden; invoked by git as GIT_EDITOR
        ]
    )
}
