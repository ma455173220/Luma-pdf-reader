import Foundation

/// Reading the page the reader typed into the page box.
public enum PageJump {
    /// The page index for what was typed, counting the PDF's pages from 1 regardless of the
    /// numbers printed on them. A number past either end goes to that end; anything that is not a
    /// number gives nil.
    public static func pageIndex(from typed: String, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        // Full-width digits, as a Chinese input method may type them, count as digits.
        let digits = String(typed.trimmingCharacters(in: .whitespaces).map { character -> Character in
            guard let scalar = character.unicodeScalars.first, (0xFF10...0xFF19).contains(scalar.value),
                  let ascii = Unicode.Scalar(scalar.value - 0xFF10 + 0x30) else { return character }
            return Character(ascii)
        })
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let number = Int(digits) else { return pageCount - 1 }      // too many digits: the last page
        return min(max(number, 1), pageCount) - 1
    }
}
