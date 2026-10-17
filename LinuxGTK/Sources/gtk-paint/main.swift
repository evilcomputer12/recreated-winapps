import CGtk
import Foundation

// ---- GObject pointer helpers ----
@inline(__always) func cast<T, U>(_ p: UnsafeMutablePointer<T>?) -> UnsafeMutablePointer<U>? { p.map { UnsafeMutablePointer<U>(OpaquePointer($0)) } }
@inline(__always) func cast<T>(_ p: UnsafeMutablePointer<T>?) -> OpaquePointer? { p.map { OpaquePointer($0) } }
@inline(__always) func cast<U>(_ p: OpaquePointer?) -> UnsafeMutablePointer<U>? { p.map { UnsafeMutablePointer<U>($0) } }
@inline(__always) func cast(_ p: OpaquePointer?) -> OpaquePointer? { p }
@inline(__always) func R<T>(_ p: UnsafeMutablePointer<T>?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }
@inline(__always) func R(_ p: OpaquePointer?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }
func connectRaw(_ raw: UnsafeMutableRawPointer?, _ signal: String, _ cb: GCallback) {
    g_signal_connect_data(raw, signal, cb, nil, nil, GConnectFlags(rawValue: 0))
}
func applyCSS(_ css: String) {
    let p = gtk_css_provider_new(); gtk_css_provider_load_from_string(p, css)
    if let d = gdk_display_get_default() { gtk_style_context_add_provider_for_display(d, cast(p), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)) }
}

let PALETTE: [(Double, Double, Double)] = [
    (0,0,0), (0.5,0.5,0.5), (0.85,0.12,0.12), (0.96,0.55,0.05), (0.98,0.82,0.10),
    (0.18,0.66,0.25), (0.13,0.45,0.90), (0.55,0.25,0.78), (0.6,0.4,0.2), (1,1,1),
]

final class Paint {
    var surface: OpaquePointer?
    var area: UnsafeMutablePointer<GtkWidget>?
    var colorWell: UnsafeMutablePointer<GtkWidget>?
    var sizeLabel: UnsafeMutablePointer<GtkWidget>?
    var tool = "pencil"
    var r = 0.0, g = 0.0, b = 0.0
    var size = 4.0
    let w: Int32 = 1000, h: Int32 = 640
    var dragging = false
    var sx = 0.0, sy = 0.0, cx = 0.0, cy = 0.0, lx = 0.0, ly = 0.0
    var undo: [OpaquePointer] = [], redo: [OpaquePointer] = []

