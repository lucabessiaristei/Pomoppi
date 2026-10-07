// QRReedSolomon.swift — Reed-Solomon error correction for the QR decoder:
// syndromes, Berlekamp-Massey, Chien search, Forney. GF(256) tables and the
// generator roots (alpha^0 ...) are the encoder's own (QREncoder.swift).
import Foundation

extension QRCode {
    private static func gfPower(_ exponent: Int) -> UInt8 {
        gfTables.exp[((exponent % 255) + 255) % 255]
    }

    private static func gfDivide(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 { return 0 }
        return gfTables.exp[gfTables.log[Int(a)] + 255 - gfTables.log[Int(b)]]
    }

    // Corrects `block` (data then EC codewords) in place. False when it holds
    // more than ecCount / 2 wrong codewords (or the fix doesn't verify).
    static func reedSolomonCorrect(_ block: inout [UInt8], ecCount: Int) -> Bool {
        let n = block.count
        func syndromes(of block: [UInt8]) -> [UInt8] {
            (0..<ecCount).map { j in
                let root = gfPower(j)
                var s: UInt8 = 0
                for c in block { s = gfMultiply(s, root) ^ c }
                return s
            }
        }
        let syn = syndromes(of: block)
        if !syn.contains(where: { $0 != 0 }) { return true }

        // Berlekamp-Massey: error locator, lowest degree first.
        var lambda: [UInt8] = [1]
        var previous: [UInt8] = [1]
        var l = 0, shift = 1
        var previousDiscrepancy: UInt8 = 1
        for i in 0..<ecCount {
            var d = syn[i]
            for k in stride(from: 1, to: min(lambda.count, i + 1), by: 1) { d ^= gfMultiply(lambda[k], syn[i - k]) }
            if d == 0 {
                shift += 1
                continue
            }
            let saved = lambda
            let factor = gfDivide(d, previousDiscrepancy)
            if lambda.count < previous.count + shift {
                lambda += [UInt8](repeating: 0, count: previous.count + shift - lambda.count)
            }
            for (k, p) in previous.enumerated() { lambda[k + shift] ^= gfMultiply(factor, p) }
            if 2 * l <= i {
                l = i + 1 - l
                previous = saved
                previousDiscrepancy = d
                shift = 1
            } else {
                shift += 1
            }
        }
        while lambda.count > 1, lambda.last == 0 { lambda.removeLast() }
        guard l > 0, l * 2 <= ecCount, lambda.count == l + 1 else { return false }

        // Chien search: codeword i has locator X = alpha^(n-1-i).
        var positions: [Int] = []
        for i in 0..<n {
            let xInverse = gfPower(-(n - 1 - i))
            var sum: UInt8 = 0, power: UInt8 = 1
            for c in lambda {
                sum ^= gfMultiply(c, power)
                power = gfMultiply(power, xInverse)
            }
            if sum == 0 { positions.append(i) }
        }
        guard positions.count == l else { return false }

        // Forney: omega = syn * lambda mod x^ecCount; magnitude = X * omega(1/X) / lambda'(1/X).
        var omega = [UInt8](repeating: 0, count: ecCount)
        for k in 0..<ecCount {
            for i in 0...min(k, lambda.count - 1) { omega[k] ^= gfMultiply(lambda[i], syn[k - i]) }
        }
        for i in positions {
            let x = gfPower(n - 1 - i), xInverse = gfPower(-(n - 1 - i))
            var numerator: UInt8 = 0, power: UInt8 = 1
            for c in omega {
                numerator ^= gfMultiply(c, power)
                power = gfMultiply(power, xInverse)
            }
            var denominator: UInt8 = 0
            power = 1
            for k in stride(from: 1, to: lambda.count, by: 2) {
                denominator ^= gfMultiply(lambda[k], power)
                power = gfMultiply(power, gfMultiply(xInverse, xInverse))
            }
            guard denominator != 0 else { return false }
            block[i] ^= gfMultiply(x, gfDivide(numerator, denominator))
        }
        return !syndromes(of: block).contains { $0 != 0 }
    }
}
