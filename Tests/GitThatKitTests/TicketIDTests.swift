import Testing
@testable import GitThatKit

@Test(arguments: [
    ("feature/PROJ-421-sso", "PROJ-421"),
    ("PROJ-421", "PROJ-421"),
    ("bugfix/AB-1", "AB-1"),
    ("feature/PROJ-421-and-PROJ-422", "PROJ-421"),   // first wins
    ("feature/X1Y2-99-thing", "X1Y2-99"),
])
func extractsTickets(branch: String, expected: String) {
    #expect(TicketID.extract(fromBranch: branch) == expected)
}

@Test(arguments: [
    "main",
    "feature/sso",
    "feature/add-123-things",       // lowercase prefix is not a ticket
    "release/1.2.3",
    "feature/A-1",                  // single letter prefix is too noisy
])
func findsNoTicket(branch: String) {
    #expect(TicketID.extract(fromBranch: branch) == nil)
}

@Test func handlesNoBranch() {
    #expect(TicketID.extract(fromBranch: nil) == nil)
}

@Test func detectsWhetherHistoryUsesTickets() {
    #expect(TicketID.appearsIn(subjects: ["PROJ-1 add a thing", "fix a thing"]))
    #expect(!TicketID.appearsIn(subjects: ["add a thing", "fix a thing"]))
}
