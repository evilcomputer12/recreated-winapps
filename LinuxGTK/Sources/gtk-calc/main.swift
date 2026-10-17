import CGtk
import CalcCore
import Foundation

// ---- GObject pointer helpers (GTK4 imports some typed, some opaque) ----
@inline(__always) func cast<T, U>(_ p: UnsafeMutablePointer<T>?) -> UnsafeMutablePointer<U>? { p.map { UnsafeMutablePointer<U>(OpaquePointer($0)) } }
@inline(__always) func cast<T>(_ p: UnsafeMutablePointer<T>?) -> OpaquePointer? { p.map { OpaquePointer($0) } }
@inline(__always) func cast<U>(_ p: OpaquePointer?) -> UnsafeMutablePointer<U>? { p.map { UnsafeMutablePointer<U>($0) } }
@inline(__always) func cast(_ p: OpaquePointer?) -> OpaquePointer? { p }
@inline(__always) func R<T>(_ p: UnsafeMutablePointer<T>?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }
@inline(__always) func R(_ p: OpaquePointer?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }
func connectRaw(_ raw: UnsafeMutableRawPointer?, _ signal: String, _ cb: GCallback) {
    g_signal_connect_data(raw, signal, cb, nil, nil, GConnectFlags(rawValue: 0))
}