    func newSurface() -> OpaquePointer? { cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h) }
    func fillWhite(_ s: OpaquePointer?) { let cr = cairo_create(s); cairo_set_source_rgb(cr,1,1,1); cairo_paint(cr); cairo_destroy(cr) }
    func copy(_ s: OpaquePointer?) -> OpaquePointer? { let n = newSurface(); let cr = cairo_create(n); cairo_set_source_surface(cr, s, 0, 0); cairo_paint(cr); cairo_destroy(cr); return n }
    func make() { surface = newSurface(); fillWhite(surface) }
    func redraw() { if let a = area { gtk_widget_queue_draw(a) } }
    func pushUndo() { if let s = surface, let c = copy(s) { undo.append(c); if undo.count > 24 { let old = undo.removeFirst(); cairo_surface_destroy(old) } }; redo.forEach { cairo_surface_destroy($0) }; redo = [] }
    func doUndo() { guard let s = surface, !undo.isEmpty else { return }; redo.append(copy(s)!); cairo_surface_destroy(s); surface = undo.removeLast(); redraw() }
    func doRedo() { guard let s = surface, !redo.isEmpty else { return }; undo.append(copy(s)!); cairo_surface_destroy(s); surface = redo.removeLast(); redraw() }
    func clearAll() { pushUndo(); fillWhite(surface); redraw() }

    func strokeSeg(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, erase: Bool = false) {
        let cr = cairo_create(surface)
        if erase { cairo_set_source_rgb(cr,1,1,1) } else { cairo_set_source_rgb(cr,r,g,b) }
        cairo_set_line_width(cr, erase ? size+4 : size)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_move_to(cr, x0, y0); cairo_line_to(cr, x1, y1); cairo_stroke(cr); cairo_destroy(cr); redraw()
    }
    func drawShape(_ cr: OpaquePointer?, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        cairo_set_source_rgb(cr, r, g, b); cairo_set_line_width(cr, size); cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        let x = min(x0,x1), y = min(y0,y1), ww = abs(x1-x0), hh = abs(y1-y0)
        switch tool {
        case "line": cairo_move_to(cr, x0, y0); cairo_line_to(cr, x1, y1); cairo_stroke(cr)
        case "rect": cairo_rectangle(cr, x, y, ww, hh); cairo_stroke(cr)
        case "ellipse":
            cairo_save(cr); cairo_translate(cr, x+ww/2, y+hh/2); cairo_scale(cr, max(ww,1)/2, max(hh,1)/2)
            cairo_arc(cr, 0, 0, 1, 0, 2 * Double.pi); cairo_restore(cr); cairo_stroke(cr)
        default: break
        }
    }
    func commitShape() { let cr = cairo_create(surface); drawShape(cr, sx, sy, cx, cy); cairo_destroy(cr); redraw() }

    func pixel(_ px: Int, _ py: Int) -> (Double, Double, Double)? {
        guard let s = surface, px >= 0, py >= 0, px < Int(w), py < Int(h) else { return nil }
        cairo_surface_flush(s)
        guard let data = cairo_image_surface_get_data(s) else { return nil }
        let stride = Int(cairo_image_surface_get_stride(s)); let i = py*stride + px*4
        return (Double(data[i+2])/255, Double(data[i+1])/255, Double(data[i])/255)   // R,G,B (BGRA mem)
    }
    func fill(_ px: Int, _ py: Int) {
        guard let s = surface else { return }
        pushUndo(); cairo_surface_flush(s)
        guard let data = cairo_image_surface_get_data(s) else { return }
        let stride = Int(cairo_image_surface_get_stride(s)); let W = Int(w), H = Int(h)
        func idx(_ x: Int, _ y: Int) -> Int { y*stride + x*4 }
        let si = idx(px, py)
        let tb = data[si], tg = data[si+1], tr = data[si+2], ta = data[si+3]
        let fb = UInt8(b*255), fg = UInt8(g*255), fr = UInt8(r*255), fa: UInt8 = 255
        if tb == fb && tg == fg && tr == fr && ta == fa { return }
        let tol = 24
        func match(_ i: Int) -> Bool { abs(Int(data[i])-Int(tb)) <= tol && abs(Int(data[i+1])-Int(tg)) <= tol && abs(Int(data[i+2])-Int(tr)) <= tol && abs(Int(data[i+3])-Int(ta)) <= tol }
        var stack = [(px, py)]
        while let (x, y) = stack.popLast() {
            if x < 0 || y < 0 || x >= W || y >= H { continue }
            let i = idx(x, y); if !match(i) { continue }
            data[i] = fb; data[i+1] = fg; data[i+2] = fr; data[i+3] = fa
            stack.append((x+1,y)); stack.append((x-1,y)); stack.append((x,y+1)); stack.append((x,y-1))
        }
        cairo_surface_mark_dirty(s); redraw()
    }
    func save() {
        let path = (ProcessInfo.processInfo.environment["HOME"] ?? ".") + "/Pictures/gtk-paint.png"
        cairo_surface_write_to_png(surface, path); print("Saved: \(path)")
    }
}
let paint = Paint()

// ---- drawing ----
let drawFunc: @convention(c) (UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, UnsafeMutableRawPointer?) -> Void = { _, cr, _, _, _ in
    guard let cr = cr, let s = paint.surface else { return }
    cairo_set_source_surface(cr, s, 0, 0); cairo_paint(cr)
    if paint.dragging && ["line","rect","ellipse"].contains(paint.tool) {
        paint.drawShape(cr, paint.sx, paint.sy, paint.cx, paint.cy)
    }
}
// ---- pointer (drag gesture) ----
let onDragBegin: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, x, y, _ in
    paint.sx = x; paint.sy = y; paint.cx = x; paint.cy = y; paint.lx = x; paint.ly = y; paint.dragging = true
    switch paint.tool {
    case "pencil", "brush": paint.pushUndo(); paint.strokeSeg(x, y, x, y)
    case "eraser": paint.pushUndo(); paint.strokeSeg(x, y, x, y, erase: true)
    case "fill": paint.fill(Int(x), Int(y)); paint.dragging = false
    case "pick": if let c = paint.pixel(Int(x), Int(y)) { paint.r = c.0; paint.g = c.1; paint.b = c.2; paint.redrawWell() }; paint.dragging = false
    case "line", "rect", "ellipse": paint.pushUndo()
    default: break
    }
}
let onDragUpdate: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, ox, oy, _ in
    let x = paint.sx + ox, y = paint.sy + oy; paint.cx = x; paint.cy = y
    switch paint.tool {
    case "pencil", "brush": paint.strokeSeg(paint.lx, paint.ly, x, y); paint.lx = x; paint.ly = y
    case "eraser": paint.strokeSeg(paint.lx, paint.ly, x, y, erase: true); paint.lx = x; paint.ly = y
    case "line", "rect", "ellipse": paint.redraw()
    default: break
    }
}
let onDragEnd: @convention(c) (OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, _, _, _ in
    if ["line","rect","ellipse"].contains(paint.tool) { paint.commitShape() }
    paint.dragging = false
}
extension Paint { func redrawWell() { if let w = colorWell { gtk_widget_queue_draw(w) } } }

