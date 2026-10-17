import Foundation
import CalcCore

let args = Array(CommandLine.arguments.dropFirst())

func usage() {
    print("""
    calc — portable Calculator engine (Linux / macOS, Foundation only)

    USAGE:
      calc eval "<expr>"              evaluate a math expression (radians)
                                        e.g. calc eval "2+3*4"          -> 14
                                             calc eval "sqrt(144)+sin(0)" -> 12
      calc prog <value> [word]        HEX/DEC/OCT/BIN in word size 64/32/16/8
                                        e.g. calc prog -1 8   calc prog 200 8
      calc conv <value> <from> <to>   unit / temperature convert
                                        e.g. calc conv 100 celsius fahrenheit
                                             calc conv 1 mile m
      calc selftest                   run built-in checks
    """)
}

func runSelftest() -> Int32 {
    var fail = 0
    func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    func check(_ n: String, _ c: Bool) { print((c ? "ok   " : "FAIL ") + n); if !c { fail += 1 } }
    check("eval 2+3*4 = 14", approx(GraphExpr.eval("2+3*4", x: 0)!, 14))
    check("eval 2^3^2 = 512", approx(GraphExpr.eval("2^3^2", x: 0)!, 512))
    check("eval sqrt(144) = 12", approx(GraphExpr.eval("sqrt(144)", x: 0)!, 12))
    check("eval -3^2 = -9", approx(GraphExpr.eval("-3^2", x: 0)!, -9))
    let p8 = Prog(wordBits: 8)
    check("prog byte 200 hex = C8", p8.format(200, base: 16) == "C8")
    check("prog byte -1 hex = FF", p8.format(UInt64(bitPattern: -1), base: 16) == "FF")
    check("prog byte -1 dec = -1", p8.format(UInt64(bitPattern: -1), base: 10) == "-1")
    check("prog 1 RoR 1 (byte) = -128", p8.signed(p8.apply(1, 1, "ror")) == -128)
    check("prog 12 NAND 10 (qword) = -9", Prog(wordBits: 64).signed(Prog().apply(12, 10, "nand")) == -9)
    check("conv 100C -> F = 212", approx(Convert.convert(100, from: "celsius", to: "fahrenheit")!, 212))
    check("conv 1 mile -> m = 1609.344", approx(Convert.convert(1, from: "mile", to: "m")!, 1609.344))
    check("conv 1 gib -> bytes", approx(Convert.convert(1, from: "gib", to: "byte")!, 1073741824))
    print(fail == 0 ? "\nALL PASS" : "\n\(fail) FAILURES")
    return fail == 0 ? 0 : 1
}

guard let cmd = args.first else { usage(); exit(1) }
switch cmd {
case "eval":
    guard args.count > 1, let v = GraphExpr.eval(args[1], x: 0) else { print("error: bad expression"); exit(1) }
    print(Num.fmt(v))
case "prog":
    let val = Int64(args.count > 1 ? args[1] : "0") ?? 0
    let word = args.count > 2 ? (Int(args[2]) ?? 64) : 64
    let p = Prog(wordBits: word); let x = UInt64(bitPattern: val)
    print("word \(p.wordBits)-bit")
    print("HEX  \(p.format(x, base: 16))")
    print("DEC  \(p.format(x, base: 10))")
    print("OCT  \(p.format(x, base: 8))")
    print("BIN  \(p.format(x, base: 2))")
case "conv":
    guard args.count > 3, let v = Double(args[1]), let r = Convert.convert(v, from: args[2], to: args[3]) else { print("error: bad conversion"); exit(1) }
    print(Num.fmt(r))
case "selftest":
    exit(runSelftest())
default:
    usage()
}
