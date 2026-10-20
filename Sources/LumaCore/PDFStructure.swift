import Foundation

/// The object index of a PDF file, read strictly.
///
/// PDF readers are forgiving: when a file's index is broken they quietly rebuild it, and where the
/// format is ambiguous each makes its own choice. This type is the opposite on purpose. Anything it
/// cannot follow exactly, or that readers are known to read differently, makes it throw, so the
/// append writer only ever touches files whose structure means one thing.
final class PDFStructure {
    enum Entry: Equatable {
        case free
        /// "In use at position 0". macOS's own PDF writer records numbers it never used this way;
        /// position 0 is the file header, so no object can live there.
        case placeholder
        case offset(Int, generation: Int)
        case compressed(stream: Int, index: Int)

        var isLive: Bool {
            switch self {
            case .offset, .compressed: return true
            case .free, .placeholder: return false
            }
        }

        var generation: Int {
            if case .offset(_, let generation) = self { return generation }
            return 0
        }
    }

    /// Leaves room for the appended update below the 4 GB limit of the index formats written here.
    static let sizeLimit = 0xFFFF_FFFF - 0x10_0000
    /// The PDF format's own ceiling on object numbers. Larger numbers only occur in broken or hostile files.
    static let maximumObjectNumber = 8_388_607

    let bytes: [UInt8]
    private(set) var entries: [Int: Entry] = [:]
    /// Numbers that the file's index sections describe in conflicting ways: deleted by a later save,
    /// reused under a new version number, or shadowed by a placeholder. The format says the newest
    /// section wins, but PDF readers do not all follow that, so such an object has no single meaning.
    private(set) var contested = Set<Int>()
    private(set) var trailer: PDFValue = .null
    private(set) var newestIsStream = false
    private(set) var newestXrefOffset = 0
    private(set) var sectionCount = 0
    private(set) var isHybrid = false

    /// Where every saved version of each object is, across all index sections. Used to tell an
    /// object pack that a later save replaced, and to find older copies of an object.
    private var versions: [Int: Set<Int>] = [:]
    /// Where every saved version of each object kept inside an object pack is: the pack and the
    /// place in it. Used to find older versions of the catalog.
    private var packedVersions: [Int: [(stream: Int, index: Int)]] = [:]
    private var objectStreams: [Int: (bytes: [UInt8], first: Int, table: [(number: Int, offset: Int)])] = [:]
    /// How much the object packs read so far have expanded to, all together.
    private var expandedPackBytes = 0
    private var cache: [Int: PDFValue] = [:]
    private var pageNumbersCache: [Int]?

