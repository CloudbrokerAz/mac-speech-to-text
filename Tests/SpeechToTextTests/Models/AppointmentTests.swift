import Foundation
import Testing
@testable import SpeechToText

/// Type-level tests for `Appointment` and its wire-shape DTO
/// (`ClinikoAppointmentDTO`) — domain mapping, derived `isCancelled`,
/// nested-ref ID extraction, identity-based equality, and the
/// most-likely-this-recording heuristic. Service-level decode coverage
/// (HTTP stubs, full envelope, status filtering) lives in
/// `ClinikoAppointmentServiceTests`.
@Suite("Appointment", .tags(.fast))
struct AppointmentTests {

    // MARK: - Identity-based equality

    @Test("equality is identity-based (same id, different cancel state → equal)")
    func equality_identityBased() {
        let active = Appointment(
            id: "5001",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),
            endsAt: Date(timeIntervalSince1970: 1_700_001_800),
            isCancelled: false
        )
        let cancelled = Appointment(
            id: "5001",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),
            endsAt: Date(timeIntervalSince1970: 1_700_001_800),
            isCancelled: true
        )
        #expect(active == cancelled)

        var bag: Set<Appointment> = []
        bag.insert(active)
        bag.insert(cancelled)
        #expect(bag.count == 1, "Set<Appointment> dedupes on id")
    }

    @Test("different ids are not equal")
    func equality_differentIDs_notEqual() {
        let lhs = Appointment(id: "5001", startsAt: Date(timeIntervalSince1970: 0))
        let rhs = Appointment(id: "5002", startsAt: Date(timeIntervalSince1970: 0))
        #expect(lhs != rhs)
        #expect(lhs.hashValue != rhs.hashValue)
    }

    // MARK: - DTO → domain mapping

    @Test("DTO maps starts_at, ends_at, and the nested ref IDs into the domain model")
    func dto_toDomainModel_basics() throws {
        let dto = ClinikoAppointmentDTO(
            id: "5001",
            startsAt: "2026-04-25T09:00:00Z",
            endsAt: "2026-04-25T09:30:00Z",
            cancelledAt: nil,
            archivedAt: nil,
            didNotArrive: false,
            patient: linkRef("https://api.au1.cliniko.com/v1/patients/1001"),
            appointmentType: linkRef("https://api.au1.cliniko.com/v1/appointment_types/4321"),
            practitioner: linkRef("https://api.au1.cliniko.com/v1/practitioners/9001")
        )

        let domain = try dto.toDomainModel(parser: ClinikoDateParser())

        #expect(domain.id == "5001")
        #expect(domain.startsAt == ISO8601DateFormatter().date(from: "2026-04-25T09:00:00Z"))
        #expect(domain.endsAt == ISO8601DateFormatter().date(from: "2026-04-25T09:30:00Z"))
        #expect(domain.isCancelled == false)
        #expect(domain.appointmentTypeID == "4321")
        #expect(domain.practitionerID == "9001")
    }

    @Test("DTO derives isCancelled from any of cancelled_at, archived_at, did_not_arrive")
    func dto_derivesIsCancelled() throws {
        let parser = ClinikoDateParser()
        let cancelled = ClinikoAppointmentDTO(
            id: "1", startsAt: "2026-04-25T09:00:00Z", endsAt: nil,
            cancelledAt: "2026-04-24T12:00:00Z", archivedAt: nil, didNotArrive: false,
            patient: nil, appointmentType: nil, practitioner: nil
        )
        let archived = ClinikoAppointmentDTO(
            id: "2", startsAt: "2026-04-25T09:00:00Z", endsAt: nil,
            cancelledAt: nil, archivedAt: "2026-04-24T12:00:00Z", didNotArrive: false,
            patient: nil, appointmentType: nil, practitioner: nil
        )
        let dna = ClinikoAppointmentDTO(
            id: "3", startsAt: "2026-04-25T09:00:00Z", endsAt: nil,
            cancelledAt: nil, archivedAt: nil, didNotArrive: true,
            patient: nil, appointmentType: nil, practitioner: nil
        )
        let active = ClinikoAppointmentDTO(
            id: "4", startsAt: "2026-04-25T09:00:00Z", endsAt: nil,
            cancelledAt: nil, archivedAt: nil, didNotArrive: false,
            patient: nil, appointmentType: nil, practitioner: nil
        )
        let nilDNA = ClinikoAppointmentDTO(
            id: "5", startsAt: "2026-04-25T09:00:00Z", endsAt: nil,
            cancelledAt: nil, archivedAt: nil, didNotArrive: nil,
            patient: nil, appointmentType: nil, practitioner: nil
        )

        #expect(try cancelled.toDomainModel(parser: parser).isCancelled)
        #expect(try archived.toDomainModel(parser: parser).isCancelled)
        #expect(try dna.toDomainModel(parser: parser).isCancelled)
        #expect(try !active.toDomainModel(parser: parser).isCancelled)
        #expect(try !nilDNA.toDomainModel(parser: parser).isCancelled)
    }

    @Test("DTO endsAt parse failure degrades to nil rather than throwing")
    func dto_endsAt_failureDegradesToNil() throws {
        let dto = ClinikoAppointmentDTO(
            id: "5001",
            startsAt: "2026-04-25T09:00:00Z",
            endsAt: "this is not a date",
            cancelledAt: nil, archivedAt: nil, didNotArrive: false,
            patient: nil, appointmentType: nil, practitioner: nil
        )

        let domain = try dto.toDomainModel(parser: ClinikoDateParser())

        // startsAt must parse; endsAt failure degrades because Cliniko
        // has been observed emitting incomplete end times on edge
        // appointment-type configurations and the picker can render
        // without one.
        #expect(domain.endsAt == nil)
    }

    @Test("DTO startsAt parse failure throws ClinikoError.decoding")
    func dto_startsAt_failureThrows() {
        let dto = ClinikoAppointmentDTO(
            id: "5001",
            startsAt: "this is not a date",
            endsAt: nil,
            cancelledAt: nil, archivedAt: nil, didNotArrive: false,
            patient: nil, appointmentType: nil, practitioner: nil
        )

        do {
            _ = try dto.toDomainModel(parser: ClinikoDateParser())
            Issue.record("expected ClinikoError.decoding to throw")
        } catch ClinikoError.decoding(let typeName) {
            #expect(typeName == "Date")
        } catch {
            Issue.record("expected ClinikoError.decoding, got \(error)")
        }
    }

    @Test("LinkRef.trailingID extracts the last URL segment from links.self")
    func linkRef_trailingID() {
        let withID = ClinikoAppointmentDTO.LinkRef(
            links: .init(self: "https://api.au1.cliniko.com/v1/practitioners/9001")
        )
        let empty = ClinikoAppointmentDTO.LinkRef(links: .init(self: nil))
        let blank = ClinikoAppointmentDTO.LinkRef(links: .init(self: ""))
        let noLinks = ClinikoAppointmentDTO.LinkRef(links: nil)

        #expect(withID.trailingID == "9001")
        #expect(empty.trailingID == nil)
        #expect(blank.trailingID == nil)
        #expect(noLinks.trailingID == nil)
    }

    @Test("LinkRef.trailingID strips trailing slash, query string, and fragment")
    func linkRef_trailingID_handlesEdgeShapes() {
        // Trailing slash — `URL.pathComponents` filters empty
        // components so the real last segment is returned.
        let withTrailingSlash = ClinikoAppointmentDTO.LinkRef(
            links: .init(self: "https://api.au1.cliniko.com/v1/practitioners/9001/")
        )
        // Query string — `URL.pathComponents` only walks the path, so
        // the query never lands in the result.
        let withQuery = ClinikoAppointmentDTO.LinkRef(
            links: .init(self: "https://api.au1.cliniko.com/v1/practitioners/9001?include=archived")
        )
        // Fragment — same path-only walk.
        let withFragment = ClinikoAppointmentDTO.LinkRef(
            links: .init(self: "https://api.au1.cliniko.com/v1/practitioners/9001#anchor")
        )

        #expect(withTrailingSlash.trailingID == "9001")
        #expect(withQuery.trailingID == "9001")
        #expect(withFragment.trailingID == "9001")
    }

    // MARK: - Most-likely-this-recording helper

    @Test("mostLikelyMatch returns nil for empty input")
    func mostLikely_empty() {
        let recordingStart = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(Appointment.mostLikelyMatch(in: [], for: recordingStart) == nil)
    }

    @Test("mostLikelyMatch returns the slot containing recordingStart even when another is closer to its startsAt")
    func mostLikely_slotContainingWinsOutright() {
        // The doctor presses record DURING the 09:00–09:30 slot. Even
        // though the 11:00 slot is closer to recordingStart by absolute
        // distance from its startsAt (e.g. 11:00 - 09:15 = 1h45m vs
        // 09:00 - 09:15 = -15m), the slot-containing rule wins.
        let recordingStart = Date(timeIntervalSince1970: 1_700_000_000 + 900)  // 09:15
        let slot1 = Appointment(
            id: "1",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),               // 09:00
            endsAt: Date(timeIntervalSince1970: 1_700_000_000 + 1800)           // 09:30
        )
        let slot2 = Appointment(
            id: "2",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000 + 7200),        // 11:00
            endsAt: Date(timeIntervalSince1970: 1_700_000_000 + 9000)           // 11:30
        )
        let result = Appointment.mostLikelyMatch(
            in: [slot2, slot1],  // input order shouldn't matter
            for: recordingStart
        )
        #expect(result?.id == "1")
    }

    @Test("mostLikelyMatch falls back to nearest startsAt when no slot contains recordingStart")
    func mostLikely_nearestStartsAt() {
        // Doctor pressed record at 10:30. Candidate slots: 09:00–09:30
        // and 11:00–11:30. Nearest by startsAt is 11:00 (distance 30
        // minutes vs 90 minutes for 09:00).
        let recordingStart = Date(timeIntervalSince1970: 1_700_000_000 + 5400)  // 10:30
        let earlier = Appointment(
            id: "early",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000),
            endsAt: Date(timeIntervalSince1970: 1_700_000_000 + 1800)
        )
        let later = Appointment(
            id: "later",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000 + 7200),
            endsAt: Date(timeIntervalSince1970: 1_700_000_000 + 9000)
        )

        let result = Appointment.mostLikelyMatch(in: [earlier, later], for: recordingStart)
        #expect(result?.id == "later")
    }

    @Test("mostLikelyMatch returns nil when nearest is beyond the maxDistance threshold")
    func mostLikely_beyondMaxDistance_returnsNil() {
        // Doctor recorded today; the nearest appointment is 3 days away.
        // Pre-selecting it would be wrong more often than right —
        // the helper bails to nil so the picker leaves the choice to
        // the user. Default threshold is 24h.
        let recordingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysAway = Appointment(
            id: "far",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000 + 3 * 24 * 60 * 60),
            endsAt: Date(timeIntervalSince1970: 1_700_000_000 + 3 * 24 * 60 * 60 + 1800)
        )
        let result = Appointment.mostLikelyMatch(in: [threeDaysAway], for: recordingStart)
        #expect(result == nil)
    }

    @Test("mostLikelyMatch threshold can be overridden")
    func mostLikely_thresholdOverride() {
        // Same fixture as above — 3 days away — but override the
        // threshold to 1 week. The match becomes valid again.
        let recordingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let threeDaysAway = Appointment(
            id: "far",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000 + 3 * 24 * 60 * 60),
            endsAt: Date(timeIntervalSince1970: 1_700_000_000 + 3 * 24 * 60 * 60 + 1800)
        )
        let result = Appointment.mostLikelyMatch(
            in: [threeDaysAway],
            for: recordingStart,
            maxDistance: 7 * 24 * 60 * 60
        )
        #expect(result?.id == "far")
    }

    @Test("mostLikelyMatch tie-breaker prefers the past-leaning slot")
    func mostLikely_tiebreaker_prefersPastSlot() {
        // Two appointments equidistant from the recording start, one
        // 30 minutes before, one 30 minutes after. The doctor more
        // commonly records during/after a slot, so the past slot
        // wins the tie-break — making the helper independent of the
        // caller's input ordering.
        let recordingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let past = Appointment(
            id: "past",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000 - 1800),
            endsAt: Date(timeIntervalSince1970: 1_700_000_000 - 600)
        )
        let future = Appointment(
            id: "future",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000 + 1800),
            endsAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600)
        )
        // Try both input orderings; result must be stable.
        #expect(Appointment.mostLikelyMatch(in: [past, future], for: recordingStart)?.id == "past")
        #expect(Appointment.mostLikelyMatch(in: [future, past], for: recordingStart)?.id == "past")
    }

    @Test("mostLikelyMatch tolerates appointments without endsAt")
    func mostLikely_nilEndsAt_doesNotCrash() {
        // An appointment without endsAt cannot be a slot-containing
        // match (contiguity requires both bounds), so it falls
        // through to the nearest-startsAt comparator.
        let recordingStart = Date(timeIntervalSince1970: 1_700_000_000)
        let openEnded = Appointment(
            id: "open",
            startsAt: Date(timeIntervalSince1970: 1_700_000_000 + 3600),  // 1h after
            endsAt: nil
        )
        let result = Appointment.mostLikelyMatch(in: [openEnded], for: recordingStart)
        #expect(result?.id == "open")
    }

    // MARK: - Helpers

    private func linkRef(_ urlString: String) -> ClinikoAppointmentDTO.LinkRef {
        ClinikoAppointmentDTO.LinkRef(
            links: ClinikoAppointmentDTO.LinkRef.Links(self: urlString)
        )
    }
}

