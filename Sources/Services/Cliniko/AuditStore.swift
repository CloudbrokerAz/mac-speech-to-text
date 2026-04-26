import Foundation
import os.log

/// Metadata-only ledger of every successful Cliniko `treatment_note`
/// export.
///
/// **Issue #10.** Mirrors the audit-log pattern from
/// [`epc-letter-generation/Sources/Services/AuditStore.swift`](https://github.com/CloudbrokerAz/epc-letter-generation/blob/main/Sources/Services/AuditStore.swift),
/// adapted for our JSONL-append shape per `.claude/references/cliniko-api.md` §Audit.
///
/// ## PHI invariant
///
/// Every record carries **only** the fields enumerated on `AuditRecord`
/// (timestamp, opaque patient/appointment/note IDs, HTTP status, app
/// version). The struct deliberately has no `String`-typed field that
/// could carry a name, transcript, or note body — if a future caller
/// tries to add one, the type system stops them. The `AuditStoreTests`
/// PHI-leak test pins this by encoding a record built from synthetic
/// PHI-shaped inputs and asserting none of them appear in the JSONL
/// byte stream.
public protocol AuditStore: Sendable {
    /// Append `event` to the audit ledger. Implementations are expected
    /// to be atomic at the line level (a partial write must not produce
    /// a half-line that breaks the next decode).
    func record(_ event: AuditRecord) async throws

    /// Read every record back, in append order. Used by the "Audit log"
    /// settings surface (future) and by tests asserting the on-disk
    /// shape.
    func loadAll() async throws -> [AuditRecord]
}

/// One row of the `treatment_note` export audit ledger.
///
/// Shape pinned by `.claude/references/cliniko-api.md` §Audit. Field
/// names match the doc's example; deliberate snake_case via explicit
/// `CodingKeys` (not `convertToSnakeCase`) so the encoder swap can't
/// drift the on-disk shape.
///
/// ID fields are `OpaqueClinikoID` (issue #59) so the type system
/// refuses non-Cliniko-shaped strings at compile time. The on-disk
/// JSON shape is **unchanged** — `OpaqueClinikoID` encodes as a bare
/// string, so a row written before #59 (`"patient_id": "1001"`) and a
/// row written after look byte-identical.
public struct AuditRecord: Codable, Sendable, Equatable {
    /// When the export landed, in UTC. Encoded as ISO8601 (see
    /// `LocalAuditStore.encoder`).
    public let timestamp: Date

    /// Cliniko patient ID. The wire shape is `Int`; the UI layer holds
    /// it as `OpaqueClinikoID` (`ClinicalSession.selectedPatientID`),
    /// and the exporter type-tags the Int into `OpaqueClinikoID(_:)`
    /// at the audit-write boundary.
    public let patientID: OpaqueClinikoID

    /// Optional Cliniko appointment ID. Practitioners may export against
    /// the patient only, in which case this is `nil`.
    public let appointmentID: OpaqueClinikoID?

    /// Cliniko `treatment_note.id` from the 201 response body.
    public let noteID: OpaqueClinikoID

    /// HTTP status from Cliniko. The exporter only writes audit records
    /// on success, so this is always 2xx in practice — kept structural
    /// (a number, not a flag) so future "201 vs 200" disambiguation
    /// doesn't require a schema bump.
    public let clinikoStatus: Int

    /// Marketing version string from `Bundle.main.infoDictionary[
    /// "CFBundleShortVersionString"]` (e.g. `"0.3.0"`). Captured at the
    /// call site so the exporter can be exercised under a faked version
    /// in tests.
    public let appVersion: String

    public init(
        timestamp: Date,
        patientID: OpaqueClinikoID,
        appointmentID: OpaqueClinikoID?,
        noteID: OpaqueClinikoID,
        clinikoStatus: Int,
        appVersion: String
    ) {
        self.timestamp = timestamp
        self.patientID = patientID
        self.appointmentID = appointmentID
        self.noteID = noteID
        self.clinikoStatus = clinikoStatus
        self.appVersion = appVersion
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case patientID = "patient_id"
        case appointmentID = "appointment_id"
        case noteID = "note_id"
        case clinikoStatus = "cliniko_status"
        case appVersion = "app_version"
    }
}

