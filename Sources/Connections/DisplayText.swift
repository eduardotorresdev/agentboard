import Foundation

/// Text a person or an agent typed that the UI shows as a name or title (worktree titles, card
/// names): one line of visible text, so it can't hide, reorder or blank what's around it, while
/// emoji sequences and scripts that join letters keep working.
public enum DisplayText {
    /// Works character by character (grapheme clusters):
    /// - line breaks and tabs become one space; other control characters go;
    /// - bidi overrides, embeddings, isolates and marks go wherever they are;
    /// - other format characters (ZWJ, ZWNJ, tags, U+0600…) stay inside a character that has
    ///   something else, and go when they stand alone (a lone U+2060, U+FEFF, soft hyphen);
    /// - characters that draw nothing or a placeholder (unassigned, private use, U+FFFC,
    ///   U+1D159, Hangul fillers, the blank braille pattern) go, as does any single character
    ///   over `maxScalarsPerCharacter` scalars (stacked combining marks), without ending the text.
    /// The result keeps whole characters within `maxLength` characters and `maxBytes` UTF-8
    /// bytes. Nil when nothing visible is left.
    public static func clean(_ text: String, maxLength: Int, maxBytes: Int) -> String? {
        var result = ""
        var pendingSpace = false
        for character in text {
            if character.unicodeScalars.allSatisfy({ $0.properties.isWhitespace || isLineControl($0) }) {
                pendingSpace = !result.isEmpty
                continue
            }
            guard let kept = keep(character) else { continue }
            let piece = (pendingSpace ? " " : "") + kept
            guard result.count + piece.count <= maxLength, result.utf8.count + piece.utf8.count <= maxBytes else { break }
            result += piece
            pendingSpace = false
        }
        return result.unicodeScalars.contains(where: isVisible) ? result : nil
    }

    static let maxScalarsPerCharacter = 16

    /// The character without bidi controls, or nil when it should go altogether.
    private static func keep(_ character: Character) -> String? {
        let scalars = character.unicodeScalars.filter { !bidi.contains($0.value) }
        guard !scalars.isEmpty, scalars.count <= maxScalarsPerCharacter else { return nil }
        if scalars.contains(where: { blank.contains($0.value) || [.unassigned, .privateUse, .surrogate, .control].contains($0.properties.generalCategory) }) {
            return nil
        }
        // A character made only of format characters draws nothing: unless it prefixes a number
        // (U+0600–0605, U+06DD, U+070F, U+08E2, U+110BD), which shows as a sign.
        if scalars.allSatisfy({ $0.properties.generalCategory == .format }), !scalars.contains(where: { numberSigns.contains($0.value) }) {
            return nil
        }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars)
        return String(kept)
    }

    private static func isLineControl(_ scalar: Unicode.Scalar) -> Bool {
        [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029].contains(scalar.value)
    }

    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .nonspacingMark, .enclosingMark, .spacingMark, .control, .format: numberSigns.contains(scalar.value)
        default: !scalar.properties.isWhitespace
        }
    }

    private static let bidi: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                            0x2066, 0x2067, 0x2068, 0x2069]
    private static let blank: Set<UInt32> = [0x115F, 0x1160, 0x2800, 0x3164, 0xFFA0, 0xFFFC, 0xFFFD, 0x1D159]
    private static let numberSigns: Set<UInt32> = [0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605, 0x06DD, 0x070F, 0x08E2, 0x110BD]
}
