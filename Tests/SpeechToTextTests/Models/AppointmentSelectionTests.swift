import Foundation
import Testing
@testable import SpeechToText

/// Pure-logic tests for `AppointmentSelection` (#14). The enum
/// resolves the type-design follow-up flagged on #9's review:
/// `Int?` overloaded "no choice yet" with "explicit no
/// appointment". The export-flow VM gates `Confirm` on
/// `isResolved` so a `.unset` value cannot ship a note.
@Suite("AppointmentSelection", .tags(.fast))
struct AppointmentSelectionTests {

    // MARK: - isResolved

    @Test("`.unset` is not resolved")
    func unsetIsNotResolved() {
        #expect(AppointmentSelection.unset.isResolved == false)
    }

    @Test("`.general` is resolved")
    func generalIsResolved() {
        #expect(AppointmentSelection.general.isResolved == true)
    }

    @Test("`.appointment(...)` is resolved")
    func appointmentIsResolved() {
        let id = OpaqueClinikoID(5001)
        #expect(AppointmentSelection.appointment(id).isResolved == true)
    }

    // MARK: - wireAppointmentID

    @Test("`.unset` produces nil on the wire (callers MUST gate on isResolved)")
    func unset_wireIDIsNil() {
        // Important: this is the same shape as `.general`. The
        // type-design rationale (and the doc-comment on
        // `wireAppointmentID`) is that `.unset` callers must check
        // `isResolved` first — reading `wireAppointmentID` from
        // `.unset` and shipping a note silently mis-attributes it
        // as a general note.
        #expect(AppointmentSelection.unset.wireAppointmentID == nil)
    }

    @Test("`.general` produces nil on the wire — Cliniko accepts appointment_id: null")
    func general_wireIDIsNil() {
        #expect(AppointmentSelection.general.wireAppointmentID == nil)
    }

    @Test("`.appointment(...)` produces the integer form for numeric Cliniko IDs")
    func appointment_wireIDIsNumeric() {
        let id = OpaqueClinikoID(5001)
        #expect(AppointmentSelection.appointment(id).wireAppointmentID == 5001)
    }

    @Test("`.appointment(...)` with a non-numeric raw value produces nil")
    func appointment_nonNumericRawValue_wireIDIsNil() {
        // Defensive — production callsites construct via
        // OpaqueClinikoID(_:Int), but a tampered Codable round-trip
        // could land here. The export-flow VM guards on this
        // separately.
        let id = OpaqueClinikoID(rawValue: "not-numeric")
        #expect(AppointmentSelection.appointment(id).wireAppointmentID == nil)
    }

    // MARK: - Equatable

    @Test("Equatable distinguishes the three cases")
    func equatable_distinguishesCases() {
        #expect(AppointmentSelection.unset != .general)
        #expect(AppointmentSelection.general != .appointment(OpaqueClinikoID(1)))
        #expect(AppointmentSelection.appointment(OpaqueClinikoID(1)) != .appointment(OpaqueClinikoID(2)))
        #expect(AppointmentSelection.appointment(OpaqueClinikoID(1)) == .appointment(OpaqueClinikoID(1)))
    }
}