    init(_ bytes: [UInt8], sizeLimit: Int = PDFStructure.sizeLimit) throws {
        self.bytes = bytes
        guard bytes.count < sizeLimit else { throw PDFAppendError.refused("file is larger than 4 GB") }
        guard bytes.starts(with: Array("%PDF-".utf8)) else { throw PDFAppendError.damaged("file does not start with a PDF header") }

        newestXrefOffset = try findStartXref()
        var next: Int? = newestXrefOffset
        var seen = Set<Int>()
        while let offset = next {
            guard seen.insert(offset).inserted else { throw PDFAppendError.damaged("index sections refer to each other in a loop") }
            var section = try loadSection(at: offset)
            if let hybrid = section.trailer["XRefStm"] {
                // A hybrid file keeps part of one section in a compressed index beside the old-style table.
                // The table comes first; the compressed part fills in what the table leaves out or marks free.
                guard !section.isStream, let hybridOffset = hybrid.int else { throw PDFAppendError.damaged("hybrid index pointer is unusable") }
                let extra = try loadSection(at: hybridOffset)
                guard extra.isStream else { throw PDFAppendError.damaged("hybrid index pointer does not lead to a compressed index") }
                for (number, extraEntry) in extra.entries {
                    switch section.entries[number] {
                    case nil: section.entries[number] = extraEntry
                    case .free?, .placeholder?:
                        // The table says deleted, the compressed part says in use: readers disagree on
                        // which to believe (some see it, some do not, some repair the file), so the file
                        // is left alone.
                        if extraEntry.isLive && number != 0 { throw PDFAppendError.damaged("the two halves of a hybrid index disagree") }
                    default: break
                    }
                }
                isHybrid = true
            }
            for (number, older) in section.entries {
                if case .offset(let position, _) = older { versions[number, default: []].insert(position) }
                if case .compressed(let stream, let index) = older { packedVersions[number, default: []].append((stream, index)) }
                guard let newer = entries[number] else {
                    entries[number] = older
                    continue
                }
                // A live object replaced by a newer live one is the normal case, also when the number
                // was freed in between and reused under a new version number: every reader follows the
                // newest. The conflict is an object that a newer section marks deleted or shadows with
                // a placeholder while an older section still has it: readers that ignore such marks
                // go on showing it. (A reference to an outdated version is caught in `resolve`.)
                if older.isLive && !newer.isLive { contested.insert(number) }
            }
            if sectionCount == 0 {
                trailer = section.trailer
                newestIsStream = section.isStream
            }
            sectionCount += 1
            if let previous = section.trailer["Prev"] {
                guard let previousOffset = previous.int else { throw PDFAppendError.damaged("pointer to the previous index is not a plain number") }
                next = previousOffset
            } else {
                next = nil
            }
        }
        try checkObjectPacksWereNotReplaced()
        try checkEveryEntry()
    }

    var freedObjectCount: Int { entries.filter { $0.key != 0 && $0.value == .free }.count }
    var placeholderCount: Int { entries.filter { $0.value == .placeholder }.count }

    var isLinearized: Bool { occurrences(of: "/Linearized", within: 0..<min(bytes.count, 1024)) > 0 }

    private static func skippingBlanks(_ bytes: [UInt8], from offset: Int) -> Int {
        var index = offset
        while index < bytes.count && PDFParser.isSpace(bytes[index]) { index += 1 }
        return index
    }

    private func occurrences(of text: String, within range: Range<Int>) -> Int {
        let needle = Array(text.utf8)
        guard range.count >= needle.count else { return 0 }
        var found = 0
        var i = range.lowerBound
        let last = range.upperBound - needle.count
        while i <= last {
            if bytes[i] == needle[0] {
                var j = 1
                while j < needle.count && bytes[i + j] == needle[j] { j += 1 }
                if j == needle.count { found += 1 }
            }
            i += 1
        }
        return found
    }

    private func findStartXref() throws -> Int {
        let keyword = Array("startxref".utf8)
        let lowest = max(0, bytes.count - 4096)
        var position = bytes.count - keyword.count
        while position >= lowest {
            if bytes[position] == keyword[0] && Array(bytes[position..<(position + keyword.count)]) == keyword {
                var parser = PDFParser(bytes, at: position + keyword.count)
                guard let offset = parser.unsignedInteger(), offset < bytes.count else {
                    throw PDFAppendError.damaged("pointer to the index is unreadable")
                }
                return offset
            }
            position -= 1
        }
        throw PDFAppendError.damaged("file has no pointer to its index")
    }

    // MARK: Index sections

    /// A run of object numbers named by an index, checked against the format's ceiling so that later
    /// arithmetic on them cannot overflow.
    private func checkedRange(start: Int?, count: Int?) throws -> (start: Int, count: Int) {
        let limit = PDFStructure.maximumObjectNumber + 1
        guard let start, let count, start >= 0, count >= 0, start <= limit, count <= limit, start + count <= limit else {
            throw PDFAppendError.damaged("index names object numbers beyond what the format allows")
        }
        return (start, count)
    }

