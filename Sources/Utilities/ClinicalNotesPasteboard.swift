// ClinicalNotesPasteboard.swift
// macOS Local Speech-to-Text Application
//
// PHI-aware pasteboard writes for the clinical-notes export fallback.
// See `.claude/references/phi-handling.md` — clipboard is a documented
// third place PHI may briefly exist, with concealment + auto-clear.

import AppKit
import Foundation

enum ClinicalNotesPasteboard {

    /// Seconds before an unchanged concealed SOAP pasteboard write clears.
    static let autoClearInterval: TimeInterval = 60

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Writes a SOAP note body to the general pasteboard with concealment
    /// markers and schedules an auto-clear when the pasteboard is unchanged.
    @MainActor
    static func copySOAPNote(_ text: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Presence of these types marks the item concealed/transient for
        // clipboard managers and Universal Clipboard history.
        pasteboard.setData(Data(), forType: concealedType)
        pasteboard.setData(Data(), forType: transientType)

        let snapshotChangeCount = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoClearInterval))
            guard pasteboard.changeCount == snapshotChangeCount else { return }
            pasteboard.clearContents()
        }
    }
}
