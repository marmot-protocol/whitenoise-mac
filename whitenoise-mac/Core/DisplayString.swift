import Foundation

// Canonical "usable display string" helpers.
//
// The rule is: trim surrounding whitespace/newlines, treat the empty result as
// absent, and pick the first candidate that survives. This used to be
// reimplemented in half a dozen slightly different shapes across the codebase
// (see marmot-protocol/whitenoise-mac#20); centralising it here keeps the
// definition of "what counts as a usable string" in one place.

extension String {
    /// The string trimmed of surrounding whitespace and newlines, or `nil`
    /// when the trimmed result is empty.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Returns the first candidate that is non-blank after trimming surrounding
/// whitespace and newlines, or `nil` when every candidate is absent or blank.
///
/// The returned value is always trimmed. Prefer this (and `String.nilIfBlank`)
/// over re-implementing trim/empty checks inline.
func firstNonBlank(_ values: [String?]) -> String? {
    for value in values {
        if let trimmed = value?.nilIfBlank { return trimmed }
    }
    return nil
}
