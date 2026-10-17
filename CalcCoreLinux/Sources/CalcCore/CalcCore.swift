// Portable Calculator engine — Foundation only (no Combine / AppKit / SwiftUI).
// Shares the algorithms used by the macOS app's Engines.swift, so it compiles on
// Linux as well as macOS. Build on Linux with the Swift Static Linux SDK.
import Foundation

// MARK: - Number formatting (no NumberFormatter, for cross-platform determinism)
public enum Num {
    public static func fmt(_ n: Double) -> String {
        if n.isNaN { return "Invalid input" }
        if n.isInfinite { return "Overflow" }
        if n == 0 { return "0" }
        let a = abs(n)
        if a < 1e-9 || a >= 1e16 { return String(format: "%.9g", n) }
        var s = String(format: "%.12f", n)
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        var neg = false
        if s.hasPrefix("-") { neg = true; s.removeFirst() }
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = String(parts[0]); let frac = parts.count > 1 ? String(parts[1]) : nil
        var grouped = ""; var c = 0
        for ch in intPart.reversed() { if c > 0 && c % 3 == 0 { grouped.append(",") }; grouped.append(ch); c += 1 }
        let ip = String(grouped.reversed())
        return (neg ? "-" : "") + ip + (frac != nil ? "." + frac! : "")
    }
}

// MARK: - Scientific / graphing expression evaluator (recursive descent)
public enum GraphExpr {
    public static func eval(_ src: String, x: Double) -> Double? {
        let toks = tokenize(src); var pos = 0
        func peek() -> String? { pos < toks.count ? toks[pos] : nil }
        func adv() -> String? { let t = peek(); if t != nil { pos += 1 }; return t }
        func atom() -> Double? {
            guard let t = adv() else { return nil }
            if t == "(" { let v = expr(); if peek() == ")" { _ = adv() }; return v }
            if let d = Double(t) { return d }
            if t == "x" { return x }
            if t == "pi" || t == "π" { return Double.pi }
            if t == "e" { return M_E }
            if peek() == "(" { _ = adv(); let a = expr() ?? .nan; if peek() == ")" { _ = adv() }; return apply(t, a) }
            return nil
        }
        func power() -> Double? { guard let b = atom() else { return nil }; if peek() == "^" { _ = adv(); guard let e = unary() else { return nil }; return pow(b, e) }; return b }
        func unary() -> Double? { if peek() == "-" { _ = adv(); return unary().map { -$0 } }; if peek() == "+" { _ = adv(); return unary() }; return power() }
        func term() -> Double? { guard var v = unary() else { return nil }; while let t = peek(), t == "*" || t == "/" { _ = adv(); guard let r = unary() else { return nil }; v = t == "*" ? v * r : v / r }; return v }
        func expr() -> Double? { guard var v = term() else { return nil }; while let t = peek(), t == "+" || t == "-" { _ = adv(); guard let r = term() else { return nil }; v = t == "+" ? v + r : v - r }; return v }
        return expr()
    }
    static func apply(_ f: String, _ a: Double) -> Double {
        switch f {
        case "sin": return sin(a); case "cos": return cos(a); case "tan": return tan(a)
        case "asin": return asin(a); case "acos": return acos(a); case "atan": return atan(a)
        case "sinh": return sinh(a); case "cosh": return cosh(a); case "tanh": return tanh(a)
        case "log": return log10(a); case "ln": return log(a); case "sqrt": return sqrt(a)
        case "cbrt": return cbrt(a); case "abs": return abs(a); case "exp": return exp(a)
        default: return .nan
        }
    }
    static func tokenize(_ s: String) -> [String] {
        var toks: [String] = []; let chars = Array(s.lowercased()); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " { i += 1; continue }
            if c.isNumber || c == "." { var n = ""; while i < chars.count, chars[i].isNumber || chars[i] == "." { n.append(chars[i]); i += 1 }; toks.append(n); continue }
            if c.isLetter || c == "π" { var id = ""; while i < chars.count, chars[i].isLetter || chars[i] == "π" { id.append(chars[i]); i += 1 }; toks.append(id); continue }
            toks.append(String(c)); i += 1
        }
        return toks
    }
}

