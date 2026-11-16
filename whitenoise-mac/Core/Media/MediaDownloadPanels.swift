import AppKit
import Foundation

/// The two questions a chat download can ask: which folder, and — for one file — what to call it
/// and where.
///
/// The app is sandboxed with only `files.user-selected.read-write`, so a place outside the
/// container is writable precisely because the user picked it in one of these panels: they are the
/// permission grant, not a formality. Injected so tests can answer them with a temporary directory
/// instead of showing a modal.
struct MediaDownloadPanels {
    /// A folder for one gesture's files, or the folder to remember, opened in `openIn` (the
    /// default folder). `nil` means cancelled.
    let chooseFolder: @MainActor (_ openIn: URL?) -> URL?
    /// Save As for a single file, offered under its suggested name in `openIn` (the default
    /// folder). `nil` means cancelled.
    let chooseFile: @MainActor (_ suggestedName: String, _ openIn: URL?) -> URL?

    static let system = MediaDownloadPanels(
        chooseFolder: { openIn in
            let panel = NSOpenPanel()
            panel.directoryURL = openIn
            panel.title = L10n.string("Choose where to save downloads")
            panel.prompt = L10n.string("Choose")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        },
        chooseFile: { suggestedName, openIn in
            let panel = NSSavePanel()
            panel.directoryURL = openIn
            panel.nameFieldStringValue = suggestedName
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    )
}
