import CGtk
import Foundation

final class PaintState {
    var surface: OpaquePointer?          // cairo_surface_t (ARGB32)
    var area: OpaquePointer?             // GtkDrawingArea
    var r = 0.0, g = 0.0, b = 0.0        // current colour
    var size = 4.0
    var startX = 0.0, startY = 0.0, lastX = 0.0, lastY = 0.0
    let w: Int32 = 900, h: Int32 = 600

    func makeSurface() {
        surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h)
        clear()
    }
    func clear() {
        guard let s = surface else { return }
        let cr = cairo_create(s)
        cairo_set_source_rgb(cr, 1, 1, 1); cairo_paint(cr); cairo_destroy(cr)
        redraw()
    }
    func stroke(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        guard let s = surface else { return }
        let cr = cairo_create(s)
        cairo_set_source_rgb(cr, r, g, b)
        cairo_set_line_width(cr, size)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_move_to(cr, x0, y0); cairo_line_to(cr, x1, y1); cairo_stroke(cr)
        cairo_destroy(cr)
        redraw()
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

func raw(_ p: OpaquePointer?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }
func connectG(_ obj: OpaquePointer?, _ signal: String, _ cb: GCallback) {
    g_signal_connect_data(raw(obj), signal, cb, nil, nil, GConnectFlags(rawValue: 0))
}

let drawFunc: @convention(c) (OpaquePointer?, OpaquePointer?, Int32, Int32, UnsafeMutableRawPointer?) -> Void = { _, cr, _, _, _ in
    guard let cr = cr, let s = paint.surface else { return }
    cairo_set_source_surface(cr, s, 0, 0)
    cairo_paint(cr)
}

let onDragBegin: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, sx, sy, _ in
    paint.startX = sx; paint.startY = sy; paint.lastX = sx; paint.lastY = sy
    paint.dot(sx, sy)
}
let onDragUpdate: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, ox, oy, _ in
    let x = paint.startX + ox, y = paint.startY + oy
    paint.stroke(paint.lastX, paint.lastY, x, y)
    paint.lastX = x; paint.lastY = y
}

let onColor: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { btn, _ in
    guard let btn = btn, let c = gtk_button_get_label(btn) else { return }
    switch String(cString: c) {
    case "Black": paint.r = 0; paint.g = 0; paint.b = 0
    case "Red": paint.r = 0.85; paint.g = 0.12; paint.b = 0.12
    case "Orange": paint.r = 0.96; paint.g = 0.55; paint.b = 0.05
    case "Yellow": paint.r = 0.98; paint.g = 0.82; paint.b = 0.10
    case "Green": paint.r = 0.18; paint.g = 0.66; paint.b = 0.25
    case "Blue": paint.r = 0.13; paint.g = 0.45; paint.b = 0.90
    case "Purple": paint.r = 0.55; paint.g = 0.25; paint.b = 0.78
    case "White": paint.r = 1; paint.g = 1; paint.b = 1
    default: break
    }
}
let onClear: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in paint.clear() }
let onSave: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in paint.save() }
let onSize: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { spin, _ in
    if let spin = spin { paint.size = gtk_spin_button_get_value(spin) }
}

let onActivate: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { app, _ in
    paint.makeSurface()
    let win = gtk_application_window_new(app)
    gtk_window_set_title(win, "Paint")
    gtk_window_set_default_size(win, 940, 680)

    let vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
    gtk_widget_set_margin_top(bar, 6); gtk_widget_set_margin_bottom(bar, 6)
    gtk_widget_set_margin_start(bar, 6); gtk_widget_set_margin_end(bar, 6)

    for name in ["Black", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "White"] {
        let b = gtk_button_new_with_label(name)
        connectG(b, "clicked", unsafeBitCast(onColor, to: GCallback.self))
        gtk_box_append(bar, b)
    }
    let sizeLabel = gtk_label_new("Size")
    gtk_box_append(bar, sizeLabel)
    let spin = gtk_spin_button_new_with_range(1, 60, 1)
    gtk_spin_button_set_value(spin, 4)
    connectG(spin, "value-changed", unsafeBitCast(onSize, to: GCallback.self))
    gtk_box_append(bar, spin)
    let clearBtn = gtk_button_new_with_label("Clear")
    connectG(clearBtn, "clicked", unsafeBitCast(onClear, to: GCallback.self))
    gtk_box_append(bar, clearBtn)
    let saveBtn = gtk_button_new_with_label("Save PNG")
    connectG(saveBtn, "clicked", unsafeBitCast(onSave, to: GCallback.self))
    gtk_box_append(bar, saveBtn)

    let area = gtk_drawing_area_new()
    paint.area = area
    gtk_drawing_area_set_content_width(area, paint.w)
    gtk_drawing_area_set_content_height(area, paint.h)
    gtk_widget_set_hexpand(area, 1); gtk_widget_set_vexpand(area, 1)
    gtk_drawing_area_set_draw_func(area, drawFunc, nil, nil)

    let drag = gtk_gesture_drag_new()
    connectG(drag, "drag-begin", unsafeBitCast(onDragBegin, to: GCallback.self))
    connectG(drag, "drag-update", unsafeBitCast(onDragUpdate, to: GCallback.self))
    gtk_widget_add_controller(area, drag)

    gtk_box_append(vbox, bar)
    gtk_box_append(vbox, area)
    gtk_window_set_child(win, vbox)
    gtk_window_present(win)
}

let app = gtk_application_new("com.recreated.gtkpaint", GApplicationFlags(rawValue: 0))
connectG(app, "activate", unsafeBitCast(onActivate, to: GCallback.self))
let status = g_application_run(app, CommandLine.argc, CommandLine.unsafeArgv)
g_object_unref(raw(app))
exit(status)
