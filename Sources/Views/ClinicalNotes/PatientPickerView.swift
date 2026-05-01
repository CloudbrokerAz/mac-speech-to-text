import SwiftUI

/// Two-pane patient picker: live-search field on the left, appointment
/// list (post-selection) on the right.
///
/// Adheres to Warm Minimalism: frosted `.ultraThinMaterial` background,
/// amber accents from `Color+Theme.swift`, spring `(0.5, 0.7)` animations,
/// minimal chrome.
///
/// PHI: every visible row contains patient data. The view is purely
/// presentational — no logging, no `print`, no analytics. State lives in
/// `PatientPickerViewModel` which lives only in memory.
struct PatientPickerView: View {

    /// VM is held as a `@Bindable` so SwiftUI tracks `@Observable`
    /// property reads. Created by the host view (per the
    /// `RecordingViewModel` pattern in this codebase) — never instantiated
    /// inline with `@State` on the view, which can trigger the
    /// actor-existential crash documented in
    /// `.claude/references/concurrency.md` §1.
    @Bindable var viewModel: PatientPickerViewModel

    /// Mirror of the search field's editable text. Decoupled from the VM
    /// so SwiftUI's two-way binding can write here while the VM owns the
    /// debounce → search lifecycle through `updateQuery(_:)`.
    @State private var searchText: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            searchPane
                .frame(minWidth: 280)
            appointmentPane
                .frame(minWidth: 280)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: viewModel.searchPhase)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: viewModel.appointmentPhase)
    }

    // MARK: - Search pane

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Patient")
                .font(.headline)
                .foregroundStyle(.primary)

            TextField("Search by name", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: searchText) { _, newValue in
                    viewModel.updateQuery(newValue)
                }
                .accessibilityIdentifier("patient-picker-search-field")

            phaseContent
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.searchPhase {
        case .idle:
            placeholderRow("Type to search for a patient")
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching…").foregroundStyle(.secondary)
            }
        case .results(let patients):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(patients) { patient in
                        patientRow(patient)
                    }
                }
            }
        case .empty:
            placeholderRow("No matches")
        case .error(let error):
            errorRow(error)
        }
    }

    private func patientRow(_ patient: Patient) -> some View {
        Button {
            viewModel.selectPatient(patient)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(patient.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    if let dob = patient.dateOfBirth {
                        Label(dob, systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let email = patient.email {
                        Label(email, systemImage: "envelope")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(selected: viewModel.selectedPatient == patient))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("patient-row-\(patient.id)")
    }

    // MARK: - Appointment pane

    private var appointmentPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appointment")
                .font(.headline)
                .foregroundStyle(.primary)

            switch viewModel.appointmentPhase {
            case .idle:
                placeholderRow("Select a patient to see appointments")
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading appointments…").foregroundStyle(.secondary)
                }
            case .loaded(let appointments):
                appointmentList(appointments)
            case .error(let error):
                errorRow(error)
            }
        }
    }

    @ViewBuilder
    private func appointmentList(_ appointments: [Appointment]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                noAppointmentRow
                ForEach(appointments) { appointment in
                    appointmentRow(appointment)
                }
            }
        }
    }

    private var noAppointmentRow: some View {
        Button {
            viewModel.selectAppointment(id: nil)
        } label: {
            HStack {
                Image(systemName: "circle.dashed")
                Text("No appointment / general note")
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(selected: viewModel.selectedAppointmentID == nil
                                      && viewModel.selectedPatient != nil))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appointment-row-none")
    }

    private func appointmentRow(_ appointment: Appointment) -> some View {
        Button {
            viewModel.selectAppointment(id: appointment.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatAppointmentTime(appointment))
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(
                selected: viewModel.selectedAppointmentID == appointment.id
            ))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appointment-row-\(appointment.id)")
    }

    /// Static formatter — `DateFormatter` allocation is non-trivial and
    /// we'd otherwise rebuild one per row on every body re-evaluation.
    /// Both styles are locale-aware so this displays correctly in any
    /// of the AU/UK/US jurisdictions the picker ships into.
    private static let appointmentTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func formatAppointmentTime(_ appointment: Appointment) -> String {
        Self.appointmentTimeFormatter.string(from: appointment.startsAt)
    }

    // MARK: - Shared row pieces

    private func placeholderRow(_ text: String) -> some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(8)
    }

    private func errorRow(_ error: ClinikoError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.amberBright)
            Text(humanReadable(error))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
        .padding(8)
    }

    private func humanReadable(_ error: ClinikoError) -> String {
        switch error {
        case .unauthenticated:
            return "Cliniko didn't accept the API key. Open Settings to update it."
        case .forbidden:
            // `.forbidden` for a list endpoint is most often a key-scope
            // issue rather than a per-resource ACL — call that out so
            // users don't go in circles asking their Cliniko admin when
            // the fix is a regenerated key with the right scope.
            return "Your Cliniko API key is valid but lacks permission. "
                + "Check the key's scopes in Cliniko or contact your admin."
        case .notFound(let resource):
            return notFoundMessage(for: resource)
        case .validation:
            return "Cliniko rejected the request — please check the input."
        case .rateLimited:
            return "Cliniko is throttling requests. Try again shortly."
        case .server:
            return "Cliniko had a server error. Try again."
        case .transport:
            return "Couldn't reach Cliniko. Check your connection."
        case .cancelled:
            return "Request cancelled."
        case .decoding:
            // `.decoding` always indicates either a Cliniko-side schema
            // change or a bug on our side — the user can't fix it, but
            // they can report it so we know to ship a fix.
            return "Cliniko returned an unexpected response shape. "
                + "If this persists, please report it."
        case .nonHTTPResponse:
            return "Cliniko returned an unexpected response."
        }
    }

    /// Resource-specific copy for `.notFound` so the picker tells the user
    /// what's missing rather than a generic "no match" — more actionable
    /// across the patient / appointment panes. Extracted from
    /// `humanReadable(_:)` to keep its cyclomatic complexity in check.
    private func notFoundMessage(for resource: ClinikoError.Resource) -> String {
        switch resource {
        case .patient: return "No matching patient in Cliniko."
        case .appointment: return "No matching appointment in Cliniko."
        case .user: return "Cliniko couldn't find your user record."
        case .treatmentNote: return "Cliniko couldn't find that treatment note."
        }
    }

    private func rowBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(selected ? Color.amberLight.opacity(0.4) : Color.clear)
    }
}
