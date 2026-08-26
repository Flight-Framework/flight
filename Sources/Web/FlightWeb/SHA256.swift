import Foundation

/// SHA-256 (FIPS 180-4), incremental. Hand-rolled deliberately: this
/// module's only cryptographic need is a *content checksum* for cache
/// validators — not key material, not signatures — and the alternative is
/// handing every Flight application a dependency that vendors BoringSSL
/// into its build for what is, here, a pure function with published test
/// vectors. The vectors (empty, "abc", the two-block message, a million
/// "a"s) are pinned in the test suite; if real cryptography ever joins
/// FlightWeb, swift-crypto replaces this and the tests keep passing.
struct SHA256 {
    private var state: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19
    )
    private var pending = [UInt8]()
    private var totalBytes: UInt64 = 0

    init() {
        pending.reserveCapacity(64)
    }

    mutating func update(_ data: Data) {
        totalBytes &+= UInt64(data.count)
        var input = ArraySlice<UInt8>(data)
        if !pending.isEmpty {
            let needed = 64 - pending.count
            let take = Swift.min(needed, input.count)
            pending.append(contentsOf: input.prefix(take))
            input = input.dropFirst(take)
            if pending.count == 64 {
                pending.withUnsafeBufferPointer { compress($0.baseAddress!) }
                pending.removeAll(keepingCapacity: true)
            } else {
                return
            }
        }
        while input.count >= 64 {
            let block = input.prefix(64)
            block.withUnsafeBufferPointer { compress($0.baseAddress!) }
            input = input.dropFirst(64)
        }
        pending.append(contentsOf: input)
    }

    /// Consumes the hasher; the 64-hex-character digest.
    consuming func hexDigest() -> String {
        let bitLength = totalBytes &* 8
        var tail: [UInt8] = [0x80]
        let remainder = (totalBytes &+ 1) % 64
        tail.append(contentsOf: repeatElement(0, count: Int((64 &+ 56 &- remainder) % 64)))
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        update(Data(tail))
        precondition(pending.isEmpty, "padding must end exactly on a block boundary")

        var hex = ""
        hex.reserveCapacity(64)
        for word in [state.0, state.1, state.2, state.3, state.4, state.5, state.6, state.7] {
            hex += String(format: "%08x", word)
        }
        return hex
    }

    /// One-shot convenience.
    static func hexDigest(of data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data)
        return hasher.hexDigest()
    }

    // MARK: - Compression

    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
        0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
        0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
        0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
        0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    private mutating func compress(_ block: UnsafePointer<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        for t in 0..<16 {
            w[t] =
                UInt32(block[t * 4]) << 24 | UInt32(block[t * 4 + 1]) << 16
                | UInt32(block[t * 4 + 2]) << 8 | UInt32(block[t * 4 + 3])
        }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }

        var (a, b, c, d, e, f, g, h) = state
        for t in 0..<64 {
            let sigma1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ sigma1 &+ choose &+ Self.k[t] &+ w[t]
            let sigma0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = sigma0 &+ majority
            (h, g, f, e, d, c, b, a) = (g, f, e, d &+ temp1, c, b, a, temp1 &+ temp2)
        }
        state = (
            state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d,
            state.4 &+ e, state.5 &+ f, state.6 &+ g, state.7 &+ h
        )
    }

    private func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