    private func loadSection(at offset: Int) throws -> (entries: [Int: Entry], trailer: PDFValue, isStream: Bool) {
        guard offset >= 0, offset < bytes.count else { throw PDFAppendError.damaged("index position lies outside the file") }
        var found: [Int: Entry] = [:]
        // Blank space before the index is allowed; anything else means the pointer is wrong.
        var parser = PDFParser(bytes, at: PDFStructure.skippingBlanks(bytes, from: offset))
        guard parser.index < bytes.count, parser.matches("xref") || (bytes[parser.index] >= 0x30 && bytes[parser.index] <= 0x39) else {
            throw PDFAppendError.damaged("index pointer does not lead to an index")
        }

        if parser.matches("xref") {
            parser.index += 4
            while true {
                parser.skipSpace()
                if parser.matches("trailer") { parser.index += 7; break }
                let range = try checkedRange(start: parser.unsignedInteger(), count: parser.unsignedInteger())
                guard range.count <= bytes.count / 18 + 1 else { throw PDFAppendError.damaged("old-style index table is longer than the file") }
                for k in 0..<range.count {
                    guard let position = parser.unsignedInteger(), let generation = parser.unsignedInteger(), generation <= 65535 else {
                        throw PDFAppendError.damaged("old-style index entry is unreadable")
                    }
                    let entry: Entry
                    switch parser.token() {
                    case "n": entry = position == 0 ? .placeholder : .offset(position, generation: generation)
                    case "f": entry = .free
                    default: throw PDFAppendError.damaged("old-style index entry is neither in use nor free")
                    }
                    if found[range.start + k] == nil { found[range.start + k] = entry }
                }
            }
            let trailer = try parser.value()
            guard trailer.entries != nil else { throw PDFAppendError.damaged("trailer is not a dictionary") }
            try checkWithinDeclaredSize(found, size: trailer["Size"]?.int)
            return (found, trailer, false)
        }

        let stream = try streamObject(at: offset, lengthMayBeIndirect: false)
        let dictionary = stream.dictionary
        guard dictionary["Type"]?.name == "XRef" else { throw PDFAppendError.damaged("index pointer does not lead to an index") }
        guard let widths = dictionary["W"]?.array?.map({ $0.int ?? -1 }), widths.count == 3,
              widths.allSatisfy({ $0 >= 0 && $0 <= 8 }) else {
            throw PDFAppendError.damaged("compressed index does not say how wide its fields are")
        }
        let size = try checkedRange(start: 0, count: dictionary["Size"]?.int).count
        var ranges = [(start: 0, count: size)]
        if let declared = dictionary["Index"] {
            guard let numbers = declared.array?.map({ $0.int }), numbers.count % 2 == 0 else {
                throw PDFAppendError.damaged("compressed index has an unreadable range list")
            }
            ranges = try stride(from: 0, to: numbers.count, by: 2).map { try checkedRange(start: numbers[$0], count: numbers[$0 + 1]) }
        }
        let rowWidth = widths.reduce(0, +)
        let rows = ranges.reduce(0) { $0 + $1.count }
        let data = stream.data
        guard rowWidth > 0, rows <= data.count / rowWidth else {
            throw PDFAppendError.damaged("compressed index is shorter than it declares")
        }
        var position = 0
        /// Reads one big-endian field. Nil when the value does not fit a positive number.
        func field(_ width: Int, fallback: Int) -> Int? {
            if width == 0 { return fallback }
            var number: UInt64 = 0
            for _ in 0..<width {
                number = (number << 8) | UInt64(data[position])
                position += 1
            }
            return Int(exactly: number)
        }
        for range in ranges {
            for k in 0..<range.count {
                guard let kind = field(widths[0], fallback: 1), let second = field(widths[1], fallback: 0),
                      let third = field(widths[2], fallback: 0) else {
                    throw PDFAppendError.damaged("compressed index holds a number too large to be real")
                }
                let entry: Entry
                switch kind {
                case 1:
                    guard third <= 65535 else { throw PDFAppendError.damaged("compressed index holds an impossible version number") }
                    entry = second == 0 ? .placeholder : .offset(second, generation: third)
                case 2:
                    guard second <= PDFStructure.maximumObjectNumber, third <= PDFStructure.maximumObjectNumber else {
                        throw PDFAppendError.damaged("compressed index points into an impossible object pack")
                    }
                    entry = .compressed(stream: second, index: third)
                default:
                    entry = .free
                }
                if found[range.start + k] == nil { found[range.start + k] = entry }
            }
        }
        try checkWithinDeclaredSize(found, size: size)
        return (found, dictionary, true)
    }

