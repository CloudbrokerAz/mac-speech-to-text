import Foundation
import os.log

/// Posts a `treatment_note` to Cliniko and records a metadata-only
/// audit entry on success.
///
/// **Issue #10.** This is the last Cliniko-side service in EPIC #1
/// before the ReviewScreen export-flow UI (#14). It owns the mapping
/// from `StructuredNotes` (+ practitioner-selected manipulations and
/// patient/appointment IDs) to the wire payload, the call into
/// `ClinikoClient`, parsing the 201 response, and the post-success
/// `AuditStore.record(_:)` write.
///
/// ## What this exporter does NOT own
///
/// - **Retries on 5xx / transport.** `ClinikoClient` already enforces
///   the no-auto-retry contract for `createTreatmentNote` per
///   `.claude/references/cliniko-api.md` §"Retry policy" (POST is
///   non-idempotent — retrying on transport failure carries
///   duplicate-write risk because we don't know whether the request
///   landed). User-confirmed retries belong to the export-flow UI
///   (#14), which catches `.server` / `.transport` and surfaces a
///   "submit failed, retry?" affordance.
/// - **Auth-revoked routing.** `.unauthenticated` is rethrown verbatim;
///   the UI layer (#14) is what routes the practitioner to the Cliniko
///   settings sheet to re-paste their key.
/// - **Session clearing.** The exporter does not call
///   `SessionStore.clear()` on success — the export-flow UI does that
///   so it can also dismiss its own modal.
///
/// ## PHI
///
/// `notes` (markdown body composed from `StructuredNotes`) is patient
/// data and is sent over TLS to Cliniko. The exporter never logs the
/// payload; `ClinikoClient` already redacts request/response bodies at
/// every privacy posture. The audit write afterward carries metadata
/// only — see `AuditRecord`.
actor TreatmentNoteExporter {
    enum Failure: Error, Sendable, Equatable {
        /// Cliniko returned a successful (2xx) status but the response
        /// body could not be decoded into `TreatmentNoteCreated`. The
        /// note **may** have been created on Cliniko's side — we just
        /// can't confirm its `id`. Surfaced separately from the wrapped
        /// `ClinikoError.decoding` so the UI can warn "the note may have
        /// landed; check Cliniko before re-submitting" rather than
        /// offering a one-tap retry.
        case responseUndecodable
        /// `JSONEncoder.encode(TreatmentNotePayload.self)` failed.
        /// Should be unreachable for a struct of three primitive fields,
        /// but surfaced so the UI distinguishes "client-side encode
        /// bug" from `ClinikoError.decoding` (which is the response-
        /// decode contract — see the `responseUndecodable` rationale).
        case requestEncodeFailed
    }

    /// Outcome of a successful POST. Carries enough for the export-flow
    /// UI (#14) to render success / partial-success states without
    /// having to know about the audit subsystem's internal failure
    /// shape.
    struct ExportOutcome: Sendable, Equatable {
        /// Cliniko's response with the created note's `id`.
        let created: TreatmentNoteCreated
        /// `true` when the audit ledger persisted the metadata row;
        /// `false` when the POST succeeded but `AuditStore.record(_:)`
        /// failed (full disk, permissions revoked, etc.). The UI must
        /// show success either way — re-submitting because of an audit
        /// failure would create a duplicate clinical record.
        let auditPersisted: Bool
        /// Manipulation IDs the practitioner had selected but that
        /// don't resolve into the current taxonomy (typically after a
        /// placeholder-to-real-taxonomy swap that removed an entry).
        /// Empty in the common case. Not in the wire body and not in
        /// the audit row — surfaced only for UI warnings.
        let droppedManipulationIDs: [String]
    }

    private let client: ClinikoClient
    private let auditStore: any AuditStore
    private let manipulations: ManipulationsRepository
    private let appVersion: String
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.speechtotext", category: "TreatmentNoteExporter")

    /// Marketing version for the active build, with a deterministic
    /// fallback when running outside an `.app` bundle (i.e. during
    /// `swift test`). Same `CFBundleShortVersionString` lookup the
    /// `ClinikoUserAgent` fallback path uses, kept in lockstep so the
    /// audit-ledger row's `app_version` matches what Cliniko sees in the
    /// `User-Agent` header for the unconfigured-email case.
    static var defaultAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    init(
        client: ClinikoClient,
        auditStore: any AuditStore,
        manipulations: ManipulationsRepository,
        appVersion: String = TreatmentNoteExporter.defaultAppVersion,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.auditStore = auditStore
        self.manipulations = manipulations
        self.appVersion = appVersion
        self.now = now
    }

    /// Compose the wire payload, POST it, and on a successful 2xx +
    /// decoded body record an `AuditRecord` (best-effort) and return an
    /// `ExportOutcome`.
    ///
    /// Error contract:
    /// - `ClinikoError.unauthenticated` / `.forbidden` / `.notFound` /
    ///   `.validation` / `.rateLimited` / `.server` / `.transport` /
    ///   `.cancelled` — rethrown verbatim from `ClinikoClient`. The
    ///   audit ledger is **not** written (per `cliniko-api.md` §Audit
    ///   "every successful export writes …").
    /// - `Failure.requestEncodeFailed` — encoder rejected the payload.
    ///   Unreachable in practice; kept as a separate case so the UI
    ///   surface distinguishes it from response-side `.decoding`.
    /// - `Failure.responseUndecodable` — Cliniko returned 2xx but the
    ///   body didn't decode into `TreatmentNoteCreated`. The note
    ///   **may** have been created server-side; the UI must surface
    ///   "verify in Cliniko before re-submitting" rather than auto-
    ///   retry. Ledger NOT written (we have no `note_id` to audit).
    ///
    /// On full success, the audit-write is best-effort: a thrown
    /// audit-failure is swallowed and surfaced via
    /// `ExportOutcome.auditPersisted = false`. Treating an audit
    /// failure as the export failing would tempt the practitioner to
    /// re-submit and double-write the clinical record.
    func export(
        notes: StructuredNotes,
        patientID: Int,
        appointmentID: Int? = nil
    ) async throws -> ExportOutcome {
        let composed = TreatmentNotePayload.composeNotesBody(
            notes: notes,
            manipulations: manipulations
        )
        let payload = TreatmentNotePayload(
            patientID: patientID,
            appointmentID: appointmentID,
            notes: composed.body
        )
        let data: Data
        do {
            data = try Self.encoder.encode(payload)
        } catch {
            // PHI: the type name is structural and non-PHI; the
            // underlying error message can echo CodingKey paths so we
            // never log it directly.
            logger.error("TreatmentNoteExporter: request encode failed type=TreatmentNotePayload")
            throw Failure.requestEncodeFailed
        }

        let created: TreatmentNoteCreated
        let httpStatus: Int
        do {
            (created, httpStatus) = try await client.sendWithStatus(.createTreatmentNote(body: data))
        } catch ClinikoError.decoding {
            // 2xx + undecodable body. The note may have landed on
            // Cliniko's side — we just lost track of its id. Surface
            // a typed signal so the UI doesn't auto-retry.
            logger.error("TreatmentNoteExporter: 2xx body undecodable type=TreatmentNoteCreated")
            throw Failure.responseUndecodable
        }

        // Cliniko POST `/treatment_notes` is documented as `201 Created`,
        // but the audit ledger records what *actually* came back so a
        // future endpoint variant returning a different 2xx (e.g. 200 or
        // a 202 from a queued model) doesn't make the row lie. Threaded
        // through `ClinikoClient.sendWithStatus` per issue #58.
        //
        // Type-tag the Int IDs into `OpaqueClinikoID` at this audit
        // boundary (#59). The wire-payload Ints flow into the
        // numerical `TreatmentNotePayload`; the audit row carries the
        // opaque-string form so the on-disk schema stays unchanged.
        let record = AuditRecord(
            timestamp: now(),
            patientID: OpaqueClinikoID(patientID),
            appointmentID: appointmentID.map(OpaqueClinikoID.init),
            noteID: OpaqueClinikoID(created.id),
            clinikoStatus: httpStatus,
            appVersion: appVersion
        )

        let auditPersisted: Bool
        do {
            try await auditStore.record(record)
            auditPersisted = true
        } catch {
            // The note IS in Cliniko. Do NOT throw — the practitioner
            // would re-submit and duplicate the clinical record. The
            // UI surfaces "exported successfully — audit log
            // unavailable" via `ExportOutcome.auditPersisted = false`.
            // PHI: `clinikoStatus` is a 2xx Int (observed, not
            // hardcoded — see #58); nothing about the failure carries
            // patient data.
            logger.error("TreatmentNoteExporter: audit-write failed status=\(record.clinikoStatus, privacy: .public)")
            auditPersisted = false
        }

        return ExportOutcome(
            created: created,
            auditPersisted: auditPersisted,
            droppedManipulationIDs: composed.droppedManipulationIDs
        )
    }

    /// Encoder shape pinned by the request fixture. `.sortedKeys` makes
    /// the wire body byte-stable for the round-trip golden test;
    /// `.withoutEscapingSlashes` keeps markdown line breaks in `notes`
    /// readable for any human eyeballing the on-wire body during
    /// triage. Cliniko does not require a specific key order.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
