import AppKit
import Foundation
import Testing
@testable import SpeechToText

@MainActor
@Suite("ClinicalNotesPasteboard", .tags(.fast))
struct ClinicalNotesPasteboardTests {

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @Test("copySOAPNote marks concealed and transient types")
    func copySOAPNote_marksConcealedAndTransient() {
        let pasteboard = NSPasteboard(name: .init("ClinicalNotesPasteboardTests.concealed"))
        pasteboard.clearContents()

        ClinicalNotesPasteboard.copySOAPNote("Synthetic SOAP body for test", pasteboard: pasteboard)

        #expect(pasteboard.string(forType: .string) == "Synthetic SOAP body for test")
        #expect(pasteboard.data(forType: Self.concealedType) != nil)
        #expect(pasteboard.data(forType: Self.transientType) != nil)
    }

    @Test("copySOAPNote replaces prior pasteboard contents")
    func copySOAPNote_replacesPriorContents() {
        let pasteboard = NSPasteboard(name: .init("ClinicalNotesPasteboardTests.replace"))
        pasteboard.clearContents()
        pasteboard.setString("prior clipboard text", forType: .string)

        ClinicalNotesPasteboard.copySOAPNote("Replacement body", pasteboard: pasteboard)

        #expect(pasteboard.string(forType: .string) == "Replacement body")
    }
}