    /// An index must not list objects at or beyond the size it declares. Readers repair such a
    /// file on opening; appending an update that declares a larger size would stop that repair.
    private func checkWithinDeclaredSize(_ entries: [Int: Entry], size: Int?) throws {
        guard let size, size >= 0, size <= PDFStructure.maximumObjectNumber + 1 else {
            throw PDFAppendError.damaged("index does not declare a usable size")
        }
        for (number, entry) in entries where entry.isLive && number >= size {
            throw PDFAppendError.damaged("index lists objects beyond the size it declares")
        }
    }

    /// Entries that say "inside pack N" were written when N was a particular pack. If a later save
    /// put something else under the same number, or removed it, those entries now point into the
    /// wrong object, and readers disagree on what happens next.
    private func checkObjectPacksWereNotReplaced() throws {
        var packs = Set<Int>()
        for entry in entries.values {
            if case .compressed(let stream, _) = entry { packs.insert(stream) }
        }
        for pack in packs {
            guard case .offset? = entries[pack] else {
                // Never there, deleted, or itself claimed to be inside a pack.
                guard contested.contains(pack) else { throw PDFAppendError.damaged("object pack is missing from the index") }
                throw PDFAppendError.damaged("an object pack was replaced or removed by a later save")
            }
            guard versions[pack]?.count == 1 else {
                throw PDFAppendError.damaged("an object pack was replaced or removed by a later save")
            }
        }
    }

    // MARK: Objects

    /// Reads "N G obj << … >> stream … endstream" at a byte offset and returns the decoded data.
    private func streamObject(at offset: Int, lengthMayBeIndirect: Bool) throws -> (number: Int, dictionary: PDFValue, data: [UInt8]) {
        guard offset >= 0, offset < bytes.count else { throw PDFAppendError.damaged("object position lies outside the file") }
        var parser = PDFParser(bytes, at: PDFStructure.skippingBlanks(bytes, from: offset))
        guard let number = parser.unsignedInteger(), parser.unsignedInteger() != nil else { throw PDFAppendError.damaged("expected an object") }
        parser.skipSpace()
        guard parser.matches("obj") else { throw PDFAppendError.damaged("expected an object") }
        parser.index += 3
        let dictionary = try parser.value()
        guard dictionary.entries != nil else { throw PDFAppendError.damaged("expected a data stream") }
        parser.skipSpace()
        guard parser.matches("stream") else { throw PDFAppendError.damaged("expected a data stream") }
        parser.index += 6
        if parser.index < bytes.count && bytes[parser.index] == 13 { parser.index += 1 }
        if parser.index < bytes.count && bytes[parser.index] == 10 { parser.index += 1 }
        let start = parser.index

        var length = dictionary["Length"]?.int
        if length == nil, lengthMayBeIndirect, let declared = dictionary["Length"], let reference = declared.reference {
            // The format forbids keeping a pack's length inside a pack. Insisting on that also rules
            // out a chain of packs each waiting for the next one's length.
            guard case .offset? = entries[reference.number] else {
                throw PDFAppendError.damaged("an object pack's length is not stored as a plain object")
            }
            length = try resolve(declared).int
        }
        guard let length, length >= 0, length <= bytes.count - start else { throw PDFAppendError.damaged("data stream has no usable length") }
        var tail = PDFParser(bytes, at: start + length)
        tail.skipSpace()
        guard tail.matches("endstream") else { throw PDFAppendError.damaged("data stream does not end where it says") }
        var data = Array(bytes[start..<(start + length)])

        var filters: [String] = []
        if let filter = dictionary["Filter"] {
            if let single = filter.name {
                filters = [single]
            } else if let several = filter.array, several.allSatisfy({ $0.name != nil }) {
                filters = several.compactMap { $0.name }
            } else {
                throw PDFAppendError.damaged("data stream names its compression in an unreadable way")
            }
        }
        var parameters: [PDFValue?] = []
        if let declared = dictionary["DecodeParms"] {
            if declared.entries != nil {
                parameters = [declared]
            } else if let several = declared.array {
                parameters = several.map { $0.entries != nil ? $0 : nil }
            }
        }
        for (k, filter) in filters.enumerated() {
            guard filter == "FlateDecode" else { throw PDFAppendError.refused("index uses a compression method this writer does not handle") }
            guard let inflated = inflateCompletely(data) else { throw PDFAppendError.damaged("compressed index does not decompress cleanly") }
            data = inflated
            guard let settings = (k < parameters.count ? parameters[k] : nil), let predictor = settings["Predictor"]?.int, predictor != 1 else { continue }
            let columns = settings["Columns"]?.int ?? 1
            guard columns >= 1, columns <= 4096 else { throw PDFAppendError.damaged("compressed index declares an impossible row width") }
            guard predictor >= 10, (settings["Colors"]?.int ?? 1) == 1, (settings["BitsPerComponent"]?.int ?? 8) == 8,
                  let plain = removePNGPredictor(data, columns: columns) else {
                throw PDFAppendError.refused("index uses a compression setting this writer does not handle")
            }
            data = plain
        }
        return (number, dictionary, data)
    }

