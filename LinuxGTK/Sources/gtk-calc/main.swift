import CGtk
import CalcCore
import Foundation

// A scientific expression calculator for GTK4, reusing CalcCore's evaluator.
final class CalcApp {
    var expr = ""
    var shown = false
    var display: OpaquePointer?
    func setDisplay(_ s: String) { if let d = display { gtk_label_set_text(d, s) } }

    func map(_ k: String) -> String {
        switch k {
        case "×": return "*"; case "÷": return "/"; case "−": return "-"
        case "√": return "sqrt("; case "xʸ": return "^"; case "x²": return "^2"
        case "sin", "cos", "tan", "log", "ln": return k + "("
        case "π": return "pi"
        default: return k
        }
    }
    func press(_ k: String) {
        switch k {
        case "C": expr = ""; shown = false
        case "⌫": if !expr.isEmpty { expr.removeLast() }; shown = false
        case "=":
            if expr.isEmpty { return }
            if let v = GraphExpr.eval(expr, x: 0) {
                let s = Num.fmt(v); setDisplay(s); expr = s.replacingOccurrences(of: ",", with: ""); shown = true
            } else { setDisplay("Error"); expr = "" }
            return
        default:
            if shown {
                if "+-*/^".contains(map(k)) { shown = false } else { expr = ""; shown = false }
            }
            expr += map(k)
        }
        setDisplay(expr.isEmpty ? "0" : expr)
    }
}

let calc = CalcApp()

// label, column, row  (row 0 is the display)
let keys: [(String, Int32, Int32)] = [
    ("C", 0, 1), ("⌫", 1, 1), ("(", 2, 1), (")", 3, 1), ("÷", 4, 1),
    ("sin", 0, 2), ("cos", 1, 2), ("tan", 2, 2), ("xʸ", 3, 2), ("×", 4, 2),
    ("7", 0, 3), ("8", 1, 3), ("9", 2, 3), ("√", 3, 3), ("−", 4, 3),
    ("4", 0, 4), ("5", 1, 4), ("6", 2, 4), ("π", 3, 4), ("+", 4, 4),
    ("1", 0, 5), ("2", 1, 5), ("3", 2, 5), ("e", 3, 5), ("=", 4, 5),
    ("0", 0, 6), (".", 1, 6), ("x²", 2, 6), ("log", 3, 6), ("ln", 4, 6),
]

func raw(_ p: OpaquePointer?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }
func connect(_ obj: OpaquePointer?, _ signal: String, _ cb: @escaping @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void) {
    g_signal_connect_data(raw(obj), signal, unsafeBitCast(cb, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
}

let onClick: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { btn, _ in
    guard let btn = btn, let c = gtk_button_get_label(btn) else { return }
    calc.press(String(cString: c))
}

let onActivate: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { app, _ in
    let win = gtk_application_window_new(app)
    gtk_window_set_title(win, "Calculator")
    gtk_window_set_default_size(win, 340, 480)

    let grid = gtk_grid_new()
    gtk_grid_set_row_spacing(grid, 5)
    gtk_grid_set_column_spacing(grid, 5)
    gtk_widget_set_margin_top(grid, 10); gtk_widget_set_margin_bottom(grid, 10)
    gtk_widget_set_margin_start(grid, 10); gtk_widget_set_margin_end(grid, 10)

    let disp = gtk_label_new("0")
    gtk_label_set_xalign(disp, 1.0)
    gtk_widget_set_hexpand(disp, 1)
    let attrs = pango_attr_list_new()
    pango_attr_list_insert(attrs, pango_attr_scale_new(2.4))
    gtk_label_set_attributes(disp, attrs)
    gtk_grid_attach(grid, disp, 0, 0, 5, 1)
    calc.display = disp

    for (label, col, row) in keys {
        let b = gtk_button_new_with_label(label)
        gtk_widget_set_hexpand(b, 1); gtk_widget_set_vexpand(b, 1)
        connect(b, "clicked", onClick)
        gtk_grid_attach(grid, b, col, row, 1, 1)
    }

    gtk_window_set_child(win, grid)
    gtk_window_present(win)
}

let app = gtk_application_new("com.recreated.gtkcalc", GApplicationFlags(rawValue: 0))
connect(app, "activate", onActivate)
let status = g_application_run(app, CommandLine.argc, CommandLine.unsafeArgv)
g_object_unref(raw(app))
exit(status)
