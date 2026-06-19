import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Result of a text insertion attempt with fallback handling
enum TextInsertionResult: Sendable, Equatable {
    /// Text was successfully inserted via Accessibility APIs
    case insertedViaAccessibility
    /// Text was copied to clipboard only (not inserted)
    case copiedToClipboardOnly(reason: ClipboardFallbackReason)
    /// Accessibility permission is required but not granted
    case requiresAccessibilityPermission
}

/// Reason why text was copied to clipboard instead of inserted
enum ClipboardFallbackReason: Sendable, Equatable {
    /// User has not granted accessibility permission
    case accessibilityNotGranted
    /// Accessibility insertion failed with an error
    case insertionFailed(String)
    /// User prefers clipboard-only mode
    case userPreference
    /// Clipboard operation failed
    case clipboardFailed(String)
}

/// Service for inserting text using Accessibility APIs
@MainActor
class TextInsertionService {
    private let permissionService = PermissionService()
    private let settingsService: SettingsService

    init(settingsService: SettingsService = SettingsService()) {
        self.settingsService = settingsService
    }

    /// Insert text at the current cursor position
    /// Prefers Cmd+V paste first, falls back to accessibility-based insertion if needed
    func insertText(_ text: String) async throws {
        // Check accessibility permission (required for both CGEvent posting and AXUIElement)
        guard permissionService.checkAccessibilityPermission() else {
            throw PermissionError.accessibilityDenied
        }

        // Get the currently focused application
        guard NSWorkspace.shared.frontmostApplication != nil else {
            AppLogger.service.info("No frontmost application detected. Falling back to clipboard copy.")
            try await copyToClipboard(text)
            return
        }

        // Strategy: Try Cmd+V paste first (most reliable for Electron apps like VSCode)
        // Then fall back to accessibility-based insertion if Cmd+V fails
        do {
            try await simulatePaste(text)
            return
        } catch {
            AppLogger.service.debug("Cmd+V paste failed, trying accessibility fallback")
        }

        // Fallback: Try accessibility-based insertion via AXUIElement
        do {
            try await insertViaAccessibility(text)
        } catch {
            // Text is already in clipboard from simulatePaste attempt
            AppLogger.service.warning("Both insertion methods failed. Text is in clipboard.")
            throw error
        }
    }

    /// Insert text using accessibility APIs (AXUIElement)
    /// This is the fallback method when Cmd+V doesn't work
    private func insertViaAccessibility(_ text: String) async throws {
        let systemWideElement = AXUIElementCreateSystemWide()
        // Note: AXUIElementCreateSystemWide returns a +1 retained object per Core Foundation
        // "Create Rule". However, Swift automatically manages CFTypeRef bridged types,
        // so explicit CFRelease is not needed when assigned to a Swift variable.
        var focusedElement: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            throw TextInsertionError.noFocusedElement
        }

        // Validate the returned element is actually an AXUIElement before casting
        // This prevents potential issues if the accessibility API returns an unexpected type
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else {
            AppLogger.service.error("Focused element is not an AXUIElement (typeID: \(CFGetTypeID(element)))")
            throw TextInsertionError.noFocusedElement
        }

        // Safe cast after type validation - AXUIElement is a CFTypeRef typealias
        // swiftlint:disable:next force_cast
        let axElement = (element as! AXUIElement)

