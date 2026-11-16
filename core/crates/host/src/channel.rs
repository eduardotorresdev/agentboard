//! The host's half of "The channel" in docs/hosts.md: the handshake that proves who the host
//! is, and the sealing of every message after it.

use chacha20poly1305::aead::{AeadInPlace, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use hkdf::Hkdf;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

/// The most plaintext one message carries.
pub const CHUNK: usize = 64 * 1024;
pub const TAG: usize = 16;
const INFO: &[u8] = b"agentboard channel v1";
const BOARD_INFO: &[u8] = b"agentboard board v1";
/// The longest name a proof may carry.
const NAME: usize = 64;
/// A direction ends long before its counter could wrap and reuse a nonce.
const LAST: u64 = 1 << 63;

/// One direction of a channel. The cipher zeroizes its key when dropped.
pub struct Sealed {
    cipher: ChaCha20Poly1305,
    counter: u64,
}

impl Sealed {
    fn new(key: &[u8]) -> Sealed {
        Sealed { cipher: ChaCha20Poly1305::new_from_slice(key).expect("32 bytes"), counter: 0 }
    }

    /// The next message's nonce: its number in this direction, 12 bytes little-endian.
    fn nonce(&mut self) -> Result<Nonce, &'static str> {
        if self.counter >= LAST {
            return Err("message counter exhausted");
        }
        let mut nonce = [0u8; 12];
        nonce[..8].copy_from_slice(&self.counter.to_le_bytes());
        self.counter += 1;
        Ok(nonce.into())
    }

    /// Turns a chunk into its message, in place: ciphertext then tag.
    pub fn seal(&mut self, message: &mut Vec<u8>) -> Result<(), &'static str> {
        if message.len() > CHUNK {
            return Err("chunk too large");
        }
        let nonce = self.nonce()?;
        self.cipher.encrypt_in_place(&nonce, b"", message).map_err(|_| "could not seal")
    }

    /// Turns a message back into its chunk, in place. A message that is too short, too long,
    /// altered, repeated or out of order fails, and the channel must end.
    pub fn open(&mut self, message: &mut Vec<u8>) -> Result<(), &'static str> {
        if message.len() < TAG || message.len() > CHUNK + TAG {
            return Err("message of a wrong size");
        }
        let nonce = self.nonce()?;
        self.cipher.decrypt_in_place(&nonce, b"", message).map_err(|_| "message not authentic")
    }
}

pub struct Accepted {
    /// What the host sends back: its ephemeral key, then its signature.
    pub answer: [u8; 96],
    /// The two ephemeral keys, the board's then the host's: what a board's proof must name.
    pub ephemerals: [u8; 64],
    /// Opens what the board sends.
    pub from_board: Sealed,
    /// Seals what the host sends.
    pub to_board: Sealed,
}

/// Answers a board's first message with a fresh ephemeral key.
pub fn accept(identity: &SigningKey, board_key: &[u8]) -> Result<Accepted, &'static str> {
    let mut seed = Zeroizing::new([0u8; 32]);
    getrandom::getrandom(&mut *seed).map_err(|_| "no random bytes")?;
    accept_with(identity, board_key, StaticSecret::from(*seed))
}

fn accept_with(identity: &SigningKey, board_key: &[u8], ephemeral: StaticSecret) -> Result<Accepted, &'static str> {
    let board_key: [u8; 32] = board_key.try_into().map_err(|_| "board key of a wrong size")?;
    let host_key = PublicKey::from(&ephemeral);
    let shared = ephemeral.diffie_hellman(&PublicKey::from(board_key));
    // An all-zero secret is what a zero or low-order board key gives: one anybody can compute.
    if !shared.was_contributory() {
        return Err("board key of low order");
    }
    let mut salt = [0u8; 64];
    salt[..32].copy_from_slice(&board_key);
    salt[32..].copy_from_slice(host_key.as_bytes());
    let mut keys = Zeroizing::new([0u8; 64]);
    Hkdf::<Sha256>::new(Some(&salt), shared.as_bytes()).expand(INFO, &mut *keys).expect("64 bytes");

    let mut answer = [0u8; 96];
    answer[..32].copy_from_slice(host_key.as_bytes());
    // With what it is for: the identity key never signs bytes a stranger chose alone.
    answer[32..].copy_from_slice(&identity.sign(&[INFO, &salt[..]].concat()).to_bytes());
    // First half board→host, second half host→board.
    Ok(Accepted { answer, ephemerals: salt, from_board: Sealed::new(&keys[..32]), to_board: Sealed::new(&keys[32..]) })
}