let wellDraw: @convention(c) (UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, UnsafeMutableRawPointer?) -> Void = { _, cr, w, h, _ in
    guard let cr = cr else { return }
    cairo_set_source_rgb(cr, paint.r, paint.g, paint.b); cairo_rectangle(cr, 0, 0, Double(w), Double(h)); cairo_fill(cr)
    cairo_set_source_rgb(cr, 0.4, 0.4, 0.4); cairo_set_line_width(cr, 1); cairo_rectangle(cr, 0.5, 0.5, Double(w)-1, Double(h)-1); cairo_stroke(cr)
}

// ---- toolbar callbacks ----
let onTool: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { b, _ in
    guard let b = b, gtk_toggle_button_get_active(cast(b)) != 0, let c = gtk_button_get_label(b) else { return }
    paint.tool = ["Pencil":"pencil","Brush":"brush","Eraser":"eraser","Line":"line","Rect":"rect","Ellipse":"ellipse","Fill":"fill","Pick":"pick"][String(cString: c)] ?? "pencil"
}
let onSwatch: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { b, _ in
    guard let b = b, let c = gtk_button_get_label(b), let i = Int(String(cString: c)) else { return }
    let col = PALETTE[i]; paint.r = col.0; paint.g = col.1; paint.b = col.2; paint.redrawWell()
}
let onUndo: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { _, _ in paint.doUndo() }
let onRedo: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { _, _ in paint.doRedo() }
let onClear: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { _, _ in paint.clearAll() }
let onSave: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { _, _ in paint.save() }
let onDec: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { _, _ in paint.size = max(1, paint.size-2); gtk_label_set_text(cast(paint.sizeLabel), "\(Int(paint.size))px") }
let onInc: @convention(c) (UnsafeMutablePointer<GtkButton>?, UnsafeMutableRawPointer?) -> Void = { _, _ in paint.size = min(80, paint.size+2); gtk_label_set_text(cast(paint.sizeLabel), "\(Int(paint.size))px") }