        // Try to set the value directly
        let setResult = AXUIElementSetAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )

        if setResult == .success {
            return
        }

        // Try setting selected text attribute as alternative
        let selectedTextResult = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        guard selectedTextResult == .success else {
            throw TextInsertionError.insertionFailed
        }
    }

    /// Copy text to clipboard (fallback method)
    private func copyToClipboard(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        guard success else {
            throw TextInsertionError.clipboardFailed
        }
    }

    /// Simulate paste operation (alternative insertion method)
    private func simulatePaste(_ text: String) async throws {
        // Copy to clipboard first
        try await copyToClipboard(text)

        // Small delay to ensure clipboard content is fully committed
        // This prevents race condition where keyboard events execute before pasteboard is ready
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Simulate Cmd+V
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw TextInsertionError.eventSourceCreationFailed
        }

        // Press Cmd
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true) else {
            throw TextInsertionError.keyEventCreationFailed("Command key down")
        }
        cmdDown.flags = .maskCommand

        // Press V
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else {
            throw TextInsertionError.keyEventCreationFailed("V key down")
        }
        vDown.flags = .maskCommand

        // Release V
        guard let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            throw TextInsertionError.keyEventCreationFailed("V key up")
        }
        vUp.flags = .maskCommand

        // Release Cmd
        guard let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            throw TextInsertionError.keyEventCreationFailed("Command key up")
        }

        // Post events with small delays for reliable processing across all applications
        cmdDown.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
        vDown.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
        vUp.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
        cmdUp.post(tap: .cghidEventTap)
    }

    /// Simulate pressing Enter key
    private func simulateEnter() async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw TextInsertionError.eventSourceCreationFailed
        }

        // Press Return (keycode 0x24 = 36)
        guard let returnDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) else {
            throw TextInsertionError.keyEventCreationFailed("Return key down")
        }

        guard let returnUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) else {
            throw TextInsertionError.keyEventCreationFailed("Return key up")
        }

        returnDown.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
        returnUp.post(tap: .cghidEventTap)
    }

    // MARK: - Fallback-Aware Insertion

    /// Insert text with fallback to clipboard if accessibility is not available
    ///
    /// This method provides a graceful degradation path:
    /// 1. If user prefers clipboard-only mode, copy to clipboard
    /// 2. If accessibility permission is not granted, copy to clipboard and indicate prompt needed
    /// 3. Try to insert via accessibility APIs
    /// 4. Fall back to clipboard if insertion fails
    ///
    /// - Parameter text: The text to insert
    /// - Returns: Result indicating how the text was handled
    func insertTextWithFallback(_ text: String) async -> TextInsertionResult {
        let settings = settingsService.load()

        // Check if user prefers clipboard-only mode
        if settings.general.clipboardOnlyMode {
            AppLogger.service.info("Using clipboard-only mode (user preference)")
            do {
                try await copyToClipboardPublic(text)
                return .copiedToClipboardOnly(reason: .userPreference)
            } catch {
                AppLogger.service.error("Clipboard copy failed in clipboard-only mode: \(error.localizedDescription, privacy: .public)")
                // Return clipboard failure reason so caller knows text was NOT copied
                return .copiedToClipboardOnly(reason: .clipboardFailed(error.localizedDescription))
            }
        }

        // Check accessibility permission
        let hasAccessibility = permissionService.checkAccessibilityPermission()

        guard hasAccessibility else {
            AppLogger.service.info("Accessibility not granted, falling back to clipboard")
            do {
                try await copyToClipboardPublic(text)
                // Check if user has dismissed the accessibility prompt before
                if settings.general.accessibilityPromptDismissed {
                    return .copiedToClipboardOnly(reason: .accessibilityNotGranted)
                } else {
                    return .requiresAccessibilityPermission
                }
            } catch {
                AppLogger.service.error("Clipboard copy failed: \(error.localizedDescription, privacy: .public)")
                // Return clipboard failure reason so caller knows text was NOT copied
                return .copiedToClipboardOnly(reason: .clipboardFailed(error.localizedDescription))
            }
        }

        // Try to insert via Cmd+V paste (more reliable than kAXSelectedTextAttribute)
        do {
            try await insertText(text)

            // Press Enter after paste if configured
            if settings.general.pasteBehavior == .pasteAndEnter {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms delay before Enter
                try await simulateEnter()
            }

            return .insertedViaAccessibility
        } catch let insertionError {
            AppLogger.service.warning("Accessibility insertion failed, falling back to clipboard: \(insertionError.localizedDescription, privacy: .public)")
            // Already copied to clipboard as part of simulatePaste fallback in insertText
            // But if that also failed, try explicit clipboard copy
            do {
                try await copyToClipboardPublic(text)
                return .copiedToClipboardOnly(reason: .insertionFailed(insertionError.localizedDescription))
            } catch let clipboardError {
                AppLogger.service.error("Final clipboard fallback failed: \(clipboardError.localizedDescription, privacy: .public)")
                // Return clipboard failure so caller knows text was NOT saved anywhere
                return .copiedToClipboardOnly(reason: .clipboardFailed(clipboardError.localizedDescription))
            }
        }
    }

    /// Public method to copy text to clipboard
    /// - Parameter text: The text to copy
    func copyToClipboardPublic(_ text: String) async throws {
        try await copyToClipboard(text)
    }
}

/// Text insertion errors
enum TextInsertionError: Error, LocalizedError, Equatable, Sendable {
    case noFocusedElement
    case insertionFailed
    case clipboardFailed
    case eventSourceCreationFailed
    case keyEventCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFocusedElement:
            return "No active text field found"
        case .insertionFailed:
            return "Failed to insert text via Accessibility API"
        case .clipboardFailed:
            return "Failed to copy text to clipboard"
        case .eventSourceCreationFailed:
            return "Failed to create CGEventSource for keyboard simulation"
        case .keyEventCreationFailed(let key):
            return "Failed to create keyboard event for \(key)"
        }
    }
}
