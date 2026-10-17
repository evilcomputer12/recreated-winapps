import CGtk
import Foundation

@inline(__always) func cast<T, U>(_ p: UnsafeMutablePointer<T>?) -> UnsafeMutablePointer<U>? {
    p.map { UnsafeMutablePointer<U>(OpaquePointer($0)) }
}
func connect<T>(_ obj: UnsafeMutablePointer<T>!, _ signal: String, _ cb: GCallback) {
    g_signal_connect_data(UnsafeMutableRawPointer(obj), signal, cb, nil, nil, GConnectFlags(rawValue: 0))
}

final class PaintState {
    var surface: OpaquePointer?                     // cairo_surface_t*
    var area: UnsafeMutablePointer<GtkWidget>?      // GtkDrawingArea
    var r = 0.0, g = 0.0, b = 0.0
    var size = 4.0
    var startX = 0.0, startY = 0.0, lastX = 0.0, lastY = 0.0
    let w: Int32 = 900, h: Int32 = 600

    func makeSurface() { surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h); clear() }
    func clear() {
        guard let s = surface else { return }
        let cr = cairo_create(s)
        cairo_set_source_rgb(cr, 1, 1, 1); cairo_paint(cr); cairo_destroy(cr); redraw()
    }
    func stroke(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        guard let s = surface else { return }
        let cr = cairo_create(s)
        cairo_set_source_rgb(cr, r, g, b)
        cairo_set_line_width(cr, size)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_move_to(cr, x0, y0); cairo_line_to(cr, x1, y1); cairo_stroke(cr)
        cairo_destroy(cr); redraw()
    }
    func dot(_ x: Double, _ y: Double) {
        guard let s = surface else { return }
        let cr = cairo_create(s)
        cairo_set_source_rgb(cr, r, g, b)
        cairo_arc(cr, x, y, size / 2, 0, 2 * Double.pi); cairo_fill(cr)
        cairo_destroy(cr); redraw()
    }
    func redraw() { if let a = area { gtk_widget_queue_draw(a) } }
    func save() {
        guard let s = surface else { return }
        let path = FileManager.default.currentDirectoryPath + "/gtk-paint.png"
        cairo_surface_write_to_png(s, path)
        print("Saved: \(path)")
    }
}

let paint = PaintState()

let drawFunc: @convention(c) (UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, UnsafeMutableRawPointer?) -> Void = { _, cr, _, _, _ in
    guard let cr = cr, let s = paint.surface else { return }
    cairo_set_source_surface(cr, s, 0, 0); cairo_paint(cr)
}
let onDragBegin: @convention(c) (UnsafeMutablePointer<GtkGestureDrag>?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, sx, sy, _ in
    paint.startX = sx; paint.startY = sy; paint.lastX = sx; paint.lastY = sy; paint.dot(sx, sy)
}
let onDragUpdate: @convention(c) (UnsafeMutablePointer<GtkGestureDrag>?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, ox, oy, _ in
    let x = paint.startX + ox, y = paint.startY + oy
    paint.stroke(paint.lastX, paint.lastY, x, y); paint.lastX = x; paint.lastY = y
}
let onColor: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { btn, _ in
    guard let btn = btn, let c = gtk_button_get_label(btn) else { return }
    switch String(cString: c) {
    case "Black": (paint.r, paint.g, paint.b) = (0, 0, 0)
    case "Red": (paint.r, paint.g, paint.b) = (0.85, 0.12, 0.12)
    case "Orange": (paint.r, paint.g, paint.b) = (0.96, 0.55, 0.05)
    case "Yellow": (paint.r, paint.g, paint.b) = (0.98, 0.82, 0.10)
    case "Green": (paint.r, paint.g, paint.b) = (0.18, 0.66, 0.25)
    case "Blue": (paint.r, paint.g, paint.b) = (0.13, 0.45, 0.90)
    case "Purple": (paint.r, paint.g, paint.b) = (0.55, 0.25, 0.78)
    case "White": (paint.r, paint.g, paint.b) = (1, 1, 1)
    default: break
    }
}
let onClear: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { _, _ in paint.clear() }
let onSave: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { _, _ in paint.save() }
let onSize: @convention(c) (UnsafeMutablePointer<GtkSpinButton>?, UnsafeMutableRawPointer?) -> Void = { spin, _ in
    if let spin = spin { paint.size = gtk_spin_button_get_value(spin) }
}

let onActivate: @convention(c) (UnsafeMutablePointer<GtkApplication>?, UnsafeMutableRawPointer?) -> Void = { app, _ in
    paint.makeSurface()
    let win = gtk_application_window_new(app)
    gtk_window_set_title(cast(win), "Paint")
    gtk_window_set_default_size(cast(win), 940, 680)

    let vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
    gtk_widget_set_margin_top(bar, 6); gtk_widget_set_margin_bottom(bar, 6)
    gtk_widget_set_margin_start(bar, 6); gtk_widget_set_margin_end(bar, 6)

    for name in ["Black", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "White"] {
        let b = gtk_button_new_with_label(name)
        connect(b, "clicked", unsafeBitCast(onColor, to: GCallback.self))
        gtk_box_append(cast(bar), b)
    }
    gtk_box_append(cast(bar), gtk_label_new("Size"))
    let spin = gtk_spin_button_new_with_range(1, 60, 1)
    gtk_spin_button_set_value(cast(spin), 4)
    connect(spin, "value-changed", unsafeBitCast(onSize, to: GCallback.self))
    gtk_box_append(cast(bar), spin)
    let clearBtn = gtk_button_new_with_label("Clear")
    connect(clearBtn, "clicked", unsafeBitCast(onClear, to: GCallback.self))
    gtk_box_append(cast(bar), clearBtn)
    let saveBtn = gtk_button_new_with_label("Save PNG")
    connect(saveBtn, "clicked", unsafeBitCast(onSave, to: GCallback.self))
    gtk_box_append(cast(bar), saveBtn)

    let area = gtk_drawing_area_new()
    paint.area = area
    gtk_drawing_area_set_content_width(cast(area), paint.w)
    gtk_drawing_area_set_content_height(cast(area), paint.h)
    gtk_widget_set_hexpand(area, 1); gtk_widget_set_vexpand(area, 1)
    gtk_drawing_area_set_draw_func(cast(area), drawFunc, nil, nil)

    let drag = gtk_gesture_drag_new()
    connect(drag, "drag-begin", unsafeBitCast(onDragBegin, to: GCallback.self))
    connect(drag, "drag-update", unsafeBitCast(onDragUpdate, to: GCallback.self))
    gtk_widget_add_controller(area, cast(drag))

    gtk_box_append(cast(vbox), bar)
    gtk_box_append(cast(vbox), area)
    gtk_window_set_child(cast(win), vbox)
    gtk_window_present(cast(win))
}

let app = gtk_application_new("com.recreated.gtkpaint", GApplicationFlags(rawValue: 0))
connect(app, "activate", unsafeBitCast(onActivate, to: GCallback.self))
let status = g_application_run(cast(app), CommandLine.argc, CommandLine.unsafeArgv)
g_object_unref(UnsafeMutableRawPointer(app))
exit(status)
