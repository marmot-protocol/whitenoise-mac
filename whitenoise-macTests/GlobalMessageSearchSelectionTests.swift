//
//  GlobalMessageSearchSelectionTests.swift
//  whitenoise-macTests
//
//  Arrow-key selection in the "Search all messages" results.
//

import Testing

@testable import whitenoise_mac

struct GlobalMessageSearchSelectionTests {
    private let ids = ["g:a", "g:b", "g:c"]

    @Test func downWithNothingSelectedSelectsTheFirstResult() {
        #expect(GlobalMessageSearchSelection.next(after: nil, in: ids) == "g:a")
    }

    @Test func downStepsToTheNextResultAndStopsAtTheLast() {
        #expect(GlobalMessageSearchSelection.next(after: "g:a", in: ids) == "g:b")
        #expect(GlobalMessageSearchSelection.next(after: "g:c", in: ids) == "g:c")
    }

    @Test func downOnAnEmptyListSelectsNothing() {
        #expect(GlobalMessageSearchSelection.next(after: nil, in: []) == nil)
    }

    @Test func downFromAResultNoLongerListedRestartsAtTheFirst() {
        #expect(GlobalMessageSearchSelection.next(after: "g:gone", in: ids) == "g:a")
    }

    @Test func upStepsToThePreviousResultAndStopsAtTheFirst() {
        #expect(GlobalMessageSearchSelection.previous(before: "g:c", in: ids) == "g:b")
        #expect(GlobalMessageSearchSelection.previous(before: "g:a", in: ids) == "g:a")
    }

    @Test func upWithNothingSelectedLeavesTheKeyToTheField() {
        #expect(GlobalMessageSearchSelection.previous(before: nil, in: ids) == nil)
        #expect(GlobalMessageSearchSelection.previous(before: "g:gone", in: ids) == nil)
    }

    @Test func refreshedResultsKeepASelectionThatIsStillListed() {
        #expect(GlobalMessageSearchSelection.reanchored("g:b", in: ["g:x", "g:b"]) == "g:b")
        #expect(GlobalMessageSearchSelection.reanchored("g:b", in: ["g:x"]) == nil)
        #expect(GlobalMessageSearchSelection.reanchored(nil, in: ids) == nil)
    }

    @Test func aRefreshKeepsTheSelectionUntilTheCompletedResultsArrive() {
        // A query edit empties the list and starts a new search before the results land.
        var selected = GlobalMessageSearchSelection.reanchored("g:b", in: [], whileSearching: true)
        #expect(selected == "g:b")
        selected = GlobalMessageSearchSelection.reanchored(selected, in: ["g:x", "g:b"], whileSearching: false)
        #expect(selected == "g:b")
    }

    @Test func completedResultsWithoutTheSelectionClearIt() {
        #expect(GlobalMessageSearchSelection.reanchored("g:b", in: [], whileSearching: false) == nil)
    }
}
