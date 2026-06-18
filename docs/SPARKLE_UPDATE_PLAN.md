# Sparkle 2 update plan (ARC-14)

This document captures the intended software-update mechanism for the
DMG-distributed macOS build. **No Sparkle integration ships in Phase 2
Batch 8** — this is planning-only so distribution work can land in a
follow-up without re-litigating the approach.

## Problem

The app ships as a manually downloaded DMG. Security fixes and clinical
workflow improvements require every clinician to re-download and replace
the app bundle. Stale versions are a real risk for a PHI-adjacent tool.

## Chosen direction: Sparkle 2

| Requirement | Sparkle 2 approach |
|---|---|
| Privacy | Appcast fetch is the only new egress — a version XML hosted on first-party HTTPS (no analytics, no third-party CDN required) |
| Signing | EdDSA-signed updates (`SUPublicEDKey` in Info.plist + `sign_update` tool) |
| Distribution | Self-hosted `appcast.xml` on the same origin as the DMG (e.g. `https://releases.example.com/mac-speech-to-text/appcast.xml`) |
| Sandbox | Sparkle works with sandbox-off menu-bar apps; `SUEnableInstallerLauncherService` handles privileged replace when needed |
| Delta updates | Optional `.delta` packages between consecutive builds to shrink download size |

## Integration outline (future PR)

1. Add `Sparkle` SPM dependency (2.x) to the Xcode app target (not the
   SPM library target — Sparkle expects an `.app` bundle with
   `Info.plist` keys).
2. Wire `SPUStandardUpdaterController` in `AppDelegate` (check on launch +
   manual “Check for Updates…” in About).
3. Publish pipeline additions in `scripts/export-dmg.sh`:
   - Generate `appcast.xml` with `generate_appcast` or a small template.
   - Run `sign_update` on each `.dmg` / `.zip` artifact.
   - Upload DMG + appcast + signature sidecar to the release bucket.
4. CI: add a release job (tag-triggered) that builds signed `.app`, zips,
   signs with Sparkle, and publishes the appcast entry.
5. Document rollback: keep N−1 DMG + appcast entry until adoption metrics
   (manual support channel) confirm uptake.

## Out of scope for Sparkle v1

- Automatic background download while a clinical session is active — gate
  “Install and relaunch” behind user confirmation and an idle
  `SessionStore` check.
- Microsoft-style forced updates — practitioners may be mid-consultation;
  defer install prompts when `SessionStore.active != nil`.
- Sparkle channels (beta/stable) — single stable channel until a second
  track is requested.

## References

- [Sparkle 2 documentation](https://sparkle-project.org/documentation/)
- Repo finding: ARC-14 in `docs/repo-review/index.html`
- Current DMG export: `scripts/export-dmg.sh`
