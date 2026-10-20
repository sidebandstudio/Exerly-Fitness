import Foundation
import Testing
@testable import ExerlyCore

@Suite struct WeeklyReviewTests {
    func proposal(by author: AgentIdentity, _ title: String, status: ProposalStatus = .pending) -> Proposal {
        var proposal = Proposal(createdAt: Fixture.instant(), author: author, title: title, summary: "", changes: [],
                                evidence: [], confidence: .medium, falsifier: "\(title) is wrong")
        proposal.status = status
        return proposal
    }

    @Test func atMostThreeSuggestionsRankedWithEvidenceAndFalsifiers() throws {
        let signals = TrainingSignalsTests()
        let falling = signals.log("barbell-bench-press", weeks: 12, oneRepMax: { 110 - Double($0) * 10 / 35 })
        let agent = AgentIdentity(kind: .mcp, name: "Synthetic agent")
        let proposals = [
            proposal(by: EntryErrorDetector.author, "Did you mean 105 kg?"),
            proposal(by: agent, "Add a back-off set"),
            proposal(by: agent, "Already decided", status: .accepted),
        ]
        var checkIn = NutritionCheckIn.Review(outcome: .notEnoughData, date: signals.lastDay, completeDays: 2, weighInDays: 1)

        let review = WeeklyReview.make(training: falling, proposals: proposals, checkIn: checkIn, through: signals.lastDay)
        #expect(review.map(\.kind) == [.stall, .proposal, .proposal])
        #expect(review[0].title == "Barbell Bench Press has dropped")
        #expect(review[0].falsifier.hasPrefix("Your Barbell Bench Press estimate rises"))
        #expect(review[1].title == "Did you mean 105 kg?" && review[1].proposalID == proposals[0].id)
        #expect(review.allSatisfy { !$0.falsifier.isEmpty })

        // A goal that can't be kept outranks everything, and the review stays at three.
        checkIn.outcome = .cannotKeepGoal
        checkIn.problems = ["Sunday's budget, 1040 kcal, is under 1200 kcal"]
        let urgent = WeeklyReview.make(training: falling, proposals: proposals, checkIn: checkIn, through: signals.lastDay)
        #expect(urgent.count == WeeklyReview.maximumItems)
        #expect(urgent.first?.kind == .goal && urgent.first?.evidence.first?.claim.hasSuffix("under 1200 kcal") == true)
        // The same week gives the same IDs, so a dismissed item stays dismissed.
        #expect(urgent.map(\.id) == WeeklyReview.make(training: falling, proposals: proposals, checkIn: checkIn,
                                                      through: signals.lastDay).map(\.id))
    }

    /// PARITY B06: a deload is advice in the weekly review, with evidence and a
    /// falsifier but no proposal to accept, no diff and nothing to undo.
    @Test func aDeloadIsAdviceWithNothingToAccept() throws {
        let signals = TrainingSignalsTests()
        let review = WeeklyReview.make(training: signals.liftsFallingTogether(), proposals: [], checkIn: nil, through: signals.lastDay)
        let deload = try #require(review.first { $0.kind == .deload })
        #expect(!deload.evidence.isEmpty && !deload.falsifier.isEmpty)
        #expect(deload.proposalID == nil)
    }
}
