import SwiftUI

/// "Vault Warmth" design language (docs/UI.md §1).
/// Brass is reserved EXCLUSIVELY for trust moments — key taps, verified
/// badges, endorsements. Never use it for generic accents.
enum SealTheme {
    static let ink = Color(red: 0.047, green: 0.055, blue: 0.071)      // #0C0E12
    static let brass = Color(red: 0.851, green: 0.643, blue: 0.255)    // #D9A441
    static let silver = Color(white: 0.75)                              // passkey-tier ring

    /// Signature NFC success: triple pulse, "wax seal" weight (UI.md §1).
    static func sealHaptic() {
        let gen = UIImpactFeedbackGenerator(style: .rigid)
        gen.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { gen.impactOccurred() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { gen.impactOccurred(intensity: 1.0) }
    }
}
