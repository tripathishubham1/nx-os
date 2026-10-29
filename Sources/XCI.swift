// Reads a game card dump's title ID from inside it, so a dropped XCI / XCZ needs no "[0100…]" in
// its name. The card's root HFS0 holds a "secure" HFS0 of NCAs (NCZs in an XCZ, whose header stays
// plain); each NCA header is AES-XTS encrypted with the console's header_key from prod.keys, and
// its program ID at 0x210 is the title ID.
import Foundation
import CommonCrypto

enum XCI {
    static func titleID(_ url: URL, keys: String?) -> String? {
        guard let keys, let headerKey = headerKey(keys), let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        func read(_ at: UInt64, _ n: Int) -> Data? {
            guard (try? h.seek(toOffset: at)) != nil, let d = try? h.read(upToCount: n), d.count == n else { return nil }
            return d
        }
        guard let head = read(0, 0x200), head[0x100..<0x104] == Data("HEAD".utf8) else { return nil }
        let root = head.u64(0x130)
        guard let secure = hfs0(read, at: root)?.first(where: { $0.name == "secure" }),
              let ncas = hfs0(read, at: secure.offset) else { return nil }
        var ids: [UInt64: Int] = [:]
        for f in ncas where f.name.hasSuffix(".nca") || f.name.hasSuffix(".ncz") {
            guard let enc = read(f.offset + 0x200, 0x200), let sector = xtsDecrypt(enc, key: headerKey, sector: 1),
                  sector[0..<4] == Data("NCA3".utf8) else { continue }
            ids[sector.u64(0x10), default: 0] += 1   // 0x210 of the header, 0x10 into its second sector
        }
        // a base game's NCAs all carry its ID; prefer one ending in 000 should a card hold more
        guard let id = ids.keys.sorted(by: { ($0 & 0xFFF == 0 ? 1 : 0, ids[$0]!) > ($1 & 0xFFF == 0 ? 1 : 0, ids[$1]!) }).first else { return nil }
        return String(format: "%016llX", id)
    }

    /// The files of the HFS0 at `at`, with absolute offsets.
    private static func hfs0(_ read: (UInt64, Int) -> Data?, at: UInt64) -> [(name: String, offset: UInt64)]? {
        guard let h = read(at, 0x10), h[0..<4] == Data("HFS0".utf8) else { return nil }
        let count = Int(h.u32(4)), strings = Int(h.u32(8))
        guard count < 4096, let table = read(at + 0x10, count * 0x40 + strings) else { return nil }
        let data = at + 0x10 + UInt64(table.count)
        return (0..<count).map { i in
            let e = i * 0x40, nameAt = count * 0x40 + Int(table.u32(e + 0x10))
            let end = table[nameAt...].firstIndex(of: 0) ?? table.endIndex
            return (String(decoding: table[nameAt..<end], as: UTF8.self), data + table.u64(e))
        }
    }

    private static func headerKey(_ keysPath: String) -> Data? {
        guard let text = try? String(contentsOfFile: keysPath, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("header_key") }),
              let hex = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces), hex.count == 64 else { return nil }
        return Data(hex: hex)
    }

    /// One 0x200 sector of Nintendo's AES-128-XTS: the tweak is the sector number, big-endian.
    private static func xtsDecrypt(_ data: Data, key: Data, sector: UInt64) -> Data? {
        var tweak = Data(count: 16)
        withUnsafeBytes(of: sector.bigEndian) { tweak.replaceSubrange(8..<16, with: $0) }
        guard var t = aes(tweak, key: key[16..<32], encrypt: true) else { return nil }
        var out = Data()
        for b in stride(from: 0, to: data.count, by: 16) {
            let x = Data(zip(data[data.startIndex + b ..< data.startIndex + b + 16], t).map { $0 ^ $1 })
            guard let y = aes(x, key: key[0..<16], encrypt: false) else { return nil }
            out.append(Data(zip(y, t).map { $0 ^ $1 }))
            var carry: UInt8 = 0   // multiply the tweak by x in GF(2^128), little-endian
            for i in 0..<16 { let c = t[i] >> 7; t[i] = t[i] << 1 | carry; carry = c }
            if carry != 0 { t[0] ^= 0x87 }
        }
        return out
    }

    private static func aes(_ block: Data, key: Data, encrypt: Bool) -> Data? {
        var out = Data(count: 16), moved = 0
        let key = Data(key), block = Data(block)
        let status = out.withUnsafeMutableBytes { o in block.withUnsafeBytes { i in key.withUnsafeBytes { k in
            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    k.baseAddress, 16, nil, i.baseAddress, 16, o.baseAddress, 16, &moved)
        } } }
        return status == kCCSuccess ? out : nil
    }
}

private extension Data {
    func u32(_ at: Int) -> UInt32 { self[startIndex + at ..< startIndex + at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    func u64(_ at: Int) -> UInt64 { self[startIndex + at ..< startIndex + at + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }
    init?(hex: String) {
        var d = Data(), i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        self = d
    }
}
