import Foundation
import Combine

// MARK: - Shared formatting
enum Num {
    static func fmt(_ n: Double) -> String {
        if n.isNaN { return "Invalid input" }
        if n.isInfinite { return "Overflow" }
        if n == 0 { return "0" }
        let a = abs(n)
        if a < 1e-9 || a >= 1e16 {
            var s = String(format: "%.9e", n)
            // tidy exponent like 1.5e+20
            s = s.replacingOccurrences(of: "e", with: "e")
            return s
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        f.maximumFractionDigits = 12
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    static func group(_ typed: String) -> String {
        let neg = typed.hasPrefix("-")
        var t = neg ? String(typed.dropFirst()) : typed
        let parts = t.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var intPart = String(parts.first ?? "")
        let frac = parts.count > 1 ? String(parts[1]) : nil
        // insert thousands separators
        if let v = Int(intPart) {
            let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
            intPart = f.string(from: NSNumber(value: v)) ?? intPart
        }
        t = intPart + (typed.contains(".") ? "." + (frac ?? "") : "")
        return (neg ? "-" : "") + t
    }
}

struct HistoryItem: Identifiable, Hashable {
    let id = UUID()
    let expr: String
    let result: String
}

// MARK: - Standard (immediate execution)
final class StandardVM: ObservableObject {
    @Published var display = "0"
    @Published var expression = ""
    private var first: Double? = nil
    private var op: Character? = nil
    private var waiting = false
    private var lastOp: Character? = nil
    private var lastArg: Double = 0
    private var typing = false
    var history: ((String, String) -> Void)?
    var memoryGet: (() -> Double)?

    var value: Double { Double(display.replacingOccurrences(of: ",", with: "")) ?? 0 }
    private func show() { display = Num.group(display) }

    func digit(_ d: String) {
        if waiting || !typing { display = (d == ".") ? "0." : d; waiting = false; typing = true }
        else if d == "." { if !display.contains(".") { display += "." } }
        else { display = (display == "0") ? d : display + d }
        let plain = display.replacingOccurrences(of: ",", with: "")
        display = Num.group(plain)
    }
    private func sym(_ o: Character) -> String { ["+":"+","-":"−","*":"×","/":"÷"][o] ?? String(o) }
    private func apply(_ a: Double, _ b: Double, _ o: Character) -> Double {
        switch o { case "+": return a+b; case "-": return a-b; case "*": return a*b; case "/": return b == 0 ? .nan : a/b; default: return b }
    }
    func setOp(_ o: Character) {
        let cur = value
        if op != nil && !waiting { first = apply(first ?? 0, cur, op!); display = Num.fmt(first!) }
        else { first = cur }
        op = o; waiting = true; typing = false; lastOp = nil
        expression = Num.fmt(first ?? 0) + " " + sym(o)
    }
    func equals() {
        let cur = value
        if let o = op, let f = first {
            lastOp = o; lastArg = cur
            let r = apply(f, cur, o)
            expression = Num.fmt(f) + " " + sym(o) + " " + Num.fmt(cur) + " ="
            history?(expression, Num.fmt(r))
            display = Num.fmt(r); first = nil; op = nil; waiting = true; typing = false
        } else if let lo = lastOp {
            let r = apply(cur, lastArg, lo)
            expression = Num.fmt(cur) + " " + sym(lo) + " " + Num.fmt(lastArg) + " ="
            history?(expression, Num.fmt(r))
            display = Num.fmt(r); waiting = true; typing = false
        }
    }
    func unary(_ kind: String) {
        let x = value
        switch kind {
        case "neg":
            if display.hasPrefix("-") { display.removeFirst() } else if display != "0" { display = "-" + display }
            return
        case "sqrt": display = Num.fmt(x < 0 ? .nan : x.squareRoot()); expression = "√(\(Num.fmt(x)))"
        case "sqr": display = Num.fmt(x*x); expression = "sqr(\(Num.fmt(x)))"
        case "recip": display = Num.fmt(x == 0 ? .nan : 1/x); expression = "1/(\(Num.fmt(x)))"
        case "pct":
            var r = 0.0
            if op == "+" || op == "-" { r = (first ?? 0) * x / 100 }
            else if op == "*" || op == "/" { r = x/100 }
            display = Num.fmt(r); return
        default: break
        }
        waiting = true; typing = false
    }
    func clearAll() { first = nil; op = nil; lastOp = nil; expression = ""; display = "0"; waiting = false; typing = false }
    func clearEntry() { display = "0"; typing = false }
    func backspace() {
        if waiting || !typing { return }
        let plain = display.replacingOccurrences(of: ",", with: "")
        var s = plain
        if s.count <= 1 || (s.count == 2 && s.hasPrefix("-")) { s = "0"; typing = false }
        else { s.removeLast() }
        display = Num.group(s)
    }
    func setValue(_ v: Double) { display = Num.fmt(v); waiting = true; typing = false }
}

// MARK: - Scientific (expression parser)
final class ScientificVM: ObservableObject {
    enum Tok { case num(String); case op(Character); case fn(String); case k(String); case lp; case rp; case fact; case pct; case mod }
    @Published var display = "0"
    @Published var expression = ""
    @Published var angle = "DEG"
    @Published var second = false
    @Published var hyp = false
    private var tokens: [Tok] = []
    private var editing = false
    private var shown = false
    private var resultRaw = 0.0
    var history: ((String, String) -> Void)?

    private func disp(_ t: Tok) -> String {
        switch t {
        case .num(let v): return v
        case .op(let c): return " " + (["+":"+","-":"−","*":"×","/":"÷","^":"^"][c] ?? String(c)) + " "
        case .fn(let n):
            let lbl = ["sin":"sin","cos":"cos","tan":"tan","asin":"sin⁻¹","acos":"cos⁻¹","atan":"tan⁻¹","log":"log","ln":"ln","sqrt":"√","cbrt":"∛","abs":"abs","exp":"exp"][n] ?? n
            return lbl + "("
        case .k(let c): return c == "pi" ? "π" : "e"
        case .lp: return "("
        case .rp: return ")"
        case .fact: return "!"
        case .pct: return "%"
        case .mod: return " mod "
        }
    }
    private func render() {
        if shown { return }
        let s = tokens.map { disp($0) }.joined()
        display = s.isEmpty ? "0" : s
        expression = ""
    }
    private func resetIfShown() { if shown { tokens = []; shown = false; editing = false } }

    func digit(_ d: String) {
        resetIfShown()
        if editing, case .num(let v)? = tokens.last {
            if d == "." && v.contains(".") { return }
            tokens[tokens.count-1] = .num(v + d)
        } else {
            tokens.append(.num(d == "." ? "0." : d)); editing = true
        }
        render()
    }
    func op(_ c: Character) {
        editing = false
        if shown { tokens = [.num(String(resultRaw))]; shown = false }
        tokens.append(.op(c)); render()
    }
    func fn(_ name: String) {
        editing = false; resetIfShown()
        if name == "tfx" { tokens.append(.num("10")); tokens.append(.op("^")); render(); return }
        tokens.append(.fn(name)); tokens.append(.lp); render()
    }
    func konst(_ c: String) { editing = false; resetIfShown(); tokens.append(.k(c)); render() }
    func paren(_ left: Bool) { editing = false; tokens.append(left ? .lp : .rp); render() }
    func postfix(_ fact: Bool) { editing = false; tokens.append(fact ? .fact : .pct); render() }
    func mod() { editing = false; tokens.append(.mod); render() }
    func neg() {
        if case .num(let v)? = tokens.last {
            tokens[tokens.count-1] = .num(v.hasPrefix("-") ? String(v.dropFirst()) : "-" + v); render()
        }
    }
    func backspace() {
        if shown { return }
        guard let last = tokens.last else { return }
        if case .num(let v) = last, v.count > 1 { tokens[tokens.count-1] = .num(String(v.dropLast())) }
        else { tokens.removeLast() }
        if tokens.isEmpty { editing = false }
        render()
    }
    func clear() { tokens = []; editing = false; shown = false; display = "0"; expression = "" }

    func equals() {
        if tokens.isEmpty { return }
        let v = (try? eval(tokens)) ?? .nan
        let line = tokens.map { disp($0) }.joined() + " ="
        expression = line
        display = Num.fmt(v)
        resultRaw = v
        shown = true
        history?(line, Num.fmt(v))
    }
    func setValue(_ v: Double) { tokens = [.num(String(v))]; shown = false; editing = false; render() }

    // recursive descent
    private var pos = 0
    private func toRad(_ x: Double) -> Double { angle == "DEG" ? x * .pi/180 : angle == "GRAD" ? x * .pi/200 : x }
    private func fromRad(_ x: Double) -> Double { angle == "DEG" ? x * 180/(.pi) : angle == "GRAD" ? x * 200/(.pi) : x }
    private func eval(_ tk: [Tok]) throws -> Double {
        pos = 0; toks = tk
        let v = try pExpr()
        return v
    }
    private var toks: [Tok] = []
    private func peek() -> Tok? { pos < toks.count ? toks[pos] : nil }
    private func next() -> Tok? { let t = peek(); if t != nil { pos += 1 }; return t }
    enum PErr: Error { case bad }
    private func pExpr() throws -> Double {
        var v = try pTerm()
        while case .op(let c)? = peek(), c == "+" || c == "-" { _ = next(); let r = try pTerm(); v = c == "+" ? v+r : v-r }
        return v
    }
    private func pTerm() throws -> Double {
        var v = try pUnary()
        loop: while let t = peek() {
            switch t {
            case .op(let c) where c == "*" || c == "/": _ = next(); let r = try pUnary(); v = c == "*" ? v*r : v/r
            case .mod: _ = next(); let r = try pUnary(); v = v.truncatingRemainder(dividingBy: r)
            default: break loop
            }
        }
        return v
    }
    private func pUnary() throws -> Double {
        if case .op(let c)? = peek(), c == "-" { _ = next(); return try -pUnary() }
        return try pPow()
    }
    private func pPow() throws -> Double {
        let b = try pPost()
        if case .op(let c)? = peek(), c == "^" { _ = next(); let e = try pUnary(); return pow(b, e) }
        return b
    }
    private func pPost() throws -> Double {
        var v = try pPrim()
        while let t = peek() {
            if case .fact = t { _ = next(); v = factorial(v) }
            else if case .pct = t { _ = next(); v = v/100 }
            else { break }
        }
        return v
    }
    private func pPrim() throws -> Double {
        guard let t = peek() else { throw PErr.bad }
        switch t {
        case .num(let v): _ = next(); return Double(v) ?? .nan
        case .k(let c): _ = next(); return c == "pi" ? .pi : M_E
        case .lp: _ = next(); let v = try pExpr(); if case .rp? = peek() { _ = next() }; return v
        case .fn(let name): _ = next(); if case .lp? = peek() { _ = next() }; let a = try pExpr(); if case .rp? = peek() { _ = next() }; return applyFn(name, a)
        case .op(let c) where c == "-": _ = next(); return try -pPrim()
        default: throw PErr.bad
        }
    }
    private func applyFn(_ n: String, _ a: Double) -> Double {
        switch n {
        case "sin": return sin(toRad(a)); case "cos": return cos(toRad(a)); case "tan": return tan(toRad(a))
        case "asin": return fromRad(asin(a)); case "acos": return fromRad(acos(a)); case "atan": return fromRad(atan(a))
        case "sinh": return sinh(a); case "cosh": return cosh(a); case "tanh": return tanh(a)
        case "asinh": return asinh(a); case "acosh": return acosh(a); case "atanh": return atanh(a)
        case "log": return log10(a); case "ln": return log(a); case "sqrt": return sqrt(a); case "cbrt": return cbrt(a)
        case "abs": return abs(a); case "exp": return exp(a); default: return a
        }
    }
    private func factorial(_ n: Double) -> Double {
        if n < 0 || n.rounded() != n { return .nan }
        if n > 170 { return .infinity }
        var r = 1.0; var i = 2.0; while i <= n { r *= i; i += 1 }; return r
    }
}

// MARK: - Programmer (word-size aware)
final class ProgrammerVM: ObservableObject {
    enum Base: String, CaseIterable { case hex, dec, oct, bin }
    @Published var base: Base = .dec
    @Published var wordBits = 64            // 64/32/16/8 → QWORD/DWORD/WORD/BYTE
    @Published var display = "0"
    @Published var expression = ""
    @Published var hexStr = "0"
    @Published var decStr = "0"
    @Published var octStr = "0"
    @Published var binStr = "0"
    @Published var bits: [Int] = Array(repeating: 0, count: 64)   // MSB-first
    private var cur: UInt64 = 0
    private var acc: UInt64? = nil
    private var op: String? = nil
    private var waiting = false

    private var mask: UInt64 { wordBits >= 64 ? ~0 : (UInt64(1) << UInt64(wordBits)) - 1 }
    private func u(_ x: UInt64) -> UInt64 { x & mask }
    private func signed(_ x: UInt64) -> Int64 {
        let m = mask; let v = x & m
        let signBit = UInt64(1) << UInt64(wordBits - 1)
        return (v & signBit) != 0 ? Int64(bitPattern: v | ~m) : Int64(bitPattern: v)
    }
    private func groupBin(_ s: String) -> String {
        var str = s
        let pad = (4 - str.count % 4) % 4
        str = String(repeating: "0", count: pad) + str
        var out = ""; var i = 0
        for ch in str { if i != 0 && i % 4 == 0 { out += " " }; out.append(ch); i += 1 }
        return out.isEmpty ? "0" : out
    }
    private func baseStr(_ x: UInt64, _ b: Base) -> String {
        let un = u(x)
        switch b {
        case .hex: return String(un, radix: 16, uppercase: true)
        case .dec: return String(signed(x))
        case .oct: return String(un, radix: 8)
        case .bin: return String(un, radix: 2)
        }
    }
    func refresh() {
        let un = u(cur)
        hexStr = String(un, radix: 16, uppercase: true)
        decStr = String(signed(cur))
        octStr = String(un, radix: 8)
        binStr = groupBin(String(un, radix: 2))
        bits = (0..<wordBits).reversed().map { Int((un >> UInt64($0)) & 1) }
        display = base == .bin ? binStr : baseStr(cur, base)
        if let o = op, let a = acc { expression = baseStr(a, base) + " " + symbol(o) } else { expression = "" }
    }
    func setWordSize(_ b: Int) { wordBits = b; cur = u(cur); if let a = acc { acc = u(a) }; refresh() }
    func toggleBit(_ displayIndex: Int) {
        let bit = wordBits - 1 - displayIndex
        guard bit >= 0, bit < wordBits else { return }
        cur = u(cur ^ (UInt64(1) << UInt64(bit))); waiting = true; refresh()
    }
    private func symbol(_ o: String) -> String {
        ["+":"+","-":"−","*":"×","/":"÷","mod":"mod","and":"AND","or":"OR","xor":"XOR","nand":"NAND","nor":"NOR","lsh":"≪","rsh":"≫","rol":"RoL","ror":"RoR"][o] ?? o
    }
    func digit(_ d: String) {
        let radix: UInt64 = [Base.hex:16, .dec:10, .oct:8, .bin:2][base]!
        guard let dv = UInt64(d, radix: 16), dv < radix else { return }
        var c = waiting ? 0 : u(cur)
        c = u(c &* radix &+ dv)
        cur = c; waiting = false; refresh()
    }
    func isEnabled(_ d: String) -> Bool {
        let radix = [Base.hex:16, .dec:10, .oct:8, .bin:2][base]!
        guard let dv = Int(d, radix: 16) else { return false }
        return dv < radix
    }
    private func applyOp(_ a0: UInt64, _ b0: UInt64, _ o: String) -> UInt64 {
        let a = u(a0), b = u(b0), w = UInt64(wordBits)
        switch o {
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
    func setOp(_ o: String) {
        if op != nil && !waiting { acc = applyOp(acc ?? 0, cur, op!); cur = acc! }
        else { acc = cur }
        op = o; waiting = true; refresh()
    }
    func equals() {
        if let o = op, let a = acc { cur = applyOp(a, cur, o); op = nil; waiting = true }
        refresh()
    }
    func unary(_ k: String) {
        if k == "not" { cur = u(~cur) }
        if k == "neg" { cur = u(UInt64(bitPattern: 0 &- signed(cur))) }
        waiting = true; refresh()
    }
    func clearAll() { cur = 0; acc = nil; op = nil; waiting = false; refresh() }
    func clearEntry() { cur = 0; waiting = false; refresh() }
    func backspace() {
        if waiting { return }
        let radix: UInt64 = [Base.hex:16, .dec:10, .oct:8, .bin:2][base]!
        cur = u(cur / radix); refresh()
    }
    func setBase(_ b: Base) { base = b; refresh() }
    func setValue(_ v: Double) { cur = u(UInt64(bitPattern: Int64(v.rounded(.towardZero)))); waiting = true; refresh() }
}

// MARK: - Date calculation
final class DateVM: ObservableObject {
    @Published var from = Date()
    @Published var to = Date()
    @Published var startDate = Date()
    @Published var addMode = true
    @Published var years = 0
    @Published var months = 0
    @Published var days = 0

    var difference: (headline: String, totalDays: Int) {
        let cal = Calendar.current
        let a = min(from, to), b = max(from, to)
        let comps = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b))
        let total = cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day ?? 0
        var parts: [String] = []
        if let y = comps.year, y != 0 { parts.append("\(y) year" + (y > 1 ? "s" : "")) }
        if let m = comps.month, m != 0 { parts.append("\(m) month" + (m > 1 ? "s" : "")) }
        if let d = comps.day, d != 0 { parts.append("\(d) day" + (d > 1 ? "s" : "")) }
        return (parts.isEmpty ? "Same day" : parts.joined(separator: ", "), total)
    }
    var computed: String {
        let cal = Calendar.current
        var dc = DateComponents()
        let s = addMode ? 1 : -1
        dc.year = s * years; dc.month = s * months; dc.day = s * days
        guard let r = cal.date(byAdding: dc, to: startDate) else { return "—" }
        let f = DateFormatter(); f.dateStyle = .full
        return f.string(from: r)
    }
}

// MARK: - Converter
struct ConvCategory: Identifiable {
    let id = UUID()
    let name: String
    let symbol: String
    let base: String
    let units: [(String, Double)]   // (name, factor to base). Temperature handled specially.
    let temperature: Bool
}
enum Converters {
    static func tempConvert(_ v: Double, _ from: String, _ to: String) -> Double {
        var c: Double
        if from == "Celsius" { c = v } else if from == "Fahrenheit" { c = (v - 32) * 5/9 } else { c = v - 273.15 }
        if to == "Celsius" { return c }; if to == "Fahrenheit" { return c * 9/5 + 32 }; return c + 273.15
    }
    static let all: [ConvCategory] = [
        ConvCategory(name: "Length", symbol: "ruler", base: "Meter", units: [
            ("Nanometer",1e-9),("Micron",1e-6),("Millimeter",1e-3),("Centimeter",1e-2),("Meter",1),("Kilometer",1e3),
            ("Inch",0.0254),("Foot",0.3048),("Yard",0.9144),("Mile",1609.344),("Nautical mile",1852)], temperature: false),
        ConvCategory(name: "Weight and Mass", symbol: "scalemass", base: "Kilogram", units: [
            ("Carat",0.0002),("Milligram",1e-6),("Gram",1e-3),("Kilogram",1),("Metric tonne",1000),
            ("Ounce",0.0283495),("Pound",0.453592),("Stone",6.35029),("US ton",907.185)], temperature: false),
        ConvCategory(name: "Temperature", symbol: "thermometer", base: "Celsius", units: [
            ("Celsius",1),("Fahrenheit",1),("Kelvin",1)], temperature: true),
        ConvCategory(name: "Volume", symbol: "drop", base: "Liter", units: [
            ("Milliliter",1e-3),("Liter",1),("Cubic meter",1000),("Teaspoon",0.00492892),("Tablespoon",0.0147868),
            ("Fluid ounce (US)",0.0295735),("Cup",0.236588),("Pint (US)",0.473176),("Quart (US)",0.946353),
            ("Gallon (US)",3.78541),("Gallon (UK)",4.54609)], temperature: false),
        ConvCategory(name: "Area", symbol: "square", base: "Square meter", units: [
            ("Square millimeter",1e-6),("Square centimeter",1e-4),("Square meter",1),("Hectare",1e4),
            ("Square kilometer",1e6),("Square inch",0.00064516),("Square foot",0.092903),("Square yard",0.836127),
            ("Acre",4046.86),("Square mile",2589988)], temperature: false),
        ConvCategory(name: "Speed", symbol: "speedometer", base: "Meter per second", units: [
            ("Centimeter/second",0.01),("Meter/second",1),("Kilometer/hour",0.277778),("Foot/second",0.3048),
            ("Mile/hour",0.44704),("Knot",0.514444),("Mach",340.29)], temperature: false),
        ConvCategory(name: "Time", symbol: "clock", base: "Second", units: [
            ("Microsecond",1e-6),("Millisecond",1e-3),("Second",1),("Minute",60),("Hour",3600),
            ("Day",86400),("Week",604800),("Year",31557600)], temperature: false),
        ConvCategory(name: "Energy", symbol: "bolt", base: "Joule", units: [
            ("Joule",1),("Kilojoule",1000),("Calorie (th)",4.184),("Kilocalorie (food)",4184),("Watt-hour",3600),
            ("Kilowatt-hour",3.6e6),("Electron volt",1.602177e-19),("British thermal unit",1055.06),("Foot-pound",1.35582)], temperature: false),
        ConvCategory(name: "Power", symbol: "powerplug", base: "Watt", units: [
            ("Watt",1),("Kilowatt",1000),("Megawatt",1e6),("Horsepower (US)",745.7),("Horsepower (metric)",735.499)], temperature: false),
        ConvCategory(name: "Data", symbol: "externaldrive", base: "Byte", units: [
            ("Bit",0.125),("Byte",1),("Kilobyte",1000),("Kibibyte",1024),("Megabyte",1e6),("Mebibyte",1048576),
            ("Gigabyte",1e9),("Gibibyte",1073741824),("Terabyte",1e12),("Tebibyte",1099511627776)], temperature: false),
        ConvCategory(name: "Pressure", symbol: "gauge", base: "Pascal", units: [
            ("Pascal",1),("Kilopascal",1000),("Bar",1e5),("PSI",6894.76),("Atmosphere",101325),("mmHg",133.322)], temperature: false),
        ConvCategory(name: "Angle", symbol: "angle", base: "Degree", units: [
            ("Degree",1),("Radian",57.29578),("Gradian",0.9)], temperature: false),
    ]
}

final class ConverterVM: ObservableObject {
    @Published var category: ConvCategory
    @Published var fromUnit: String
    @Published var toUnit: String
    @Published var input: String = "0"
    @Published var topActive = true

    init(_ cat: ConvCategory) {
        category = cat
        fromUnit = cat.base
        toUnit = cat.units.count > 1 ? cat.units[1].0 : cat.units[0].0
    }
    func setCategory(_ cat: ConvCategory) {
        category = cat; fromUnit = cat.base
        toUnit = cat.units.count > 1 ? cat.units[1].0 : cat.units[0].0
        input = "0"; topActive = true
    }
    private func factor(_ name: String) -> Double { category.units.first(where: { $0.0 == name })?.1 ?? 1 }
    var value: Double { Double(input) ?? 0 }
    var output: Double {
        let v = value
        if category.temperature {
            return topActive ? Converters.tempConvert(v, fromUnit, toUnit) : Converters.tempConvert(v, toUnit, fromUnit)
        }
        return topActive ? v * factor(fromUnit) / factor(toUnit) : v * factor(toUnit) / factor(fromUnit)
    }
    var topDisplay: String { topActive ? Num.group(input) : Num.fmt(output) }
    var botDisplay: String { topActive ? Num.fmt(output) : Num.group(input) }

    func key(_ k: String) {
        switch k {
        case "C": input = "0"
        case "back": input = input.count > 1 ? String(input.dropLast()) : "0"
        case "neg": input = input.hasPrefix("-") ? String(input.dropFirst()) : (input == "0" ? "0" : "-" + input)
        case ".": if !input.contains(".") { input += "." }
        default:
            if k >= "0" && k <= "9" {
                if input.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "").count >= 15 { return }
                input = (input == "0") ? k : input + k
            }
        }
    }
}

// MARK: - Graphing
final class GraphVM: ObservableObject {
    @Published var equations: [String] = ["x^2", "", ""]
    @Published var xmin = -10.0
    @Published var xmax = 10.0
    @Published var ymin = -7.0
    @Published var ymax = 7.0
    func zoom(_ f: Double) {
        let cx = (xmin+xmax)/2, cy = (ymin+ymax)/2, hw = (xmax-xmin)/2*f, hh = (ymax-ymin)/2*f
        xmin = cx-hw; xmax = cx+hw; ymin = cy-hh; ymax = cy+hh
    }
    func reset() { xmin = -10; xmax = 10; ymin = -7; ymax = 7 }
    func pan(_ dx: Double, _ dy: Double) { xmin += dx; xmax += dx; ymin += dy; ymax += dy }
}

enum GraphExpr {
    static func eval(_ src: String, x: Double) -> Double? {
        let toks = tokenize(src); var pos = 0
        func peek() -> String? { pos < toks.count ? toks[pos] : nil }
        func adv() -> String? { let t = peek(); if t != nil { pos += 1 }; return t }
        func atom() -> Double? {
            guard let t = adv() else { return nil }
            if t == "(" { let v = expr(); if peek() == ")" { _ = adv() }; return v }
            if let d = Double(t) { return d }
            if t == "x" { return x }
            if t == "pi" || t == "π" { return .pi }
            if t == "e" { return M_E }
            if peek() == "(" { _ = adv(); let a = expr() ?? .nan; if peek() == ")" { _ = adv() }; return apply(t, a) }
            return nil
        }
        func power() -> Double? { guard let b = atom() else { return nil }; if peek() == "^" { _ = adv(); guard let e = unary() else { return nil }; return pow(b, e) }; return b }
        func unary() -> Double? { if peek() == "-" { _ = adv(); return unary().map { -$0 } }; if peek() == "+" { _ = adv(); return unary() }; return power() }
        func term() -> Double? { guard var v = unary() else { return nil }; while let t = peek(), t == "*" || t == "/" { _ = adv(); guard let r = unary() else { return nil }; v = t == "*" ? v*r : v/r }; return v }
        func expr() -> Double? { guard var v = term() else { return nil }; while let t = peek(), t == "+" || t == "-" { _ = adv(); guard let r = term() else { return nil }; v = t == "+" ? v+r : v-r }; return v }
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