    /// Confirms an index entry really points at "number generation obj" and returns a parser placed after it.
    private func header(at offset: Int, number: Int, generation: Int) throws -> PDFParser {
        guard offset >= 0, offset < bytes.count else { throw PDFAppendError.damaged("index points outside the file") }
        // Some writers point at the line break just before the object. Blank space is allowed here,
        // and nothing else: the next thing must be the object's own number.
        var parser = PDFParser(bytes, at: PDFStructure.skippingBlanks(bytes, from: offset))
        guard parser.index < bytes.count, bytes[parser.index] >= 0x30, bytes[parser.index] <= 0x39 else {
            throw PDFAppendError.damaged("index points at the wrong place")
        }
        guard parser.unsignedInteger() == number, parser.unsignedInteger() == generation else {
            throw PDFAppendError.damaged("index points at the wrong object")
        }
        parser.skipSpace()
        guard parser.matches("obj") else { throw PDFAppendError.damaged("index points at the wrong object") }
        parser.index += 3
        return parser
    }

    /// The object with this number, or null when the file has freed it or never had it.
    /// Throws for a contested number: the writer must not build on an object readers disagree about.
    func object(_ number: Int) throws -> PDFValue {
        guard !contested.contains(number) else {
            throw PDFAppendError.damaged("an object this page depends on was deleted or replaced in a way PDF readers read differently")
        }
        if let cached = cache[number] { return cached }
        let value: PDFValue
        switch entries[number] {
        case nil, .free?, .placeholder?:
            value = .null
        case .offset(let offset, let generation)?:
            var parser = try header(at: offset, number: number, generation: generation)
            value = try parser.value()
        case .compressed(let streamNumber, let index)?:
            let pack = try objectStream(streamNumber)
            guard index >= 0, index < pack.table.count, pack.table[index].number == number else {
                throw PDFAppendError.damaged("object pack does not hold the object the index says it does")
            }
            var parser = PDFParser(pack.bytes, at: pack.first + pack.table[index].offset)
            value = try parser.value()
        }
        cache[number] = value
        return value
    }