// MARK: - Programmer (word-size aware, two's complement)
public struct Prog {
    public var wordBits: Int
    public init(wordBits: Int = 64) { self.wordBits = max(1, min(64, wordBits)) }
    public var mask: UInt64 { wordBits >= 64 ? ~0 : (UInt64(1) << UInt64(wordBits)) - 1 }
    public func u(_ x: UInt64) -> UInt64 { x & mask }
    public func signed(_ x: UInt64) -> Int64 {
        let m = mask; let v = x & m
        let signBit = UInt64(1) << UInt64(wordBits - 1)
        return (v & signBit) != 0 ? Int64(bitPattern: v | ~m) : Int64(bitPattern: v)
    }
    private func groupBin(_ s: String) -> String {
        var str = s; let pad = (4 - str.count % 4) % 4
        str = String(repeating: "0", count: pad) + str
        var out = ""; var i = 0
        for ch in str { if i != 0 && i % 4 == 0 { out += " " }; out.append(ch); i += 1 }
        return out.isEmpty ? "0" : out
    }
    public func format(_ x: UInt64, base: Int) -> String {
        let un = u(x)
        switch base {
        case 16: return String(un, radix: 16, uppercase: true)
        case 10: return String(signed(x))
        case 8: return String(un, radix: 8)
        default: return groupBin(String(un, radix: 2))
        }
    }
    public func apply(_ a0: UInt64, _ b0: UInt64, _ op: String) -> UInt64 {
        let a = u(a0), b = u(b0), w = UInt64(wordBits)
        switch op {
        case "+": return u(a &+ b); case "-": return u(a &- b); case "*": return u(a &* b)
        case "/": return b == 0 ? 0 : u(UInt64(bitPattern: signed(a) / signed(b)))
        case "mod": return b == 0 ? 0 : u(UInt64(bitPattern: signed(a) % signed(b)))
        case "and": return a & b; case "or": return a | b; case "xor": return a ^ b
        case "nand": return u(~(a & b)); case "nor": return u(~(a | b))
        case "lsh": return u(a << (b % w)); case "rsh": return u(a >> (b % w))
        case "rol": let s = b % w; return s == 0 ? a : u((a << s) | (a >> (w - s)))
        case "ror": let s = b % w; return s == 0 ? a : u((a >> s) | (a << (w - s)))
        default: return b
        }
    }
}

// MARK: - Unit conversion (subset of the app's 12 categories)
public enum Convert {
    public static let categories: [String: [(String, Double)]] = [
        "Length": [("nm", 1e-9), ("mm", 1e-3), ("cm", 1e-2), ("m", 1), ("km", 1e3), ("inch", 0.0254), ("foot", 0.3048), ("yard", 0.9144), ("mile", 1609.344)],
        "Mass": [("mg", 1e-6), ("g", 1e-3), ("kg", 1), ("tonne", 1000), ("oz", 0.0283495), ("lb", 0.453592), ("stone", 6.35029)],
        "Data": [("bit", 0.125), ("byte", 1), ("kb", 1000), ("kib", 1024), ("mb", 1e6), ("mib", 1048576), ("gb", 1e9), ("gib", 1073741824)],
        "Time": [("ms", 1e-3), ("s", 1), ("min", 60), ("hour", 3600), ("day", 86400), ("week", 604800)],
    ]
    public static func tempConvert(_ v: Double, _ from: String, _ to: String) -> Double? {
        let f = from.lowercased(), t = to.lowercased()
        func toC(_ x: Double, _ u: String) -> Double? { u == "c" || u == "celsius" ? x : u == "f" || u == "fahrenheit" ? (x - 32) * 5 / 9 : u == "k" || u == "kelvin" ? x - 273.15 : nil }
        func fromC(_ c: Double, _ u: String) -> Double? { u == "c" || u == "celsius" ? c : u == "f" || u == "fahrenheit" ? c * 9 / 5 + 32 : u == "k" || u == "kelvin" ? c + 273.15 : nil }
        guard let c = toC(v, f), let r = fromC(c, t) else { return nil }
        return r
    }
    public static func convert(_ v: Double, from: String, to: String) -> Double? {
        if let r = tempConvert(v, from, to) { return r }
        let fl = from.lowercased(), tl = to.lowercased()
        for (_, units) in categories {
            if let f = units.first(where: { $0.0 == fl }), let t = units.first(where: { $0.0 == tl }) {
                return v * f.1 / t.1
            }
        }
        return nil
    }
}