// ---- styling ----
func applyCSS(_ css: String) {
    let p = gtk_css_provider_new()
    gtk_css_provider_load_from_string(p, css)
    if let disp = gdk_display_get_default() {
        gtk_style_context_add_provider_for_display(disp, cast(p), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}

// ================= state =================
final class Model {
    // standard / scientific share an expression
    var expr = ""
    var shown = false
    var mem = 0.0
    var exprLabel: UnsafeMutablePointer<GtkWidget>?
    var resultLabel: UnsafeMutablePointer<GtkWidget>?

    // programmer
    var pVal: UInt64 = 0
    var pAcc: UInt64 = 0
    var pOp = ""
    var pWait = false
    var pBase = 10
    let prog = Prog(wordBits: 64)
    var hexL: UnsafeMutablePointer<GtkWidget>?
    var decL: UnsafeMutablePointer<GtkWidget>?
    var octL: UnsafeMutablePointer<GtkWidget>?
    var binL: UnsafeMutablePointer<GtkWidget>?

    var stack: UnsafeMutablePointer<GtkWidget>?
    var mode: String {
        guard let s = stack, let c = gtk_stack_get_visible_child_name(cast(s)) else { return "standard" }
        return String(cString: c)
    }

    // ---------- scientific/standard ----------
    func mapKey(_ k: String) -> String {
        switch k {
        case "×": return "*"; case "÷": return "/"; case "−": return "-"
        case "√": return "sqrt("; case "xʸ", "x^y": return "^"; case "x²": return "^2"
        case "10ˣ": return "10^"; case "eˣ": return "exp("; case "|x|": return "abs("
        case "sin", "cos", "tan", "asin", "acos", "tan⁻¹", "log", "ln", "exp", "abs": return k + "("
        case "π": return "pi"; case "%": return "/100"
        default: return k
        }
    }
    func sciSet() {
        gtk_label_set_text(cast(resultLabel), shown ? Num.fmt(GraphExpr.eval(expr, x: 0) ?? .nan) : (expr.isEmpty ? "0" : expr))
        gtk_label_set_text(cast(exprLabel), shown ? expr : "")
    }
    func sciPress(_ k: String) {
        switch k {
        case "C", "AC": expr = ""; shown = false
        case "CE": expr = ""; shown = false
        case "⌫": if shown { shown = false } else if !expr.isEmpty { expr.removeLast() }
        case "=":
            if expr.isEmpty { return }
            if GraphExpr.eval(expr, x: 0) != nil { shown = true } else { gtk_label_set_text(cast(resultLabel), "Error"); gtk_label_set_text(cast(exprLabel), expr); expr = ""; return }
        case "MC": mem = 0
        case "MR": let v = Num.fmt(mem).replacingOccurrences(of: ",", with: ""); if shown { expr = v; shown = false } else { expr += v }
        case "MS": if let v = GraphExpr.eval(expr, x: 0) { mem = v }
        case "M+": if let v = GraphExpr.eval(expr, x: 0) { mem += v }
        case "M−": if let v = GraphExpr.eval(expr, x: 0) { mem -= v }
        case "±":
            if let v = GraphExpr.eval(expr, x: 0) { let n = Num.fmt(-v).replacingOccurrences(of: ",", with: ""); expr = n; shown = false }
        default:
            if shown {
                let m = mapKey(k)
                if "+-*/^".contains(m), let v = GraphExpr.eval(expr, x: 0) { expr = Num.fmt(v).replacingOccurrences(of: ",", with: "") } else { expr = "" }
                shown = false
            }
            expr += mapKey(k)
        }
        if shown {
            gtk_label_set_text(cast(exprLabel), expr + " =")
            gtk_label_set_text(cast(resultLabel), Num.fmt(GraphExpr.eval(expr, x: 0) ?? .nan))
        } else {
            gtk_label_set_text(cast(exprLabel), "")
            gtk_label_set_text(cast(resultLabel), expr.isEmpty ? "0" : expr)
        }
    }

    // ---------- programmer ----------
    func progRefresh() {
        gtk_label_set_text(cast(hexL), "HEX   " + prog.format(pVal, base: 16))
        gtk_label_set_text(cast(decL), "DEC   " + prog.format(pVal, base: 10))
        gtk_label_set_text(cast(octL), "OCT   " + prog.format(pVal, base: 8))
        gtk_label_set_text(cast(binL), "BIN   " + prog.format(pVal, base: 2))
    }
    func progPress(_ k: String) {
        let radix: UInt64 = [16: 16, 10: 10, 8: 8, 2: 2][pBase]!
        if let dv = UInt64(k, radix: 16), dv < radix {
            pVal = prog.u((pWait ? 0 : pVal) &* radix &+ dv); pWait = false; progRefresh(); return
        }
        switch k {
        case "AC": pVal = 0; pAcc = 0; pOp = ""; pWait = false
        case "⌫": pVal = prog.u(pVal / radix)
        case "NOT": pVal = prog.u(~pVal); pWait = true
        case "=": if !pOp.isEmpty { pVal = prog.apply(pAcc, pVal, pOp); pOp = "" }; pWait = true
        case "HEX": pBase = 16; case "DEC": pBase = 10; case "OCT": pBase = 8; case "BIN": pBase = 2
        default:
            let opmap = ["AND": "and", "OR": "or", "XOR": "xor", "«": "lsh", "»": "rsh", "mod": "mod", "+": "+", "−": "-", "×": "*", "÷": "/"]
            if let o = opmap[k] {
                if !pOp.isEmpty && !pWait { pAcc = prog.apply(pAcc, pVal, pOp) } else { pAcc = pVal }
                pOp = o; pWait = true; pVal = pAcc
            }
        }
        progRefresh()
    }
}
let m = Model()

// ================= button click =================
let onSci: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { b, _ in
    guard let b = b, let c = gtk_button_get_label(b) else { return }; m.sciPress(String(cString: c))
}
let onProg: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { b, _ in
    guard let b = b, let c = gtk_button_get_label(b) else { return }; m.progPress(String(cString: c))
}

func makeGrid(_ rows: [[String]], cols: Int32, _ cb: GCallback) -> UnsafeMutablePointer<GtkWidget>? {
    let grid = gtk_grid_new()
    gtk_grid_set_row_spacing(cast(grid), 6); gtk_grid_set_column_spacing(cast(grid), 6)
    gtk_widget_set_margin_top(grid, 8); gtk_widget_set_margin_bottom(grid, 10)
    gtk_widget_set_margin_start(grid, 10); gtk_widget_set_margin_end(grid, 10)
    for (r, row) in rows.enumerated() {
        for (ci, label) in row.enumerated() where !label.isEmpty {
            let btn = gtk_button_new_with_label(label)
            gtk_widget_set_hexpand(btn, 1); gtk_widget_set_vexpand(btn, 1)
            var cls = "fn"
            if label == "=" { cls = "equal" }
            else if ["÷", "×", "−", "+"].contains(label) { cls = "op" }
            else if let f = label.first, f.isNumber || label == "." { cls = "digit" }
            gtk_widget_add_css_class(btn, "key"); gtk_widget_add_css_class(btn, cls)
            connectRaw(R(btn), "clicked", cb)
            gtk_grid_attach(cast(grid), btn, Int32(ci), Int32(r), 1, 1)
        }
    }
    return grid
}

// ================= keyboard =================
let onKey: @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Int32 = { _, keyval, _, _, _ in
    if m.mode == "programmer" { return 0 }
    switch keyval {
    case 0xff0d, 0xff8d: m.sciPress("="); return 1          // Return / KP_Enter
    case 0xff08: m.sciPress("⌫"); return 1                  // BackSpace
    case 0xff1b: m.sciPress("C"); return 1                  // Escape
    default: break
    }
    let u = gdk_keyval_to_unicode(keyval)
    guard let scalar = Unicode.Scalar(u) else { return 0 }
    let ch = String(scalar)
    switch ch {
    case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "(", ")": m.sciPress(ch); return 1
    case "+": m.sciPress("+"); return 1
    case "-": m.sciPress("−"); return 1
    case "*": m.sciPress("×"); return 1
    case "/": m.sciPress("÷"); return 1
    case "^": m.sciPress("xʸ"); return 1
    case "=": m.sciPress("="); return 1
    default: return 0
    }
}

// ================= activate =================
let onActivate: @convention(c) (UnsafeMutablePointer<GtkApplication>?, UnsafeMutableRawPointer?) -> Void = { app, _ in
    applyCSS("""
    window { background-color: #f2f3f5; }
    headerbar { min-height: 40px; background: #e9eaee; box-shadow: none; }
    .display { font-size: 15px; color: rgba(0,0,0,0.45); padding: 0 8px; }
    .result  { font-size: 48px; font-weight: 300; color: #16181d; padding: 0 8px; }
    .bases   { font-family: monospace; font-size: 16px; color: #2a2c31; padding: 3px 8px; }
    button.key {
      background-image: none; background-color: #ffffff; color: #1a1c20;
      border: none; border-radius: 12px; box-shadow: 0 1px 2px rgba(0,0,0,0.07);
      min-height: 54px; font-size: 19px; font-weight: 400; margin: 0;
      transition: background-color 110ms ease;
    }
    button.key:hover  { background-color: #eceef1; }
    button.key:active { background-color: #dde0e5; }
    button.digit { font-weight: 500; }
    button.op   { background-color: #e7eefb; color: #0a63c9; font-weight: 600; }
    button.op:hover { background-color: #d9e5fa; }
    button.fn   { background-color: #eceef2; color: #3a3d44; font-size: 15px; }
    button.fn:hover { background-color: #e1e4ea; }
    button.equal {
      background-image: none; background-color: #0067c0; color: #ffffff;
      font-weight: 700; font-size: 21px; border-radius: 12px;
      box-shadow: 0 2px 6px rgba(0,103,192,0.35);
    }
    button.equal:hover { background-color: #1577d6; }
    """)

    let win = gtk_application_window_new(app)
    gtk_window_set_title(cast(win), "Calculator")
    gtk_window_set_default_size(cast(win), 360, 560)

    let header = gtk_header_bar_new()
    let switcher = gtk_stack_switcher_new()
    gtk_header_bar_set_title_widget(cast(header), switcher)
    gtk_window_set_titlebar(cast(win), header)

    let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)

    // shared display (standard + scientific)
    let disp = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)
    gtk_widget_set_margin_top(disp, 10); gtk_widget_set_margin_bottom(disp, 6)
    gtk_widget_set_margin_start(disp, 16); gtk_widget_set_margin_end(disp, 16)
    let exprL = gtk_label_new(""); gtk_label_set_xalign(cast(exprL), 1.0); gtk_widget_add_css_class(exprL, "display")
    let resL = gtk_label_new("0"); gtk_label_set_xalign(cast(resL), 1.0); gtk_widget_add_css_class(resL, "result")
    gtk_label_set_wrap(cast(resL), 0); gtk_label_set_ellipsize(cast(resL), PANGO_ELLIPSIZE_START)
    gtk_box_append(cast(disp), exprL); gtk_box_append(cast(disp), resL)
    m.exprLabel = exprL; m.resultLabel = resL
    gtk_box_append(cast(root), disp)

    let stack = gtk_stack_new()
    gtk_stack_set_transition_type(cast(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
    gtk_widget_set_vexpand(stack, 1)
    gtk_stack_switcher_set_stack(cast(switcher), cast(stack))
    m.stack = stack

    // Standard
    let std = makeGrid([
        ["MC", "MR", "M+", "M−"],
        ["%", "¹⁄ₓ", "x²", "√"],
        ["C", "CE", "⌫", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"],
        ["±", "0", ".", "="],
    ], cols: 4, unsafeBitCast(onSci, to: GCallback.self))
    gtk_stack_add_titled(cast(stack), std, "standard", "Standard")

    // Scientific
    let sci = makeGrid([
        ["C", "CE", "⌫", "(", ")"],
        ["sin", "cos", "tan", "|x|", "xʸ"],
        ["√", "log", "ln", "eˣ", "÷"],
        ["7", "8", "9", "π", "×"],
        ["4", "5", "6", "e", "−"],
        ["1", "2", "3", "x²", "+"],
        ["±", "0", ".", "10ˣ", "="],
    ], cols: 5, unsafeBitCast(onSci, to: GCallback.self))
    gtk_stack_add_titled(cast(stack), sci, "scientific", "Scientific")

    // Programmer
    let progPage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)
    gtk_widget_set_margin_top(progPage, 8); gtk_widget_set_margin_start(progPage, 12); gtk_widget_set_margin_end(progPage, 12)
    for (lbl, store) in [("hex", 0), ("dec", 1), ("oct", 2), ("bin", 3)] {
        let l = gtk_label_new("\(lbl.uppercased())   0"); gtk_label_set_xalign(cast(l), 0.0); gtk_widget_add_css_class(l, "bases")
        gtk_box_append(cast(progPage), l)
        switch store { case 0: m.hexL = l; case 1: m.decL = l; case 2: m.octL = l; default: m.binL = l }
    }
    let progGrid = makeGrid([
        ["HEX", "DEC", "OCT", "BIN", "AC"],
        ["A", "B", "AND", "OR", "⌫"],
        ["C", "D", "XOR", "NOT", "÷"],
        ["E", "F", "7", "8", "9"],
        ["«", "»", "4", "5", "6"],
        ["mod", "±", "1", "2", "3"],
        ["×", "−", "+", "0", "="],
    ], cols: 5, unsafeBitCast(onProg, to: GCallback.self))
    gtk_widget_set_vexpand(progGrid, 1)
    gtk_box_append(cast(progPage), progGrid)
    gtk_stack_add_titled(cast(stack), progPage, "programmer", "Programmer")

    gtk_box_append(cast(root), stack)
    gtk_window_set_child(cast(win), root)

    let keyctl = gtk_event_controller_key_new()
    connectRaw(R(keyctl), "key-pressed", unsafeBitCast(onKey, to: GCallback.self))
    gtk_widget_add_controller(win, keyctl)

    m.progRefresh()
    gtk_window_present(cast(win))
}

let app = gtk_application_new("com.recreated.gtkcalc", GApplicationFlags(rawValue: 32)) // G_APPLICATION_NON_UNIQUE
connectRaw(R(app), "activate", unsafeBitCast(onActivate, to: GCallback.self))
let status = g_application_run(cast(app), CommandLine.argc, CommandLine.unsafeArgv)
g_object_unref(R(app))
exit(status)