    /// A stream object's dictionary and its data exactly as stored (still compressed), for copying
    /// it into another file unchanged. Nil when the object is not a stream; streams never live
    /// inside object packs.
    func storedStream(_ number: Int) throws -> (dictionary: PDFValue, data: ArraySlice<UInt8>)? {
        guard !contested.contains(number) else {
            throw PDFAppendError.damaged("an object this page depends on was deleted or replaced in a way PDF readers read differently")
        }
        guard case .offset(let offset, let generation)? = entries[number] else { return nil }
        var parser = try header(at: offset, number: number, generation: generation)
        let dictionary = try parser.value()
        guard dictionary.entries != nil else { return nil }
        parser.skipSpace()
        guard parser.matches("stream") else { return nil }
        parser.index += 6
        if parser.index < bytes.count && bytes[parser.index] == 13 { parser.index += 1 }
        if parser.index < bytes.count && bytes[parser.index] == 10 { parser.index += 1 }
        let start = parser.index
        guard let declared = dictionary["Length"], let length = try resolve(declared).int, length >= 0, length <= bytes.count - start else {
            throw PDFAppendError.damaged("data stream has no usable length")
        }
        var tail = PDFParser(bytes, at: start + length)
        tail.skipSpace()
        guard tail.matches("endstream") else { throw PDFAppendError.damaged("data stream does not end where it says") }
        return (dictionary, bytes[start..<(start + length)])
    }

    private func objectStream(_ number: Int) throws -> (bytes: [UInt8], first: Int, table: [(number: Int, offset: Int)]) {
        if let cached = objectStreams[number] { return cached }
        guard case .offset(let offset, let generation)? = entries[number] else {
            throw PDFAppendError.damaged("object pack is missing from the index")
        }
        _ = try header(at: offset, number: number, generation: generation)
        let stream = try streamObject(at: offset, lengthMayBeIndirect: true)
        guard stream.dictionary["Type"]?.name == "ObjStm", let count = stream.dictionary["N"]?.int, count >= 0,
              count <= PDFStructure.maximumObjectNumber,
              let first = stream.dictionary["First"]?.int, first >= 0, first <= stream.data.count else {
            throw PDFAppendError.damaged("object pack has an unreadable header")
        }
        var parser = PDFParser(stream.data, at: 0)
        var table: [(number: Int, offset: Int)] = []
        for _ in 0..<count {
            guard parser.index <= first, let member = parser.unsignedInteger(), let position = parser.unsignedInteger(),
                  position < stream.data.count - first else {
                throw PDFAppendError.damaged("object pack has an unreadable table of contents")
            }
            table.append((member, position))
        }
        let pack = (bytes: stream.data, first: first, table: table)
        expandedPackBytes += stream.data.count
        guard expandedPackBytes <= inflatedTotalLimit else { throw PDFAppendError.refused("the file's packed objects expand too far") }
        objectStreams[number] = pack
        return pack
    }

    /// Every in-use entry must lead to the object it names. A file that fails this only opens in
    /// readers because they repair it; appending a fresh index would hide the damage from them.
    private func checkEveryEntry() throws {
        for (number, entry) in entries {
            switch entry {
            case .free, .placeholder:
                continue
            case .offset(let offset, let generation):
                _ = try header(at: offset, number: number, generation: generation)
            case .compressed(let streamNumber, let index):
                let pack = try objectStream(streamNumber)
                guard index >= 0, index < pack.table.count, pack.table[index].number == number else {
                    throw PDFAppendError.damaged("object pack does not hold the object the index says it does")
                }
            }
        }
    }

    /// Follows a reference, insisting that it names the object's current version. A reference to an
    /// older version is dead by the format's rules, yet some readers follow it to the new object.
    func resolve(_ value: PDFValue) throws -> PDFValue {
        guard let reference = value.reference else { return value }
        if let entry = entries[reference.number], entry.isLive, entry.generation != reference.generation {
            throw PDFAppendError.damaged("a reference names an outdated version of an object")
        }
        return try object(reference.number)
    }

    // MARK: Document level

    func catalog() throws -> PDFValue {
        guard let root = trailer["Root"], root.reference != nil else { throw PDFAppendError.damaged("trailer does not name the document root") }
        let catalog = try resolve(root)
        guard catalog.entries != nil else { throw PDFAppendError.damaged("document root is missing") }
        return catalog
    }

