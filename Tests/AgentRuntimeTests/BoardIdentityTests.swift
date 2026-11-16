import CryptoKit
import Foundation
import Testing
@testable import AgentRuntime

/// A board proving who it is to a host, and what it makes of the host's verdict ("Board
/// identity" in docs/hosts.md), against the vector the Rust host is tested with.
struct BoardIdentityTests {
    private static func hex(_ text: String) -> Data {
        Data(stride(from: 0, to: text.count, by: 2).map { UInt8(text.dropFirst($0).prefix(2), radix: 16)! })
    }

    @Test func theProofAndFingerprintAreTheOnesTheHostExpects() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("core/fixtures/board-identity.json")
        let vector = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String])
        let field = { (name: String) in Self.hex(vector[name]!) }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: field("board_identity_seed"))
        #expect(key.publicKey.rawRepresentation == field("board_identity_key"))
        #expect(HostChannel.fingerprint(of: key.publicKey.rawRepresentation) == vector["fingerprint"])

        let signed = HostChannel.signed(boardEphemeral: field("board_ephemeral_key"), hostEphemeral: field("host_ephemeral_key"), hostIdentity: field("host_identity_key"))
        #expect(signed == field("signed"))
        // The host's own proof holds here, and this build's has its layout (signatures differ: CryptoKit's are randomized).
        let theirs = field("proof")
        #expect(key.publicKey.isValidSignature(theirs.dropFirst(32).prefix(64), for: signed))
        let mine = try #require(HostChannel.proof(.init(key: key, name: vector["name"]!), boardEphemeral: field("board_ephemeral_key"),
                                                  hostEphemeral: field("host_ephemeral_key"), hostIdentity: field("host_identity_key")))
        #expect(mine.count == theirs.count && mine.prefix(32) == theirs.prefix(32) && mine.dropFirst(96) == theirs.dropFirst(96))
        #expect(key.publicKey.isValidSignature(mine.dropFirst(32).prefix(64), for: signed))

        // A name is cut to 64 bytes without splitting a character.
        let long = try #require(HostChannel.proof(.init(key: key, name: String(repeating: "é", count: 40)), boardEphemeral: Data(count: 32),
                                                  hostEphemeral: Data(count: 32), hostIdentity: Data(count: 32)))
        #expect(String(decoding: long.dropFirst(96), as: UTF8.self) == String(repeating: "é", count: 32))
    }

    @Test func aVerdictIsTrustedOrPendingAndNothingElse() {
        #expect(HostChannel.verdict(Data("trusted".utf8)) == .channel(-1))
        #expect(HostChannel.verdict(Data("pending 0".utf8)) == .pending(trusted: 0))
        #expect(HostChannel.verdict(Data("pending 3".utf8)) == .pending(trusted: 3))
        for other in ["", "pending", "pending x", "pending -1", "pending 1 2", "trusted ", "Trusted", "ok"] {
            #expect(HostChannel.verdict(Data(other.utf8)) == nil, "\(other)")
        }
    }

    /// A host's end of a line, after the handshake: what the board sent, and what it will hear.
    private final class FakeHost: @unchecked Sendable {
        let lock = NSCondition()
        var sent: [Data] = [], answers: [Data] = [], closed = false
        let sealing = SymmetricKey(size: .bits256), opening = SymmetricKey(size: .bits256)

        var line: HostChannel.Line {
            HostChannel.Line(send: { message, _ in self.lock.withLock { self.sent.append(message); self.lock.broadcast() }; return true },
                             receive: { timeout in
                                 self.lock.lock()
                                 defer { self.lock.unlock() }
                                 let deadline = Date().addingTimeInterval(timeout ?? 5)
                                 while self.answers.isEmpty, !self.closed { guard self.lock.wait(until: deadline) else { return nil } }
                                 return self.answers.isEmpty ? nil : self.answers.removeFirst()
                             },
                             close: { self.lock.withLock { self.closed = true; self.lock.broadcast() } }, dispose: {})
        }

        /// What the host says, sealed as its message `number`.
        func say(_ text: String, _ number: UInt64) {
            let sealed = try! ChaChaPoly.seal(Data(text.utf8), using: opening, nonce: HostChannel.nonce(number))
            lock.withLock { answers.append(sealed.ciphertext + sealed.tag); lock.broadcast() }
        }

        /// The board's message `number`, opened.
        func heard(_ number: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            let deadline = Date().addingTimeInterval(5)
            while sent.count <= number { guard lock.wait(until: deadline) else { return nil } }
            let message = sent[number]
            return try? ChaChaPoly.open(ChaChaPoly.SealedBox(nonce: HostChannel.nonce(UInt64(number)), ciphertext: message.dropLast(16), tag: message.suffix(16)), using: sealing)
        }

        func prove(ticket: Data? = nil, as board: HostChannel.Board) -> HostChannel.Opened {
            HostChannel.prove(line, keys: (sealing, opening), boardEphemeral: Data(repeating: 1, count: 32), hostEphemeral: Data(repeating: 2, count: 32),
                              hostKey: Data(repeating: 3, count: 32), board: board, ticket: ticket, kind: Data("boards".utf8), timeout: 0.5)
        }
    }

    @Test func aTrustedBoardGetsItsChannelAndAPendingOrRefusedOneDoesNot() throws {
        let board = HostChannel.Board(key: Curve25519.Signing.PrivateKey(), name: "Test Mac")
        let signed = HostChannel.signed(boardEphemeral: Data(repeating: 1, count: 32), hostEphemeral: Data(repeating: 2, count: 32), hostIdentity: Data(repeating: 3, count: 32))

        // Trusted, on the direct path: ticket, proof, then what the channel carries; the stream counts on from there on both sides.
        let trusting = FakeHost()
        trusting.say("trusted", 0)
        let channel = try #require(trusting.prove(ticket: Data(repeating: 9, count: 32), as: board).channel)
        defer { close(channel) }
        #expect(trusting.heard(0) == Data(repeating: 9, count: 32))
        let proof = try #require(trusting.heard(1))
        #expect(proof.prefix(32) == board.key.publicKey.rawRepresentation && proof.dropFirst(96) == Data("Test Mac".utf8))
        #expect(board.key.publicKey.isValidSignature(proof.dropFirst(32).prefix(64), for: signed))
        #expect(trusting.heard(2) == Data("boards".utf8))
        #expect(write(channel, "{}\n", 3) == 3)
        #expect(trusting.heard(3) == Data("{}\n".utf8))
        trusting.say("listed", 1)
        var buffer = [UInt8](repeating: 0, count: 16)
        #expect(read(channel, &buffer, 16) == 6 && Array(buffer.prefix(6)) == Array("listed".utf8))

        // Pending: the count comes out and the line is done with; what the channel would carry was already said, for the host to drop.
        let wary = FakeHost()
        wary.say("pending 2", 0)
        #expect(wary.prove(as: board) == .pending(trusted: 2))
        #expect(wary.heard(0)?.count == 96 + 8 && wary.heard(1) == Data("boards".utf8) && wary.sent.count == 2)

        // Anything else is a failure, not "pending": words the contract doesn't have, a verdict
        // sealed as another message, and a host that closes with no verdict (a proof it refused).
        let odd = FakeHost()
        odd.say("welcome", 0)
        #expect(odd.prove(as: board) == .failed)
        let replayed = FakeHost()
        replayed.say("trusted", 1)
        #expect(replayed.prove(as: board) == .failed)
        let silent = FakeHost()
        silent.line.close()
        #expect(silent.prove(as: board) == .failed)
        #expect(FakeHost().prove(as: board) == .failed, "no verdict in time")
    }
}
