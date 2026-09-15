import Foundation

//  EstateMediaStore.swift
//  Seal
//
//  Photos and voice notes are too big for the keychain. They are stored on
//  disk ALREADY ENCRYPTED under their envelope's content key, byte for byte
//  the blob that goes to CloudKit, in Application Support under the owner's
//  identity hash. The content key lives in the estate (keychain). Nothing
//  readable is ever written to disk.

enum EstateMediaStore {

    static func directory(ownerHash: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("estate", isDirectory: true)
            .appendingPathComponent(ownerHash, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ ciphertext: Data, blobID: String, ownerHash: String) throws {
        let url = directory(ownerHash: ownerHash).appendingPathComponent(blobID)
        try ciphertext.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func read(blobID: String, ownerHash: String) -> Data? {
        try? Data(contentsOf: directory(ownerHash: ownerHash).appendingPathComponent(blobID))
    }

    static func wipe(ownerHash: String) {
        try? FileManager.default.removeItem(at: directory(ownerHash: ownerHash))
    }
}
