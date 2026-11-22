import CryptoKit
import Foundation
import Network
import TerminalCore
import XCTest
@testable import AgentBoardPhone

/// The phone's side of "The channel" and "Board identity" (docs/hosts.md) against a fake relay
/// that plays the host's side, written from the doc, not from HostChannel.swift.
final class ChannelTests: XCTestCase {
    func testTrustedBoardGetsAStreamToTheCore() throws {
        let board = Curve25519.Signing.PrivateKey()
        let host = try FakeHost(trusting: [board.publicKey.rawRepresentation])
        let opened = HostChannel.open(server: host.url, token: "t", host: UUID(), hostKey: host.identity.publicKey.rawRepresentation,
                                      board: .init(key: board, name: "Phone"), timeout: 5)
        guard case .channel(let fd) = opened else { return XCTFail("\(opened)") }
        defer { close(fd) }
        XCTAssertEqual(write(fd, "ping", 4), 4)
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(read(fd, &buffer, 16), 4)
        XCTAssertEqual(Array(buffer.prefix(4)), Array("ping".utf8))
        XCTAssertEqual(host.carried, "core")
        XCTAssertEqual(host.name, "Phone")
    }

    func testUnknownBoardIsPending() throws {
        let host = try FakeHost(trusting: [Curve25519.Signing.PrivateKey().publicKey.rawRepresentation])
        let opened = HostChannel.open(server: host.url, token: "t", host: UUID(), hostKey: host.identity.publicKey.rawRepresentation,
                                      board: .init(key: Curve25519.Signing.PrivateKey(), name: "Phone"), timeout: 5)
        XCTAssertEqual(opened, .pending(trusted: 1))
    }

    func testAHostThatIsNotWhoItsKeySaysGetsNothing() throws {
        let board = Curve25519.Signing.PrivateKey()
        let host = try FakeHost(trusting: [board.publicKey.rawRepresentation])
        let opened = HostChannel.open(server: host.url, token: "t", host: UUID(), hostKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                                      board: .init(key: board, name: "Phone"), timeout: 5)
        XCTAssertEqual(opened, .failed)
        XCTAssertNil(host.name, "no proof goes to a host that didn't prove itself")
    }

    func testBoardIdentityFixture() throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appendingPathComponent("core/fixtures/board-identity.json"))) as! [String: String]
        func hex(_ key: String) -> Data { Data(stride(from: 0, to: fixture[key]!.count, by: 2).map { UInt8(fixture[key]!.dropFirst($0).prefix(2), radix: 16)! }) }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: hex("board_identity_seed"))
        XCTAssertEqual(key.publicKey.rawRepresentation, hex("board_identity_key"))
        XCTAssertEqual(HostChannel.signed(boardEphemeral: hex("board_ephemeral_key"), hostEphemeral: hex("host_ephemeral_key"),
                                          hostIdentity: hex("host_identity_key")), hex("signed"))
        XCTAssertEqual(HostChannel.fingerprint(of: hex("board_identity_key")), fixture["fingerprint"])
        let proof = HostChannel.proof(.init(key: key, name: fixture["name"]!), boardEphemeral: hex("board_ephemeral_key"),
                                      hostEphemeral: hex("host_ephemeral_key"), hostIdentity: hex("host_identity_key"))!
        XCTAssertEqual(proof.prefix(32), hex("proof").prefix(32))
        XCTAssertEqual(proof.dropFirst(96), hex("proof").dropFirst(96))
        XCTAssertTrue(key.publicKey.isValidSignature(proof.dropFirst(32).prefix(64), for: hex("signed")))
    }

    /// A snapshot as the core sends it restores to the same screen, byte for byte.
    func testRestoresCoreSnapshotFixtures() throws {
        let folder = Self.repo.appendingPathComponent("core/fixtures/terminal")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".snapshot") }
        XCTAssertFalse(names.isEmpty)
        for name in names {
            let bytes = try [UInt8](Data(contentsOf: folder.appendingPathComponent(name)))
            let terminal = Terminal(cols: 10, rows: 5)
            XCTAssertTrue(terminal.restore(bytes), name)
            XCTAssertEqual(terminal.snapshot(), bytes, name)
        }
    }

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// The account server's relay and the host behind it, in one: a WebSocket listener on the
/// loopback that answers the board as docs/hosts.md says a host does, then echoes the stream.
final class FakeHost: @unchecked Sendable {
    let identity = Curve25519.Signing.PrivateKey()
    private(set) var url = URL(string: "http://127.0.0.1")!
    private let listener: NWListener
    private let trusted: [Data]
    private let lock = NSLock()
    private var _carried: String?
    private var _name: String?
    var carried: String? { lock.withLock { _carried } }
    var name: String? { lock.withLock { _name } }