    /// Why this file must be left alone even though its structure is sound, or nil if it may be annotated.
    func refusalReason() throws -> String? {
        if trailer["Encrypt"] != nil { return "password-protected" }
        let catalog = try catalog()
        var hasSeal = false
        var hasRetiredSeal = false
        // The objects a seal's record can sit in: the seal's own objects if it has any, and the
        // objects that contain it when it is written inline.
        var sealHolders = Set<Int>()
        if let permissions = catalog["Perms"] {
            // /UR and /UR3 are a publisher's "usage rights" seal: it only unlocks extra features in
            // Adobe Reader and says nothing about who wrote the document. Anything else in here
            // (/DocMDP) is a real certification that forbids changes.
            let kinds = try resolve(permissions).entries ?? []
            guard !kinds.isEmpty, kinds.allSatisfy({ $0.key == "UR" || $0.key == "UR3" }) else { return "certified by its author" }
            hasSeal = true
            for holder in [trailer["Root"], permissions] + kinds.map({ Optional($0.value) }) {
                if let number = holder?.reference?.number { sealHolders.insert(number) }
            }
        } else if let root = trailer["Root"]?.reference?.number {
            // A seal that a page edit retired: an earlier version of this very catalog had one, and
            // nothing else. Its records stay in the file's earlier bytes; they are allowed where the
            // seal was kept, and nowhere else. The form must no longer say that signatures exist.
            for earlier in everyVersion(of: root) {
                guard let permissions = earlier["Perms"] else { continue }
                // Only the seal's own objects as they are now are looked into; an outdated or odd one counts as a signature.
                guard let kinds = try? resolve(permissions).entries, !kinds.isEmpty,
                      kinds.allSatisfy({ $0.key == "UR" || $0.key == "UR3" }) else { return "digitally signed" }
                hasRetiredSeal = true
                for holder in [Optional(PDFValue(node: .ref(root, 0), raw: [])), permissions] + kinds.map({ Optional($0.value) }) {
                    if let number = holder?.reference?.number { sealHolders.insert(number) }
                }
            }
        }
        if let form = catalog["AcroForm"] {
            let formValue = try resolve(form)
            var visited = Set<Int>()
            if try containsSignatureField(formValue["Fields"], depth: 0, visited: &visited) { return "digitally signed" }
            // The form's flags say whether signatures exist. With a seal that statement is about the
            // seal itself; without one, believe it.
            let flags = try resolve(formValue["SigFlags"] ?? .null).int ?? 0
            if flags & 1 != 0 && !hasSeal { return "digitally signed" }
        }
        // Every signature records the byte ranges it covers, wherever in the file it is attached.
        // The only such records allowed are the seal's own: those inside the objects that hold the
        // seal, in any saved version of them. One anywhere else is another signature.
        let records = positions(of: "/ByteRange")
        if records.isEmpty { return nil }
        guard hasSeal || hasRetiredSeal else { return "digitally signed" }
        let allowed = sealHolders.flatMap { extentsOfEveryVersion(of: $0) }
        for record in records where !allowed.contains(where: { $0.contains(record) }) { return "digitally signed" }
        return nil
    }

    private func positions(of text: String) -> [Int] {
        let needle = Array(text.utf8)
        guard bytes.count >= needle.count else { return [] }
        var found: [Int] = []
        var i = 0
        let last = bytes.count - needle.count
        while i <= last {
            if bytes[i] == needle[0] {
                var j = 1
                while j < needle.count && bytes[i + j] == needle[j] { j += 1 }
                if j == needle.count { found.append(i) }
            }
            i += 1
        }
        return found
    }

    /// Every saved version of an object that can be read: those stored as plain objects in the file,
    /// and those inside object packs.
    private func everyVersion(of number: Int) -> [PDFValue] {
        let packed = (packedVersions[number] ?? []).compactMap { place -> PDFValue? in
            guard let pack = try? objectStream(place.stream), place.index >= 0, place.index < pack.table.count,
                  pack.table[place.index].number == number else { return nil }
            var parser = PDFParser(pack.bytes, at: pack.first + pack.table[place.index].offset)
            return try? parser.value()
        }
        return packed + plainVersions(of: number)
    }