/// Disk-backed `AuditStore`. Appends one JSON line per record to a file
/// in Application Support (`<bundle_id>/audit.jsonl`).
///
/// ## Concurrency
///
/// Actor-isolated. Each `record(_:)` call serialises the encoder write +
/// the file-handle append, so concurrent exporters can't interleave
/// half-lines. The handle is opened on demand per-call (rather than
/// retained across calls) to keep crash recovery simple — a process
/// crash mid-write loses at most the in-flight line.
///
/// ## Filesystem hardening
///
/// The audit file is created with POSIX `0o600` so other macOS users on
/// the same machine can't read it. We do **not** apply
/// `.completeFileProtection` (iOS-only) — macOS has no equivalent
/// per-file class, and Application Support is already user-scoped.
public actor LocalAuditStore: AuditStore {
    public enum Failure: Error, Equatable, Sendable {
        /// Application Support couldn't be located for this user. In
        /// practice unreachable on a healthy macOS install — surfaced so
        /// the exporter can decide whether to fail loud or fall back to
        /// in-memory auditing.
        case applicationSupportUnavailable
        /// Encode failed. Should be unreachable for `AuditRecord` (every
        /// field is a primitive); kept for completeness.
        case encodeFailed
        /// Append to disk failed (full disk, permissions, etc.).
        case writeFailed
        /// `Data(contentsOf: fileURL)` failed in `loadAll`. Distinct
        /// from `.writeFailed` so the future "Audit log" settings
        /// surface can route a read failure to a different message
        /// than an export's write failure.
        case readFailed
    }

    /// Resolve the default on-disk URL for the audit ledger.
    ///
    /// Layout: `~/Library/Application Support/<bundle-id>/audit.jsonl`.
    /// The bundle-id segment falls back to a fixed string when running
    /// outside an app bundle (e.g. `swift test`), so tests don't depend
    /// on the host runtime.
    public static func defaultURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) throws -> URL {
        let support: URL
        do {
            support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw Failure.applicationSupportUnavailable
        }
        let folder = support.appendingPathComponent(bundleIdentifier ?? "com.speechtotext.mac", isDirectory: true)
        return folder.appendingPathComponent("audit.jsonl", isDirectory: false)
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.speechtotext", category: "AuditStore")

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = LocalAuditStore.makeEncoder()
        self.decoder = LocalAuditStore.makeDecoder()
    }

    public func record(_ event: AuditRecord) async throws {
        let line: Data
        do {
            line = try encoder.encode(event) + Data([0x0A])  // trailing LF
        } catch {
            logger.error("AuditStore: encode failed type=AuditRecord")
            throw Failure.encodeFailed
        }
        do {
            try ensureFileExists()
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch let failure as Failure {
            throw failure
        } catch {
            // Path / errno is structural and non-PHI, but we keep the
            // log inert per `.claude/references/phi-handling.md` — the
            // file path may include the bundle-id which is fine, but
            // any future change to use a per-patient subdir would leak.
            logger.error("AuditStore: write failed")
            throw Failure.writeFailed
        }
    }

    /// Read every record back, in append order. Tolerates corrupt lines
    /// (a process crash mid-write produces a half-written tail line; a
    /// disk-corruption event could damage any line). Bad lines are
    /// skipped with a structural log entry — the audit ledger must
    /// remain readable, otherwise practitioners lose visibility into
    /// every export they made before the corruption. Lines the JSONL
    /// shape can't parse are not surfaced as structured diagnostics
    /// here — `lineIndex` would be a triage-time tool but the doc-rule
    /// is "never echo line bytes", so we keep just the count via the
    /// structural log.
    public func loadAll() async throws -> [AuditRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let raw: Data
        do {
            raw = try Data(contentsOf: fileURL)
        } catch {
            logger.error("AuditStore: read failed")
            throw Failure.readFailed
        }
        var records: [AuditRecord] = []
        var lineIndex = 0
        // Split on LF so an unterminated final line still parses;
        // skip empty trailing newline gracefully.
        for line in raw.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let record = try? decoder.decode(AuditRecord.self, from: Data(line)) {
                records.append(record)
            } else {
                // Non-PHI: lineIndex is an integer; the bytes themselves
                // are never logged because they may carry the
                // opaque-but-sensitive patient_id.
                logger.error("AuditStore: skipping corrupt line index=\(lineIndex, privacy: .public)")
            }
            lineIndex += 1
        }
        return records
    }

    /// Lazily create the file (and its parent dir) with `0o600`. Idempotent.
    private func ensureFileExists() throws {
        let folder = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            let created = fileManager.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            guard created else { throw Failure.writeFailed }
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // `.sortedKeys` makes each line byte-stable, which the
        // PHI-leak test relies on (it grep-searches the encoded bytes
        // for synthetic-PHI substrings and would false-negative if
        // ordering varied). No `.prettyPrinted` — JSONL lines are
        // single-line by definition.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Test fake that holds records in memory and surfaces them via
/// `loadAll()`. Suitable for the exporter unit tests so they don't have
/// to provision a temp directory.
public actor InMemoryAuditStore: AuditStore {
    private var records: [AuditRecord] = []
    private let recordHook: (@Sendable (AuditRecord) async throws -> Void)?

    public init(recordHook: (@Sendable (AuditRecord) async throws -> Void)? = nil) {
        self.recordHook = recordHook
    }

    public func record(_ event: AuditRecord) async throws {
        // Hook lets exporter tests simulate disk failures without
        // wiring up a `FailingAuditStore` per call site. Fires before
        // append so a thrown error leaves `records` empty (matching the
        // disk semantics of "the line wasn't durably written").
        if let recordHook {
            try await recordHook(event)
        }
        records.append(event)
    }

    public func loadAll() async throws -> [AuditRecord] {
        records
    }

    public func reset() {
        records.removeAll()
    }
}