/// Standalone tests for `ClinikoDateParser` — pin every offset / fractional
/// shape Cliniko has been observed to emit. The parser is the load-bearing
/// piece of #129's date-handling story; if any of these regressed,
/// populated-response decode would silently fail again.
@Suite("ClinikoDateParser", .tags(.fast))
struct ClinikoDateParserTests {

    @Test("parses Z-form (UTC, no fractional seconds)")
    func parses_Z_plain() throws {
        let date = try ClinikoDateParser().parse("2026-04-25T09:00:00Z")
        #expect(date == ISO8601DateFormatter().date(from: "2026-04-25T09:00:00Z"))
    }

    @Test("parses Z-form with fractional seconds")
    func parses_Z_fractional() throws {
        let date = try ClinikoDateParser().parse("2026-04-25T09:00:00.123Z")
        let baseline = ISO8601DateFormatter().date(from: "2026-04-25T09:00:00Z")
            .map { $0.timeIntervalSinceReferenceDate + 0.123 }
        // `Date(timeIntervalSinceReferenceDate:) + addingTimeInterval`
        // and direct ISO8601 parsing return values that may differ by
        // sub-microsecond floating-point representation drift; use a
        // tolerance check rather than exact equality.
        let diff = (try #require(baseline)) - date.timeIntervalSinceReferenceDate
        #expect(abs(diff) < 0.001)
    }

    @Test("parses +10:00 form (RFC3339 with colon)")
    func parses_colonOffset_plain() throws {
        let date = try ClinikoDateParser().parse("2026-04-25T19:00:00+10:00")
        // 19:00 AEST (UTC+10) == 09:00 UTC.
        #expect(date == ISO8601DateFormatter().date(from: "2026-04-25T09:00:00Z"))
    }

    @Test("parses +10:00 form with fractional seconds")
    func parses_colonOffset_fractional() throws {
        let date = try ClinikoDateParser().parse("2026-04-25T19:00:00.123+10:00")
        let baseline = ISO8601DateFormatter().date(from: "2026-04-25T09:00:00Z")
            .map { $0.timeIntervalSinceReferenceDate + 0.123 }
        let diff = (try #require(baseline)) - date.timeIntervalSinceReferenceDate
        #expect(abs(diff) < 0.001)
    }

    @Test("parses +1000 form (ISO8601 basic offset, NO colon)")
    func parses_basicOffset_plain() throws {
        // `ISO8601DateFormatter` rejects this regardless of options; the
        // parser falls back to a `DateFormatter` with `ZZZZ` to handle
        // it. This is the case the previous global `.iso8601` decoder
        // strategy could not have parsed.
        let date = try ClinikoDateParser().parse("2026-04-25T19:00:00+1000")
        #expect(date == ISO8601DateFormatter().date(from: "2026-04-25T09:00:00Z"))
    }

    @Test("parses +1000 form with fractional seconds")
    func parses_basicOffset_fractional() throws {
        let date = try ClinikoDateParser().parse("2026-04-25T19:00:00.123+1000")
        let baseline = ISO8601DateFormatter().date(from: "2026-04-25T09:00:00Z")
            .map { $0.timeIntervalSinceReferenceDate + 0.123 }
        let diff = (try #require(baseline)) - date.timeIntervalSinceReferenceDate
        #expect(abs(diff) < 0.001)
    }

    @Test("throws ClinikoError.decoding on a malformed input")
    func throws_onMalformed() {
        do {
            _ = try ClinikoDateParser().parse("definitely not a date")
            Issue.record("expected throw")
        } catch ClinikoError.decoding(let typeName) {
            #expect(typeName == "Date")
        } catch {
            Issue.record("expected ClinikoError.decoding, got \(error)")
        }
    }

    @Test("error description never echoes the input string (PHI guard)")
    func errorDescription_doesNotEchoInput() {
        // The input here would be PHI-adjacent in a real call (an
        // appointment's start time + a known patient context). The
        // parser must throw a typed error whose `localizedDescription`
        // names the type only — never the value.
        let leakyInput = "2026-04-25T19:00:00.SHOULD-NOT-LEAK"
        do {
            _ = try ClinikoDateParser().parse(leakyInput)
            Issue.record("expected throw")
        } catch let error {
            let surface = error.localizedDescription
            #expect(!surface.contains("SHOULD-NOT-LEAK"),
                    "PHI sentinel leaked through error: \(surface)")
        }
    }
}