    private func plainVersions(of number: Int) -> [PDFValue] {
        (versions[number] ?? []).sorted().compactMap { offset in
            guard offset >= 0, offset < bytes.count else { return nil }
            var parser = PDFParser(bytes, at: PDFStructure.skippingBlanks(bytes, from: offset))
            guard parser.unsignedInteger() == number, parser.unsignedInteger() != nil else { return nil }
            parser.skipSpace()
            guard parser.matches("obj") else { return nil }
            parser.index += 3
            return try? parser.value()
        }
    }

    /// The stretch of the file each saved version of an object occupies. A version that cannot be
    /// read is left out, which errs on the side of refusing.
    private func extentsOfEveryVersion(of number: Int) -> [Range<Int>] {
        (versions[number] ?? []).compactMap { offset in
            guard offset >= 0, offset < bytes.count else { return nil }
            var parser = PDFParser(bytes, at: PDFStructure.skippingBlanks(bytes, from: offset))
            guard parser.unsignedInteger() == number, parser.unsignedInteger() != nil else { return nil }
            parser.skipSpace()
            guard parser.matches("obj") else { return nil }
            parser.index += 3
            guard let value = try? parser.value() else { return nil }
            return value.raw.startIndex..<value.raw.endIndex
        }
    }

    /// Whether any form field, at any depth, is a signature field. Each field is looked at once,
    /// however many parents share it, so a tangled form cannot make this take forever.
    private func containsSignatureField(_ fields: PDFValue?, depth: Int, visited: inout Set<Int>) throws -> Bool {
        guard let fields else { return false }
        guard depth < 32 else { throw PDFAppendError.damaged("form fields are nested too deeply to check for signatures") }
        guard let list = try resolve(fields).array else { return false }
        for item in list {
            if let number = item.reference?.number {
                guard visited.insert(number).inserted else { continue }
                guard visited.count <= 20_000 else { throw PDFAppendError.damaged("form has too many fields to check for signatures") }
            }
            let field = try resolve(item)
            if field["FT"]?.name == "Sig" { return true }
            if try containsSignatureField(field["Kids"], depth: depth + 1, visited: &visited) { return true }
        }
        return false
    }

    /// Object numbers of all pages, in reading order, found by walking the whole page tree.
    func pageNumbers() throws -> [Int] {
        if let cached = pageNumbersCache { return cached }
        guard let root = try catalog()["Pages"], root.reference != nil else {
            throw PDFAppendError.damaged("document has no page tree")
        }
        var pages: [Int] = []
        var visited = Set<Int>()
        func walk(_ reference: PDFValue, depth: Int) throws {
            guard let number = reference.reference?.number else { throw PDFAppendError.damaged("page tree child is not a reference") }
            guard depth < 64, visited.insert(number).inserted else { throw PDFAppendError.damaged("page tree loops back on itself") }
            let node = try resolve(reference)
            guard node.entries != nil else { throw PDFAppendError.damaged("page tree refers to something that is not there") }
            if let kidsValue = node["Kids"] {
                guard let kids = try resolve(kidsValue).array else { throw PDFAppendError.damaged("page tree children are not a list") }
                let before = pages.count
                for kid in kids { try walk(kid, depth: depth + 1) }
                // Every branch must count exactly the pages under it. Readers that trust a branch's
                // count to find a page would otherwise number the pages differently from this walk,
                // and a mark would be written on another page than the one it was made on.
                guard let declared = node["Count"], try resolve(declared).int == pages.count - before else {
                    throw PDFAppendError.damaged("page tree miscounts its pages")
                }
            } else {
                if let type = node["Type"]?.name, type != "Page" { throw PDFAppendError.damaged("page tree ends in something that is not a page") }
                pages.append(number)
            }
        }
        try walk(root, depth: 0)
        pageNumbersCache = pages
        return pages
    }
}
