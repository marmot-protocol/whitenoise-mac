//
//  ProfilePrivacyDisclosure.swift
//  whitenoise-mac
//
//  Whether the profile privacy card shows its details, and which of its two controls
//  it offers.
//

import SwiftUI

/// The open/closed state of `ProfilePrivacyNote`, kept as a value so which control it offers
/// and what the chevron is labelled can be asserted without clicking anything — the test host builds no
/// accessibility tree to click through.
struct ProfilePrivacyDisclosure: Equatable {
    var isExpanded = false

    /// Opens the card; what `Learn more` does.
    mutating func expand() {
        isExpanded = true
    }

    /// Closes the card; what the chevron does.
    mutating func collapse() {
        isExpanded = false
    }

    /// The closed card has one way in, `Learn more`, and the open card one way out, the chevron:
    /// each shows only while it has somewhere to go.
    var showsLearnMore: Bool {
        !isExpanded
    }

    var showsChevron: Bool {
        isExpanded
    }

    /// Pointing up, at the summary the card closes back to.
    static let chevronSymbol = "chevron.up"

    /// The chevron's accessibility label and tooltip: a catalog key that already carries all nine
    /// translations (it was the shared-media grid's expander).
    static let collapseLabelKey = "View less"
}