/// The identity key and the name in a board's proof ("Board identity"), when its signature is
/// that key's over this very channel (`ephemerals`) to this very host: one made for another
/// host, or for another channel to this one, proves nothing here.
pub fn proven<'a>(proof: &'a [u8], ephemerals: &[u8; 64], host: &VerifyingKey) -> Option<([u8; 32], &'a [u8])> {
    if proof.len() < 96 || proof.len() > 96 + NAME {
        return None;
    }
    let key: [u8; 32] = proof[..32].try_into().ok()?;
    let signature = Signature::from_slice(&proof[32..96]).ok()?;
    let signed = [BOARD_INFO, &ephemerals[..], host.as_bytes()].concat();
    // Strict: no weak key, for which anybody could sign.
    VerifyingKey::from_bytes(&key).ok()?.verify_strict(&signed, &signature).ok()?;
    Some((key, &proof[96..]))
}

/// What a channel carries, named by a trusted board's first sealed message after its proof.
#[derive(Debug, PartialEq, Eq)]
pub enum Carrying {
    Core,
    /// A port on this host's loopback.
    Tcp(u16),
    /// The list of boards this host trusts, kept by the host itself.
    Boards,
}

impl Carrying {
    pub fn parse(text: &[u8]) -> Option<Carrying> {
        if text == b"core" {
            return Some(Carrying::Core);
        }
        if text == b"boards" {
            return Some(Carrying::Boards);
        }
        // Plain decimal only: `parse` alone would take "+80".
        let digits = text.strip_prefix(b"tcp:").filter(|digits| !digits.is_empty() && digits.iter().all(u8::is_ascii_digit) && digits[0] != b'0')?;
        std::str::from_utf8(digits).ok()?.parse().ok().map(Carrying::Tcp)
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use ed25519_dalek::Verifier;

    pub fn hex(text: &str) -> Vec<u8> {
        (0..text.len()).step_by(2).map(|at| u8::from_str_radix(&text[at..at + 2], 16).unwrap()).collect()
    }

    /// The board's side, written from docs/hosts.md with the primitives alone: shares no code
    /// with `accept` or `Sealed`.
    pub struct Board {
        secret: StaticSecret,
        /// Who the board is to a host: the key its proof is signed with.
        pub identity: SigningKey,
        /// What the proof signs after its label: both ephemeral keys, then the host's identity.
        pub transcript: Vec<u8>,
        seal_key: [u8; 32],
        open_key: [u8; 32],
        sent: u64,
        received: u64,
    }

    impl Board {
        /// A board nobody has seen before.
        pub fn new() -> Board {
            let mut seed = [0u8; 32];
            getrandom::getrandom(&mut seed).unwrap();
            Board::of(SigningKey::from_bytes(&seed))
        }

        pub fn of(identity: SigningKey) -> Board {
            let mut seed = [0u8; 32];
            getrandom::getrandom(&mut seed).unwrap();
            Board { secret: StaticSecret::from(seed), identity, transcript: Vec::new(), seal_key: [0; 32], open_key: [0; 32], sent: 0, received: 0 }
        }

        pub fn key(&self) -> [u8; 32] {
            PublicKey::from(&self.secret).to_bytes()
        }

        /// False when the answer isn't the host's.
        pub fn finish(&mut self, answer: &[u8], host_identity: &VerifyingKey) -> bool {
            if answer.len() != 96 {
                return false;
            }
            let salt = [&self.key()[..], &answer[..32]].concat();
            if host_identity.verify(&[INFO, &salt[..]].concat(), &Signature::from_slice(&answer[32..]).unwrap()).is_err() {
                return false;
            }
            let host_key: [u8; 32] = answer[..32].try_into().unwrap();
            let shared = self.secret.diffie_hellman(&PublicKey::from(host_key));
            let mut keys = [0u8; 64];
            Hkdf::<Sha256>::new(Some(&salt), shared.as_bytes()).expand(b"agentboard channel v1", &mut keys).unwrap();
            self.seal_key.copy_from_slice(&keys[..32]);
            self.open_key.copy_from_slice(&keys[32..]);
            self.transcript = [&salt[..], host_identity.as_bytes()].concat();
            true
        }

        /// The proof before sealing: identity key, signature, name.
        pub fn proof(&self, name: &str) -> Vec<u8> {
            let signature = self.identity.sign(&[b"agentboard board v1", &self.transcript[..]].concat());
            [self.identity.verifying_key().as_bytes(), &signature.to_bytes()[..], name.as_bytes()].concat()
        }

        pub fn prove(&mut self, name: &str) -> Vec<u8> {
            let proof = self.proof(name);
            self.seal(&proof)
        }

        fn nonce(counter: u64) -> Nonce {
            let mut nonce = [0u8; 12];
            nonce[..8].copy_from_slice(&counter.to_le_bytes());
            nonce.into()
        }

        pub fn seal(&mut self, chunk: &[u8]) -> Vec<u8> {
            use chacha20poly1305::aead::Aead;
            self.sent += 1;
            ChaCha20Poly1305::new_from_slice(&self.seal_key).unwrap().encrypt(&Self::nonce(self.sent - 1), chunk).unwrap()
        }

        pub fn open(&mut self, message: &[u8]) -> Option<Vec<u8>> {
            use chacha20poly1305::aead::Aead;
            self.received += 1;
            ChaCha20Poly1305::new_from_slice(&self.open_key).unwrap().decrypt(&Self::nonce(self.received - 1), message).ok()
        }
    }

    fn identity() -> SigningKey {
        // RFC 8032, test 1.
        SigningKey::from_bytes(&hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60").try_into().unwrap())
    }

    /// RFC 7748's two keys as board and host; the derived keys and sealed messages come from
    /// CryptoKit (the board's library), run on the same inputs.
    #[test]
    fn fixed_vectors() {
        let board_key = hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
        let ephemeral: [u8; 32] = hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb").try_into().unwrap();
        let mut accepted = accept_with(&identity(), &board_key, StaticSecret::from(ephemeral)).unwrap();

        assert_eq!(accepted.answer[..32], hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"));
        let salt = [&board_key[..], &accepted.answer[..32]].concat();
        let signature = Signature::from_slice(&accepted.answer[32..]).unwrap();
        assert!(identity().verifying_key().verify(&[INFO, &salt[..]].concat(), &signature).is_ok());
        assert_eq!(identity().verifying_key().as_bytes()[..], hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"));

        let mut first = hex("0672ca875624fa1a5d090006a9e90b8263f39123");
        accepted.from_board.open(&mut first).unwrap();
        assert_eq!(first, b"core");

        let mut skipped = b"nonce 0".to_vec();
        accepted.to_board.seal(&mut skipped).unwrap();
        let mut second = b"hi".to_vec();
        accepted.to_board.seal(&mut second).unwrap();
        assert_eq!(second, hex("62e28711e895d17ce418666aa27ac5c40569"));
    }

    #[test]
    fn interoperates_with_a_board_written_from_the_spec() {
        let host = identity();
        let mut board = Board::new();
        let mut accepted = accept(&host, &board.key()).unwrap();
        assert!(board.finish(&accepted.answer, &host.verifying_key()));

        for size in [0, 1, 1000, CHUNK] {
            let chunk = vec![7u8; size];
            let mut message = board.seal(&chunk);
            assert_eq!(message.len(), size + TAG);
            accepted.from_board.open(&mut message).unwrap();
            assert_eq!(message, chunk);

            let mut message = chunk.clone();
            accepted.to_board.seal(&mut message).unwrap();
            assert_eq!(board.open(&message).unwrap(), chunk);
        }
        // Another identity's answer is not this host's.
        let other = SigningKey::from_bytes(&[1; 32]);
        assert!(!Board::new().finish(&accepted.answer, &other.verifying_key()));
        assert!(!board.finish(&accept(&other, &board.key()).unwrap().answer, &host.verifying_key()));
    }

    #[test]
    fn refuses_weak_board_keys() {
        assert!(accept(&identity(), &[0; 32]).is_err());
        // A point of order 8 (RFC 7748 §6.1's list).
        let low = hex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800");
        assert!(accept(&identity(), &low).is_err());
        assert!(accept(&identity(), &[9; 31]).is_err());
        assert!(accept(&identity(), &[9; 33]).is_err());
    }

    fn pair() -> (Board, Accepted) {
        let mut board = Board::new();
        let accepted = accept(&identity(), &board.key()).unwrap();
        assert!(board.finish(&accepted.answer, &identity().verifying_key()));
        (board, accepted)
    }

    #[test]
    fn refuses_messages_out_of_order_altered_or_of_a_wrong_size() {
        let (mut board, mut accepted) = pair();
        let (first, second) = (board.seal(b"one"), board.seal(b"two"));
        assert!(accepted.from_board.open(&mut second.clone()).is_err(), "out of order");

        let (mut board, mut accepted) = pair();
        let first_again = board.seal(b"one");
        accepted.from_board.open(&mut first_again.clone()).unwrap();
        assert!(accepted.from_board.open(&mut first_again.clone()).is_err(), "repeated");
        let _ = (first, second);

        let (mut board, mut accepted) = pair();
        let mut altered = board.seal(b"one");
        altered[0] ^= 1;
        assert!(accepted.from_board.open(&mut altered).is_err(), "altered");

        let (mut board, mut accepted) = pair();
        assert!(accepted.from_board.open(&mut vec![0; TAG - 1]).is_err(), "short");
        assert!(accepted.from_board.open(&mut vec![0; CHUNK + TAG + 1]).is_err(), "long");
        assert!(accepted.to_board.seal(&mut vec![0; CHUNK + 1]).is_err(), "chunk too large");
        // A refused size used no nonce: the next real message still opens.
        let mut message = board.seal(b"one");
        accepted.from_board.open(&mut message).unwrap();
    }

    #[test]
    fn a_direction_ends_before_its_counter_wraps() {
        let (_, mut accepted) = pair();
        accepted.to_board.counter = LAST - 1;
        accepted.to_board.seal(&mut b"last".to_vec()).unwrap();
        assert!(accepted.to_board.seal(&mut b"one more".to_vec()).is_err());
        accepted.from_board.counter = LAST;
        assert!(accepted.from_board.open(&mut vec![0; 32]).is_err());
    }

    #[test]
    fn names_what_a_channel_carries() {
        assert_eq!(Carrying::parse(b"core"), Some(Carrying::Core));
        assert_eq!(Carrying::parse(b"tcp:1"), Some(Carrying::Tcp(1)));
        assert_eq!(Carrying::parse(b"tcp:65535"), Some(Carrying::Tcp(65535)));
        assert_eq!(Carrying::parse(b"boards"), Some(Carrying::Boards));
        for refused in ["", "Core", "core ", "tcp:", "tcp:0", "tcp:65536", "tcp:+80", "tcp:080", "tcp: 80", "tcp:80\n", "tcp:example.com:80", "tcp:10.0.0.1:80", "udp:80", "unix:/x", "board", "boards\n"] {
            assert_eq!(Carrying::parse(refused.as_bytes()), None, "{refused:?}");
        }
    }

    #[test]
    fn a_proof_holds_for_one_channel_to_one_host() {
        let host = identity();
        let (board, accepted) = pair();
        let proof = board.proof("Test Mac");
        let key = board.identity.verifying_key().to_bytes();
        assert_eq!(proven(&proof, &accepted.ephemerals, &host.verifying_key()), Some((key, &b"Test Mac"[..])));
        assert_eq!(proven(&proof[..96], &accepted.ephemerals, &host.verifying_key()), Some((key, &b""[..])));
        // The name isn't signed: it arrives sealed, and decides nothing.
        assert!(proven(&[&proof[..96], &[b'n'; 64][..]].concat(), &accepted.ephemerals, &host.verifying_key()).is_some());

        // Made for host A, shown to host B.
        let other = SigningKey::from_bytes(&[1; 32]);
        assert_eq!(proven(&proof, &accepted.ephemerals, &other.verifying_key()), None);
        // The right key, on another channel to the same host: either ephemeral key differs.
        let (_, another) = pair();
        assert_eq!(proven(&proof, &another.ephemerals, &host.verifying_key()), None);
        for at in [0, 32] {
            let mut ephemerals = accepted.ephemerals;
            ephemerals[at] ^= 1;
            assert_eq!(proven(&proof, &ephemerals, &host.verifying_key()), None);
        }
        // Somebody else's key over this board's signature, an altered signature, wrong sizes.
        let stolen = [&other.verifying_key().to_bytes()[..], &proof[32..]].concat();
        assert_eq!(proven(&stolen, &accepted.ephemerals, &host.verifying_key()), None);
        let mut altered = proof.clone();
        altered[40] ^= 1;
        assert_eq!(proven(&altered, &accepted.ephemerals, &host.verifying_key()), None);
        assert_eq!(proven(&proof[..95], &accepted.ephemerals, &host.verifying_key()), None);
        assert_eq!(proven(&[&proof[..96], &[b'n'; 65][..]].concat(), &accepted.ephemerals, &host.verifying_key()), None);
        assert_eq!(proven(b"core", &accepted.ephemerals, &host.verifying_key()), None);
        // The channel's own signature (the host's answer) is no proof either: another label.
        let replayed = [&host.verifying_key().to_bytes()[..], &accepted.answer[32..]].concat();
        assert_eq!(proven(&replayed, &accepted.ephemerals, &host.verifying_key()), None);
    }

    /// Fixed keys, shared with the board's tests through `core/fixtures/board-identity.json`:
    /// RFC 7748's two keys as the ephemeral ones, RFC 8032's tests 1 and 2 as host and board.
    #[test]
    fn board_identity_vectors() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!("../../../fixtures/board-identity.json")).unwrap();
        let field = |name: &str| hex(fixture[name].as_str().unwrap());
        let ephemeral: [u8; 32] = hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb").try_into().unwrap();
        let accepted = accept_with(&identity(), &field("board_ephemeral_key"), StaticSecret::from(ephemeral)).unwrap();
        assert_eq!(accepted.ephemerals[..], [field("board_ephemeral_key"), field("host_ephemeral_key")].concat());
        assert_eq!(identity().verifying_key().as_bytes()[..], field("host_identity_key"));

        let board = SigningKey::from_bytes(&field("board_identity_seed").try_into().unwrap());
        assert_eq!(board.verifying_key().as_bytes()[..], field("board_identity_key"));
        let signed = [BOARD_INFO, &accepted.ephemerals[..], identity().verifying_key().as_bytes()].concat();
        assert_eq!(signed, field("signed"));
        let name = fixture["name"].as_str().unwrap();
        let proof = [board.verifying_key().as_bytes(), &board.sign(&signed).to_bytes()[..], name.as_bytes()].concat();
        assert_eq!(proof, field("proof"), "{}", proof.iter().map(|byte| format!("{byte:02x}")).collect::<String>());
        assert_eq!(proven(&proof, &accepted.ephemerals, &identity().verifying_key()), Some((board.verifying_key().to_bytes(), name.as_bytes())));
        assert_eq!(crate::boards::fingerprint(board.verifying_key().as_bytes()), fixture["fingerprint"].as_str().unwrap());
    }
}