// ---- activate ----
let onActivate: @convention(c) (UnsafeMutablePointer<GtkApplication>?, UnsafeMutableRawPointer?) -> Void = { app, _ in
    applyCSS("""
    window { background-color: #f2f3f5; }
    box.toolbar { background-color: #e9eaee; padding: 6px 8px; }
    button { background-image: none; background-color: #ffffff; border: none; border-radius: 8px;
             box-shadow: 0 1px 2px rgba(0,0,0,0.06); min-height: 30px; padding: 4px 10px; color: #26282d;
             transition: background-color 110ms ease; }
    button:hover { background-color: #eceef1; }
    togglebutton { background-image: none; background-color: #ffffff; border: none; border-radius: 8px;
                   box-shadow: 0 1px 2px rgba(0,0,0,0.06); min-height: 30px; padding: 4px 11px; color: #26282d; margin: 0 1px; }
    togglebutton:hover { background-color: #eceef1; }
    togglebutton:checked { background-color: #0067c0; color: #ffffff; box-shadow: 0 2px 5px rgba(0,103,192,0.35); }
    separator { background-color: rgba(0,0,0,0.12); margin: 2px 6px; min-width: 1px; }
    scrolledwindow { background-color: #c9ccd1; }
    button.sw { min-width: 24px; min-height: 24px; padding: 0; margin: 0 1px; background-image: none;
                color: transparent; border-radius: 6px; box-shadow: inset 0 0 0 1px rgba(0,0,0,0.15); }
    button.sw:hover { box-shadow: inset 0 0 0 2px #0067c0; }
    .sw0{background-color:#000}.sw1{background-color:#808080}.sw2{background-color:#d91f1f}.sw3{background-color:#f58c0d}.sw4{background-color:#fad11a}
    .sw5{background-color:#2ea841}.sw6{background-color:#2173e6}.sw7{background-color:#8c40c7}.sw8{background-color:#996633}.sw9{background-color:#fff}
    """)
    paint.make()
    let win = gtk_application_window_new(app)
    gtk_window_set_title(cast(win), "Paint")
    gtk_window_set_default_size(cast(win), 1040, 740)

    let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
    gtk_widget_add_css_class(bar, "toolbar")
    gtk_widget_set_margin_top(bar, 6); gtk_widget_set_margin_bottom(bar, 6); gtk_widget_set_margin_start(bar, 8); gtk_widget_set_margin_end(bar, 8)

    // tools (grouped toggles)
    var group: UnsafeMutablePointer<GtkWidget>? = nil
    for name in ["Pencil","Brush","Eraser","Line","Rect","Ellipse","Fill","Pick"] {
        let t = gtk_toggle_button_new_with_label(name)
        if let g = group { gtk_toggle_button_set_group(cast(t), cast(g)) } else { group = t; gtk_toggle_button_set_active(cast(t), 1) }
        connectRaw(R(t), "toggled", unsafeBitCast(onTool, to: GCallback.self))
        gtk_box_append(cast(bar), t)
    }
    gtk_box_append(cast(bar), gtk_separator_new(GTK_ORIENTATION_VERTICAL))
    // palette
    for i in 0..<PALETTE.count {
        let s = gtk_button_new_with_label("\(i)")
        gtk_widget_add_css_class(s, "sw"); gtk_widget_add_css_class(s, "sw\(i)")
        connectRaw(R(s), "clicked", unsafeBitCast(onSwatch, to: GCallback.self))
        gtk_box_append(cast(bar), s)
    }
    let well = gtk_drawing_area_new(); paint.colorWell = well
    gtk_drawing_area_set_content_width(cast(well), 34); gtk_drawing_area_set_content_height(cast(well), 24)
    gtk_drawing_area_set_draw_func(cast(well), wellDraw, nil, nil)
    gtk_box_append(cast(bar), well)
    gtk_box_append(cast(bar), gtk_separator_new(GTK_ORIENTATION_VERTICAL))
    // size
    gtk_box_append(cast(bar), gtk_label_new("Size"))
    let dec = gtk_button_new_with_label("−"); connectRaw(R(dec), "clicked", unsafeBitCast(onDec, to: GCallback.self)); gtk_box_append(cast(bar), dec)
    let sl = gtk_label_new("4px"); paint.sizeLabel = sl; gtk_box_append(cast(bar), sl)
    let inc = gtk_button_new_with_label("+"); connectRaw(R(inc), "clicked", unsafeBitCast(onInc, to: GCallback.self)); gtk_box_append(cast(bar), inc)
    gtk_box_append(cast(bar), gtk_separator_new(GTK_ORIENTATION_VERTICAL))
    // actions
    for (lbl, cb) in [("Undo", onUndo), ("Redo", onRedo), ("Clear", onClear), ("Save", onSave)] {
        let btn = gtk_button_new_with_label(lbl); connectRaw(R(btn), "clicked", unsafeBitCast(cb, to: GCallback.self)); gtk_box_append(cast(bar), btn)
    }

    let area = gtk_drawing_area_new(); paint.area = area
    gtk_drawing_area_set_content_width(cast(area), paint.w); gtk_drawing_area_set_content_height(cast(area), paint.h)
    gtk_widget_set_hexpand(area, 1); gtk_widget_set_vexpand(area, 1)
    gtk_drawing_area_set_draw_func(cast(area), drawFunc, nil, nil)
    let drag = gtk_gesture_drag_new()
    connectRaw(R(drag), "drag-begin", unsafeBitCast(onDragBegin, to: GCallback.self))
    connectRaw(R(drag), "drag-update", unsafeBitCast(onDragUpdate, to: GCallback.self))
    connectRaw(R(drag), "drag-end", unsafeBitCast(onDragEnd, to: GCallback.self))
    gtk_widget_add_controller(area, cast(drag))
    let scroll = gtk_scrolled_window_new()
    gtk_scrolled_window_set_child(cast(scroll), area)
    gtk_widget_set_vexpand(scroll, 1)

    gtk_box_append(cast(root), bar)
    gtk_box_append(cast(root), scroll)
    gtk_window_set_child(cast(win), root)
    gtk_window_present(cast(win))
}

let app = gtk_application_new("com.recreated.gtkpaint", GApplicationFlags(rawValue: 32)) // G_APPLICATION_NON_UNIQUE
connectRaw(R(app), "activate", unsafeBitCast(onActivate, to: GCallback.self))
let status = g_application_run(cast(app), CommandLine.argc, CommandLine.unsafeArgv)
g_object_unref(R(app))
exit(status)
