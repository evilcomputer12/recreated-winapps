import CGtk
import CalcCore
import Foundation

// Cast between GObject-derived pointer types (GtkWidget* <-> GtkWindow*, etc.)
@inline(__always) func cast<T, U>(_ p: UnsafeMutablePointer<T>?) -> UnsafeMutablePointer<U>? {
    p.map { UnsafeMutablePointer<U>(OpaquePointer($0)) }
}
func connect<T>(_ obj: UnsafeMutablePointer<T>!, _ signal: String, _ cb: GCallback) {
    g_signal_connect_data(UnsafeMutableRawPointer(obj), signal, cb, nil, nil, GConnectFlags(rawValue: 0))
}

final class CalcApp {
    var expr = ""
    var shown = false
    var display: UnsafeMutablePointer<GtkWidget>?
    func setDisplay(_ s: String) { if let d = display { gtk_label_set_text(cast(d), s) } }

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

let keys: [(String, Int32, Int32)] = [
    ("C", 0, 1), ("⌫", 1, 1), ("(", 2, 1), (")", 3, 1), ("÷", 4, 1),
    ("sin", 0, 2), ("cos", 1, 2), ("tan", 2, 2), ("xʸ", 3, 2), ("×", 4, 2),
    ("7", 0, 3), ("8", 1, 3), ("9", 2, 3), ("√", 3, 3), ("−", 4, 3),
    ("4", 0, 4), ("5", 1, 4), ("6", 2, 4), ("π", 3, 4), ("+", 4, 4),
    ("1", 0, 5), ("2", 1, 5), ("3", 2, 5), ("e", 3, 5), ("=", 4, 5),
    ("0", 0, 6), (".", 1, 6), ("x²", 2, 6), ("log", 3, 6), ("ln", 4, 6),
]

let onClick: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { btn, _ in
    guard let btn = btn, let c = gtk_button_get_label(btn) else { return }
    calc.press(String(cString: c))
}

let onActivate: @convention(c) (UnsafeMutablePointer<GtkApplication>?, UnsafeMutableRawPointer?) -> Void = { app, _ in
    let win = gtk_application_window_new(app)
    gtk_window_set_title(cast(win), "Calculator")
    gtk_window_set_default_size(cast(win), 340, 480)

    let grid = gtk_grid_new()
    gtk_grid_set_row_spacing(cast(grid), 5)
    gtk_grid_set_column_spacing(cast(grid), 5)
    gtk_widget_set_margin_top(grid, 10); gtk_widget_set_margin_bottom(grid, 10)
    gtk_widget_set_margin_start(grid, 10); gtk_widget_set_margin_end(grid, 10)

    let disp = gtk_label_new("0")
    gtk_label_set_xalign(cast(disp), 1.0)
    gtk_widget_set_hexpand(disp, 1)
    gtk_grid_attach(cast(grid), disp, 0, 0, 5, 1)
    calc.display = disp

    for (label, col, row) in keys {
        let b = gtk_button_new_with_label(label)
        gtk_widget_set_hexpand(b, 1); gtk_widget_set_vexpand(b, 1)
        connect(b, "clicked", unsafeBitCast(onClick, to: GCallback.self))
        gtk_grid_attach(cast(grid), b, col, row, 1, 1)
    }

    gtk_window_set_child(cast(win), grid)
    gtk_window_present(cast(win))
}

let app = gtk_application_new("com.recreated.gtkcalc", GApplicationFlags(rawValue: 0))
connect(app, "activate", unsafeBitCast(onActivate, to: GCallback.self))
let status = g_application_run(cast(app), CommandLine.argc, CommandLine.unsafeArgv)
g_object_unref(UnsafeMutableRawPointer(app))
exit(status)
