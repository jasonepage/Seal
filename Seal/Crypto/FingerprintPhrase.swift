import Foundation
import CryptoKit

/// Human-checkable key fingerprints (UI.md §1): an emoji + three words derived
/// from a public key. Two people say their friend's phrase out loud after a
/// forge, a human-layer check that they verified the same key. Never hex.
enum FingerprintPhrase {
    private static let emojis = [
        "🦊", "🦉", "🐢", "🐝", "🦭", "🐙", "🦅", "🐺",
        "🦡", "🐊", "🦔", "🐋", "🐿️", "🐞", "🦬", "🐈",
    ]
    private static let words = [
        "meadow", "anchor", "violet", "ember", "harbor", "cedar", "summit", "willow",
        "lantern", "moss", "drift", "quartz", "raven", "saddle", "tide", "grove",
        "flint", "marble", "noon", "orchid", "pebble", "quill", "river", "slate",
        "thorn", "umber", "vale", "wander", "yarrow", "zephyr", "amber", "birch",
        "canyon", "dune", "elm", "fjord", "garnet", "heath", "iris", "juniper",
        "kestrel", "larch", "mesa", "nectar", "onyx", "prairie", "reef", "sage",
        "tundra", "aspen", "brook", "cliff", "dell", "evergreen", "fern", "glacier",
        "hollow", "inlet", "jade", "knoll", "lagoon", "maple", "north", "oak",
    ]

    static func phrase(for publicKey: Data) -> String {
        let digest = Data(SHA256.hash(data: Data("seal.fingerprint.v1".utf8) + publicKey))
        let bytes = [UInt8](digest)
        let emoji = emojis[Int(bytes[0]) % emojis.count]
        let w1 = words[Int(bytes[1]) % words.count]
        let w2 = words[Int(bytes[2]) % words.count]
        let w3 = words[Int(bytes[3]) % words.count]
        return "\(emoji) \(w1) \(w2) \(w3)"
    }
}
