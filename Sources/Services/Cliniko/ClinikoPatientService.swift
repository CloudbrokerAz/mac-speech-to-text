import Foundation

/// Actor-constrained protocol for the patient picker's search dependency.
///
/// The picker view-model holds `any ClinikoPatientSearching` so unit tests
/// can substitute an in-test actor without spinning up a real HTTP stack.
/// Per `.claude/references/concurrency.md`, mockable services in this
/// project use actor-constrained protocols (actors cannot be subclassed,
/// so a `class`-style protocol won't do).
public protocol ClinikoPatientSearching: Actor {
    /// Issue a debounced patient search. The caller is responsible for
    /// debouncing (the VM does this with `Task.sleep`); this protocol stays
    /// thin so the picker can express "I want results for *this* query" and
    /// the service layer doesn't need its own timer.
    ///
    /// - Throws: `ClinikoError`. `.cancelled` for user-cancelled requests
    ///   (so the picker can swallow them silently); `.unauthenticated` to
    ///   route the user to settings; `.transport` for connectivity.
    /// - Returns: zero or more `Patient` records, in Cliniko's response
    ///   order (Cliniko sorts by relevance / recency — the picker does not
    ///   re-sort).
    func searchPatients(query: String) async throws -> [Patient]
}

/// Default `ClinikoPatientSearching` implementation: a thin wrapper around
/// `ClinikoClient.send(.patientSearch(query:))`.
///
/// PHI: this actor never logs the query, never logs the response, and never
/// stores anything across calls — every `searchPatients` is a pure function
/// of its arguments. Logging belongs to `ClinikoClient`, which redacts the
/// URL bound IDs and the response body per
/// `.claude/references/cliniko-api.md`.
public actor ClinikoPatientService: ClinikoPatientSearching {
    private let client: ClinikoClient

    public init(client: ClinikoClient) {
        self.client = client
    }

    public func searchPatients(query: String) async throws -> [Patient] {
        // Guard against empty / whitespace-only queries: without this, a
        // bare `GET /v1/patients` lists EVERY patient in the tenant —
        // unfiltered PHI exfiltration if a future caller bypasses the
        // picker VM's empty-check (today only `PatientPickerViewModel`
        // calls this, and it short-circuits empty input, but the
        // service-layer contract should be safe in isolation). Matches
        // the reference impl in `epc-letter-generation`.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let response: PatientSearchResponse = try await client.send(.patientSearch(query: trimmed))
        return response.patients
    }
}
