import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Hold-to-record shortcut
    static let holdToRecord = Self("holdToRecord", default: .init(.space, modifiers: [.control, .shift]))

    /// Toggle recording (for toggle mode)
    static let toggleRecording = Self("toggleRecording")

    /// Toggle voice monitoring on/off
    static let toggleVoiceMonitoring = Self("toggleVoiceMonitoring")

    /// Clinical Notes recording shortcut (#91). Unbound by default — the doctor
    /// picks a chord in Settings → Clinical Notes Mode after the toggle is on
    /// and Cliniko credentials are present. Default-unbound avoids surprise
    /// OS / browser / IDE conflicts on install.
    static let clinicalNotesRecord = Self("clinicalNotesRecord")
}
