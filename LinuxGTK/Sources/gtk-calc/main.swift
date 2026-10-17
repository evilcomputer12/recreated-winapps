import CWeb
import Foundation

// native GTK3 window hosting a WebKit view that renders the shared HTML/CSS UI
@inline(__always) func cast<T, U>(_ p: UnsafeMutablePointer<T>?) -> UnsafeMutablePointer<U>? { p.map { UnsafeMutablePointer<U>(OpaquePointer($0)) } }
@inline(__always) func cast<T>(_ p: UnsafeMutablePointer<T>?) -> OpaquePointer? { p.map { OpaquePointer($0) } }
@inline(__always) func cast<U>(_ p: OpaquePointer?) -> UnsafeMutablePointer<U>? { p.map { UnsafeMutablePointer<U>($0) } }
@inline(__always) func cast(_ p: OpaquePointer?) -> OpaquePointer? { p }
@inline(__always) func R<T>(_ p: UnsafeMutablePointer<T>?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }

let onDestroy: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in gtk_main_quit() }
// Any zoom change (Ctrl/Super + scroll or +/-) snaps back to 100% → zoom disabled.
let onZoom: @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { obj, _, _ in
    if webkit_web_view_get_zoom_level(cast(obj)) != 1.0 { webkit_web_view_set_zoom_level(cast(obj), 1.0) }
}

func fullHTML(_ embedded: String) -> String {
    let body = String(data: Data(base64Encoded: embedded) ?? Data(), encoding: .utf8) ?? ""
    return """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>html,body{margin:0;height:100%;overflow:hidden;-webkit-user-select:none;user-select:none}</style>
    </head><body>\(body)</body></html>
    """
}

gtk_init(nil, nil)
let win = gtk_window_new(GTK_WINDOW_TOPLEVEL)
gtk_window_set_title(cast(win), "Calculator")
gtk_window_set_default_size(cast(win), 400, 640)
let web = webkit_web_view_new()
webkit_web_view_set_zoom_level(cast(web), 1.0)
gtk_container_add(cast(win), web)
webkit_web_view_load_html(cast(web), fullHTML(calcHTML), nil)
g_signal_connect_data(R(web), "notify::zoom-level", unsafeBitCast(onZoom, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
g_signal_connect_data(R(win), "destroy", unsafeBitCast(onDestroy, to: GCallback.self), nil, nil, GConnectFlags(rawValue: 0))
gtk_widget_show_all(win)
gtk_main()
