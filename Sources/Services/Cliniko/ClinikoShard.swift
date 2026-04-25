import Foundation

/// A Cliniko regional shard. The base URL of a tenant is
/// `https://api.{shard}.cliniko.com/v1/`; the shard is also encoded as a
/// suffix on the API key (e.g. `MS-XXXXX-au1`), but #7 takes the explicit
/// picker route per `.claude/references/cliniko-api.md` so the user is in
/// control. Auto-detection from the API-key suffix is a possible follow-up.
public enum ClinikoShard: String, CaseIterable, Codable, Sendable, Identifiable {
    case au1, au2, au3, au4
    case uk1, uk2
    case ca1
    case us1
    case eu1

    public var id: String { rawValue }

    /// Default for new installs. Most early users are in AU; the picker lets
    /// anyone change it before saving credentials.
    public static let `default`: ClinikoShard = .au1

    /// Hostname for the shard's Cliniko API endpoint. Composed only from the
    /// enum's lowercase ASCII raw value, so it is always a valid URL host.
    public var apiHost: String {
        "api.\(rawValue).cliniko.com"
    }

    /// User-facing label shown in the picker. Pairs the region name with the
    /// raw shard identifier so an experienced Cliniko admin can spot the right
    /// one quickly.
    public var displayName: String {
        switch self {
        case .au1: return "Australia 1 (au1)"
        case .au2: return "Australia 2 (au2)"
        case .au3: return "Australia 3 (au3)"
        case .au4: return "Australia 4 (au4)"
        case .uk1: return "United Kingdom 1 (uk1)"
        case .uk2: return "United Kingdom 2 (uk2)"
        case .ca1: return "Canada 1 (ca1)"
        case .us1: return "United States 1 (us1)"
        case .eu1: return "Europe 1 (eu1)"
        }
    }
}