    init(trusting trusted: [Data]) throws {
        self.trusted = trusted
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            Thread.detachNewThread { self?.serve(Messages(connection)) }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        url = URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!
    }

    deinit { listener.cancel() }

    private func serve(_ line: Messages) {
        let info = Data("agentboard channel v1".utf8)
        guard let boardEphemeral = line.receive(), boardEphemeral.count == 32,
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: boardEphemeral) else { return line.close() }
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let hostEphemeral = mine.publicKey.rawRepresentation
        let salt = boardEphemeral + hostEphemeral
        line.send(hostEphemeral + (try! identity.signature(for: info + salt)))
        let keys = try! mine.sharedSecretFromKeyAgreement(with: theirs)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 64).withUnsafeBytes { Data($0) }
        let (fromBoard, toBoard) = (SymmetricKey(data: keys.prefix(32)), SymmetricKey(data: keys.suffix(32)))
        var heard: UInt64 = 0, said: UInt64 = 0
        func open() -> Data? {
            guard let message = line.receive(), message.count >= 16,
                  let box = try? ChaChaPoly.SealedBox(nonce: HostChannel.nonce(heard), ciphertext: message.dropLast(16), tag: message.suffix(16)),
                  let plain = try? ChaChaPoly.open(box, using: fromBoard) else { return nil }
            heard += 1
            return plain
        }
        func seal(_ plain: Data) {
            let box = try! ChaChaPoly.seal(plain, using: toBoard, nonce: HostChannel.nonce(said))
            said += 1
            line.send(box.ciphertext + box.tag)
        }
        // The proof: key, signature over the two ephemeral keys and this host's identity, name.
        guard let proof = open(), proof.count >= 96, proof.count <= 160,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: proof.prefix(32)),
              key.isValidSignature(proof.dropFirst(32).prefix(64),
                                   for: Data("agentboard board v1".utf8) + boardEphemeral + hostEphemeral + identity.publicKey.rawRepresentation)
        else { return line.close() }
        lock.withLock { _name = String(decoding: proof.dropFirst(96), as: UTF8.self) }
        guard trusted.contains(proof.prefix(32)) else {
            seal(Data("pending \(trusted.count)".utf8))
            return line.close()
        }
        seal(Data("trusted".utf8))
        guard let kind = open() else { return line.close() }
        lock.withLock { _carried = String(decoding: kind, as: UTF8.self) }
        while let chunk = open() { seal(chunk) }
        line.close()
    }

    /// Blocking WebSocket messages over one connection.
    final class Messages: @unchecked Sendable {
        let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }

        func receive() -> Data? {
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: Data?
            connection.receiveMessage { data, _, _, error in
                if error == nil { result = data ?? Data() }
                done.signal()
            }
            guard done.wait(timeout: .now() + 10) == .success else { return nil }
            return result
        }

        func send(_ data: Data) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
            // Waits until it's out, so a close right after doesn't cut it.
            let sent = DispatchSemaphore(value: 0)
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in sent.signal() })
            _ = sent.wait(timeout: .now() + 5)
        }

        func close() { connection.cancel() }
    }
}
