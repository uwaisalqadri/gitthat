// GitVocabulary.swift
// THE SINGLE PLACE where git's internal vocabulary is spelled out as plain string constants.
// Every other file in GITTHAT references these names instead of spelling the words inline.
// This file is listed in VocabularyLintTests.exemptFiles; no other file should need exemption
// for vocabulary reasons (Git.swift is exempt only for its "rebase", "squash", "fixup"
// git-subcommand argument strings, which are now below and referenced from Git.swift too).
//
// Rule: if you need one of git's reserved words anywhere in GITTHAT, add a constant here.

enum GitVocabulary {
    // The verb git uses internally for its interactive history-rewrite mechanism.
    static let rebaseVerb = "rebase"

    // Todo-file short-form verbs (git reads these directly; users never see them).
    static let todoSquash = "squash"
    static let todoFixup  = "fixup"

    // Environment variable names that contain git's vocabulary.
    static let envRebaseAutostash = "GIT_REBASE_AUTOSTASH"
}
