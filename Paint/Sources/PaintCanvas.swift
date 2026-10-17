import AppKit

enum Tool: String { case select, lasso, pencil, brush, airbrush, eraser, fill, picker, text, shape }
enum FillStyle { case outline, solid, both }
enum BrushType: String, CaseIterable { case brush = "Brush", marker = "Marker", watercolour = "Watercolour", crayon = "Crayon", calligraphy = "Calligraphy", oil = "Oil brush" }
enum ShapeKind: String, CaseIterable {
    case line = "Line", polygon = "Polygon", rectangle = "Rectangle", roundRect = "Rounded rectangle", ellipse = "Ellipse",
         triangle = "Triangle", rightTriangle = "Right triangle", diamond = "Diamond",
         pentagon = "Pentagon", hexagon = "Hexagon", star5 = "Five-point star", star6 = "Six-point star",
         arrowRight = "Right arrow", arrowLeft = "Left arrow", arrowUp = "Up arrow", arrowDown = "Down arrow",
         heart = "Heart", lightning = "Lightning"
}

struct LayerInfo: Identifiable, Hashable {
    let id: UUID; var name: String; var visible: Bool; var opacity: Double
}

final class CanvasState: ObservableObject {
    @Published var tool: Tool = .pencil
    @Published var brush: BrushType = .brush
    @Published var shape: ShapeKind = .rectangle
    @Published var primary: NSColor = .black
    @Published var secondary: NSColor = .white
    @Published var colorTarget = 1          // which of color 1/2 the palette edits
    @Published var showLayers = true
    @Published var lineWidth: CGFloat = 4
    @Published var fillStyle: FillStyle = .outline
    @Published var transparentSelection = false
    @Published var showGrid = false
    @Published var showRulers = false
    @Published var fontName = "Helvetica Neue"
    @Published var fontSize: CGFloat = 24
    @Published var bold = false
    @Published var italic = false
    @Published var zoom: CGFloat = 1
    @Published var coords = "—"
    @Published var selSize = ""
    @Published var dims = "900 × 600"
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var layers: [LayerInfo] = []
    @Published var activeLayer = 0
    weak var canvas: PaintCanvasView?
}

final class Layer {
    let id = UUID()
    var rep: NSBitmapImageRep
    var name: String
    var visible = true
    var opacity: CGFloat = 1
    init(rep: NSBitmapImageRep, name: String) { self.rep = rep; self.name = name }
}

final class PaintCanvasView: NSView {
    var state: CanvasState!
    private var px = 900, py = 600
    private var layers: [Layer] = []
    private var active = 0
    private var activeRep: NSBitmapImageRep { layers[active].rep }

    private struct Snap { let layers: [(Data, String, Bool, CGFloat)]; let active: Int; let w: Int; let h: Int }
    private var undoStack: [Snap] = []
    private var redoStack: [Snap] = []

    private var drawing = false
    private var activeColor: NSColor = .black
    private var start = NSPoint.zero
    private var current = NSPoint.zero
    private var previewing = false
    private var airTimer: Timer?

    private var selRect: NSRect?
    private var selImage: NSBitmapImageRep?
    private var movingSel = false
    private var resizingHandle = -1
    private var dragStartRect = NSRect.zero
    private var dragOffset = NSSize.zero
    private var lassoPts: [NSPoint] = []
    private var polyPts: [NSPoint] = []
    private var selClearAction: (() -> Void)?     // clears the original footprint, run on first move/resize
    private var selCleared = false
    private func clearOriginalIfNeeded() { if !selCleared { selClearAction?(); selCleared = true } }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: if selImage != nil { deleteSelection() } else { super.keyDown(with: event) }
        case 36, 76: if !polyPts.isEmpty { commitPolygon() } else if selImage != nil { commitSelection() } else { super.keyDown(with: event) }
        case 53: if !polyPts.isEmpty { polyPts = []; needsDisplay = true } else if selImage != nil { commitSelection() } else { super.keyDown(with: event) }
        default: super.keyDown(with: event)
        }
    }

    // MARK: setup
    func setup(width: Int, height: Int) {
        px = width; py = height
        let base = Layer(rep: makeRep(width, height), name: "Background")
        clearRep(base.rep, color: .white)
        layers = [base]; active = 0
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        undoStack.removeAll(); redoStack.removeAll()
        state?.dims = "\(width) × \(height)"
        publish(); needsDisplay = true
    }
    private func makeRep(_ w: Int, _ h: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, w), pixelsHigh: max(1, h), bitsPerSample: 8,
                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 4*max(1, w), bitsPerPixel: 32)!
    }
    private func clearRep(_ r: NSBitmapImageRep, color: NSColor?) {
        let g = NSGraphicsContext(bitmapImageRep: r)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        if let c = color { c.setFill(); NSRect(x: 0, y: 0, width: r.pixelsWide, height: r.pixelsHigh).fill() }
        else { NSRect(x: 0, y: 0, width: r.pixelsWide, height: r.pixelsHigh).fill(using: .clear) }
        g.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
    }
    private func publish() {
        state.layers = layers.map { LayerInfo(id: $0.id, name: $0.name, visible: $0.visible, opacity: Double($0.opacity)) }
        state.activeLayer = active
    }

    // MARK: context drawing (bottom-left coords)
    private func withContext(_ rep: NSBitmapImageRep, _ body: () -> Void) {
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        body(); g.flushGraphics(); NSGraphicsContext.restoreGraphicsState(); needsDisplay = true
    }
    private func paintSegment(_ a: NSPoint, _ b: NSPoint, color: NSColor) {
        switch state.tool {
        case .pencil: stroke(a, b, color, max(1, state.lineWidth), .square, 1)
        case .eraser: stroke(a, b, .white, state.lineWidth + 2, .round, 1)
        case .brush: paintBrush(a, b, color)
        default: break
        }
    }
    private func paintBrush(_ a: NSPoint, _ b: NSPoint, _ c: NSColor) {
        let w = state.lineWidth
        switch state.brush {
        case .brush: stroke(a, b, c, w, .round, 1)
        case .marker: stroke(a, b, c, w*1.4, .round, 0.4)
        case .watercolour: stroke(a, b, c, w*1.8, .round, 0.14)
        case .oil: stroke(a, b, c, w, .round, 0.9)
        case .calligraphy: stroke(a, b, c, w, .butt, 1)
        case .crayon:
            stroke(a, b, c, w, .round, 0.75)
            withContext(activeRep) {
                c.withAlphaComponent(0.6).setFill()
                let steps = max(1, Int(hypot(b.x-a.x, b.y-a.y)/3))
                for i in 0...steps {
                    let t = CGFloat(i)/CGFloat(max(1, steps))
                    let x = a.x + (b.x-a.x)*t + CGFloat.random(in: -w/2...w/2)
                    let y = a.y + (b.y-a.y)*t + CGFloat.random(in: -w/2...w/2)
                    NSRect(x: x, y: y, width: 1.4, height: 1.4).fill()
                }
            }
        }
    }
    private func stroke(_ a: NSPoint, _ b: NSPoint, _ color: NSColor, _ width: CGFloat, _ cap: NSBezierPath.LineCapStyle, _ alpha: CGFloat) {
        withContext(activeRep) {
            let p = NSBezierPath(); p.move(to: a); p.line(to: b)
            p.lineWidth = width; p.lineCapStyle = cap; p.lineJoinStyle = .round
            color.withAlphaComponent(alpha).setStroke(); p.stroke()
        }
    }
    private func dot(_ a: NSPoint, color: NSColor, width: CGFloat, alpha: CGFloat = 1) {
        withContext(activeRep) { color.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: a.x-width/2, y: a.y-width/2, width: width, height: width)).fill() }
    }
    private func spray(_ a: NSPoint, color: NSColor) {
        withContext(activeRep) { color.setFill(); let r = state.lineWidth*1.4
            for _ in 0..<Int(max(6, state.lineWidth)) {
                let ang = Double.random(in: 0..<(2*Double.pi)); let d = Double.random(in: 0...Double(r))
                NSRect(x: a.x + CGFloat(cos(ang)*d), y: a.y + CGFloat(sin(ang)*d), width: 1, height: 1).fill()
            } }
    }

    // MARK: pixels
    private func toPixel(_ p: NSPoint) -> (Int, Int) { (Int(p.x.rounded()), py - 1 - Int(p.y.rounded())) }
    private func pickColor(_ p: NSPoint) -> NSColor {
        let (x, y) = toPixel(p); let flat = flatten()
        guard x >= 0, y >= 0, x < px, y < py else { return .white }
        return flat.colorAt(x: x, y: y) ?? .white
    }
    private func floodFill(_ p: NSPoint, color: NSColor) {
        let (sx, sy) = toPixel(p)
        guard sx >= 0, sy >= 0, sx < px, sy < py, let data = activeRep.bitmapData else { return }
        let bpr = activeRep.bytesPerRow
        let conv = color.usingColorSpace(.deviceRGB) ?? color
        let fr = UInt8(conv.redComponent*255), fg = UInt8(conv.greenComponent*255), fb = UInt8(conv.blueComponent*255), fa: UInt8 = 255
        func idx(_ x: Int, _ y: Int) -> Int { y*bpr + x*4 }
        let s = idx(sx, sy)
        let tr = data[s], tg = data[s+1], tb = data[s+2], ta = data[s+3]
        if abs(Int(tr)-Int(fr)) <= 1 && abs(Int(tg)-Int(fg)) <= 1 && abs(Int(tb)-Int(fb)) <= 1 && ta == fa { return }
        let tol = 40
        func m(_ i: Int) -> Bool { abs(Int(data[i])-Int(tr)) <= tol && abs(Int(data[i+1])-Int(tg)) <= tol && abs(Int(data[i+2])-Int(tb)) <= tol && abs(Int(data[i+3])-Int(ta)) <= tol }
        var stack = [(sx, sy)]
        while let (cx, cy) = stack.popLast() {
            if cx < 0 || cy < 0 || cx >= px || cy >= py { continue }
            let i = idx(cx, cy); if !m(i) { continue }
            data[i] = fr; data[i+1] = fg; data[i+2] = fb; data[i+3] = fa
            stack.append((cx+1, cy)); stack.append((cx-1, cy)); stack.append((cx, cy+1)); stack.append((cx, cy-1))
        }
        needsDisplay = true
    }

    // MARK: undo / redo
    private func makeSnap() -> Snap {
        Snap(layers: layers.map { ($0.rep.representation(using: .png, properties: [:]) ?? Data(), $0.name, $0.visible, $0.opacity) }, active: active, w: px, h: py)
    }
    func beginChange() { commitText(); undoStack.append(makeSnap()); if undoStack.count > 30 { undoStack.removeFirst() }; redoStack.removeAll(); sync() }
    func undo() { commitSelection(); guard let s = undoStack.popLast() else { return }; redoStack.append(makeSnap()); apply(s); sync() }
    func redo() { guard let s = redoStack.popLast() else { return }; undoStack.append(makeSnap()); apply(s); sync() }
    private func apply(_ s: Snap) {
        px = s.w; py = s.h
        layers = s.layers.map { (data, name, vis, op) in
            let l = Layer(rep: NSBitmapImageRep(data: data) ?? makeRep(px, py), name: name); l.visible = vis; l.opacity = op; return l
        }
        active = min(s.active, layers.count-1)
        frame = NSRect(x: 0, y: 0, width: px, height: py); state.dims = "\(px) × \(py)"
        publish(); needsDisplay = true
    }
    private func sync() { state.canUndo = !undoStack.isEmpty; state.canRedo = !redoStack.isEmpty }

    // MARK: mouse
    override func mouseDown(with e: NSEvent) { begin(e, color: state.primary) }
    override func mouseDragged(with e: NSEvent) { drag(e) }
    override func mouseUp(with e: NSEvent) { end(e) }
    override func rightMouseDown(with e: NSEvent) { begin(e, color: state.secondary) }
    override func rightMouseDragged(with e: NSEvent) { drag(e) }
    override func rightMouseUp(with e: NSEvent) { end(e) }
    private var polyCursor = NSPoint.zero
    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil); state.coords = coordStr(p)
        if state.tool == .shape, state.shape == .polygon, !polyPts.isEmpty { polyCursor = p; needsDisplay = true }
    }
    private func coordStr(_ p: NSPoint) -> String { "\(Int(p.x)), \(py - Int(p.y))" }

    private func begin(_ e: NSEvent, color: NSColor) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        activeColor = color; start = p; current = p; drawing = true; state.coords = coordStr(p)
        switch state.tool {
        case .picker: let c = pickColor(p); if color == state.secondary { state.secondary = c } else { state.primary = c }; drawing = false
        case .text: drawing = false; placeText(at: p)
        case .select: selectBegin(p)
        case .lasso: lassoBegin(p)
        case .shape where state.shape == .polygon:
            drawing = false
            if e.clickCount >= 2 { commitPolygon(); return }
            if polyPts.isEmpty { beginChange() }
            polyPts.append(p); needsDisplay = true
        case .fill: beginChange(); floodFill(p, color: color); drawing = false
        case .pencil: beginChange(); dot(p, color: color, width: max(1, state.lineWidth))
        case .brush: beginChange(); dot(p, color: color, width: state.lineWidth)
        case .eraser: beginChange(); dot(p, color: .white, width: state.lineWidth + 2)
        case .airbrush: beginChange(); spray(p, color: color)
            airTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in guard let s = self else { return }; s.spray(s.current, color: color) }
        case .shape: beginChange(); previewing = true
        }
    }
    private func drag(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil); current = p; state.coords = coordStr(p)
        guard drawing else { return }
        switch state.tool {
        case .pencil, .brush, .eraser: paintSegment(start, p, color: activeColor); start = p
        case .airbrush: break
        case .select: selectDrag(p)
        case .lasso: lassoPts.append(p); needsDisplay = true
        case .shape: needsDisplay = true
        default: break
        }
    }
    private func end(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        airTimer?.invalidate(); airTimer = nil
        if drawing, previewing, !(state.tool == .shape && state.shape == .polygon) { withContext(activeRep) { drawShape(start, p) }; previewing = false }
        if state.tool == .select { selectEnd(p) }
        if state.tool == .lasso { lassoEnd(p) }
        drawing = false
    }

    // MARK: shapes
    private func shapePath(_ a: NSPoint, _ b: NSPoint) -> NSBezierPath {
        let path = NSBezierPath()
        let x = min(a.x, b.x), y = min(a.y, b.y), w = abs(b.x-a.x), h = abs(b.y-a.y)
        let r = NSRect(x: x, y: y, width: w, height: h); let cx = r.midX, cy = r.midY
        func poly(_ sides: Int, _ rot: CGFloat) {
            for i in 0..<sides {
                let ang = rot + CGFloat(i) * 2 * .pi / CGFloat(sides)
                let pt = NSPoint(x: cx + cos(ang)*w/2, y: cy + sin(ang)*h/2)
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.close()
        }
        func star(_ points: Int) {
            for i in 0..<(points*2) {
                let rad: CGFloat = (i % 2 == 0) ? 1.0 : 0.42
                let ang = .pi/2 + CGFloat(i) * .pi / CGFloat(points)
                let pt = NSPoint(x: cx + cos(ang)*w/2*rad, y: cy + sin(ang)*h/2*rad)
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.close()
        }
        switch state.shape {
        case .line: path.move(to: a); path.line(to: b)
        case .rectangle: path.appendRect(r)
        case .roundRect: path.appendRoundedRect(r, xRadius: min(24, w/2), yRadius: min(24, h/2))
        case .ellipse: path.appendOval(in: r)
        case .triangle: path.move(to: NSPoint(x: cx, y: r.maxY)); path.line(to: NSPoint(x: r.minX, y: r.minY)); path.line(to: NSPoint(x: r.maxX, y: r.minY)); path.close()
        case .rightTriangle: path.move(to: NSPoint(x: r.minX, y: r.maxY)); path.line(to: NSPoint(x: r.minX, y: r.minY)); path.line(to: NSPoint(x: r.maxX, y: r.minY)); path.close()
        case .diamond: path.move(to: NSPoint(x: cx, y: r.maxY)); path.line(to: NSPoint(x: r.maxX, y: cy)); path.line(to: NSPoint(x: cx, y: r.minY)); path.line(to: NSPoint(x: r.minX, y: cy)); path.close()
        case .pentagon: poly(5, .pi/2)
        case .hexagon: poly(6, 0)
        case .star5: star(5)
        case .star6: star(6)
        case .arrowRight, .arrowLeft, .arrowUp, .arrowDown: arrow(r, path)
        case .heart: heart(r, path)
        case .lightning:
            let pts = [NSPoint(x: 0.55, y: 1), NSPoint(x: 0.2, y: 0.5), NSPoint(x: 0.45, y: 0.5),
                       NSPoint(x: 0.25, y: 0), NSPoint(x: 0.8, y: 0.62), NSPoint(x: 0.5, y: 0.62), NSPoint(x: 0.7, y: 1)]
            let mapped = pts.map { NSPoint(x: r.minX + $0.x*r.width, y: r.minY + $0.y*r.height) }
            path.move(to: mapped[0]); mapped.dropFirst().forEach { path.line(to: $0) }; path.close()
        case .polygon: break
        }
        return path
    }
    private func arrow(_ r: NSRect, _ path: NSBezierPath) {
        // build right arrow in unit then transform for direction
        let w = r.width, h = r.height
        let sh = h*0.3, hw = w*0.45
        var pts = [NSPoint(x: 0, y: h/2+sh/2), NSPoint(x: w-hw, y: h/2+sh/2), NSPoint(x: w-hw, y: h),
                   NSPoint(x: w, y: h/2), NSPoint(x: w-hw, y: 0), NSPoint(x: w-hw, y: h/2-sh/2), NSPoint(x: 0, y: h/2-sh/2)]
        func tf(_ p: NSPoint) -> NSPoint {
            switch state.shape {
            case .arrowLeft: return NSPoint(x: w-p.x, y: p.y)
            case .arrowUp: return NSPoint(x: p.y, y: p.x)
            case .arrowDown: return NSPoint(x: p.y, y: h-p.x)
            default: return p
            }
        }
        pts = pts.map { NSPoint(x: r.minX + tf($0).x, y: r.minY + tf($0).y) }
        path.move(to: pts[0]); pts.dropFirst().forEach { path.line(to: $0) }; path.close()
    }
    private func heart(_ r: NSRect, _ path: NSBezierPath) {
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        path.move(to: NSPoint(x: x+w/2, y: y+h*0.28))
        path.curve(to: NSPoint(x: x, y: y+h*0.7), controlPoint1: NSPoint(x: x+w*0.3, y: y), controlPoint2: NSPoint(x: x, y: y+h*0.35))
        path.curve(to: NSPoint(x: x+w/2, y: y+h), controlPoint1: NSPoint(x: x, y: y+h*0.9), controlPoint2: NSPoint(x: x+w*0.3, y: y+h))
        path.curve(to: NSPoint(x: x+w, y: y+h*0.7), controlPoint1: NSPoint(x: x+w*0.7, y: y+h), controlPoint2: NSPoint(x: x+w, y: y+h*0.9))
        path.curve(to: NSPoint(x: x+w/2, y: y+h*0.28), controlPoint1: NSPoint(x: x+w, y: y+h*0.35), controlPoint2: NSPoint(x: x+w*0.7, y: y))
        path.close()
    }
    private func drawShape(_ a: NSPoint, _ b: NSPoint) {
        let path = shapePath(a, b)
        path.lineWidth = state.lineWidth; path.lineJoinStyle = .round; path.lineCapStyle = .round
        let other = (activeColor == state.primary) ? state.secondary : state.primary
        if state.shape != .line {
            if state.fillStyle == .solid { activeColor.setFill(); path.fill() }
            else if state.fillStyle == .both { other.setFill(); path.fill() }
        }
        if state.fillStyle != .solid || state.shape == .line { activeColor.setStroke(); path.stroke() }
    }

    // MARK: selection (with resize handles)
    private var handleR: CGFloat { max(7, 10 / max(state?.zoom ?? 1, 0.15)) }
    private func handleCenters(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.maxX, y: r.midY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY)]
    }
    private func handleHit(_ p: NSPoint, _ r: NSRect) -> Int {
        for (i, c) in handleCenters(r).enumerated() { if abs(p.x-c.x) <= handleR && abs(p.y-c.y) <= handleR { return i } }
        return -1
    }
    private func resizeRect(_ s: NSRect, _ h: Int, _ p: NSPoint) -> NSRect {
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        switch h {
        case 0: minX = p.x; minY = p.y
        case 1: minY = p.y
        case 2: maxX = p.x; minY = p.y
        case 3: maxX = p.x
        case 4: maxX = p.x; maxY = p.y
        case 5: maxY = p.y
        case 6: minX = p.x; maxY = p.y
        case 7: minX = p.x
        default: break
        }
        if maxX-minX < 6 { if [0, 6, 7].contains(h) { minX = maxX-6 } else { maxX = minX+6 } }
        if maxY-minY < 6 { if [0, 1, 2].contains(h) { minY = maxY-6 } else { maxY = minY+6 } }
        return NSRect(x: minX, y: minY, width: maxX-minX, height: maxY-minY)
    }
    private func selectBegin(_ p: NSPoint) {
        if let r = selRect, selImage != nil {
            let h = handleHit(p, r); if h >= 0 { clearOriginalIfNeeded(); resizingHandle = h; dragStartRect = r; return }
            if r.contains(p) { clearOriginalIfNeeded(); movingSel = true; dragOffset = NSSize(width: p.x-r.minX, height: p.y-r.minY); return }
        }
        commitSelection(); beginChange(); selRect = NSRect(origin: p, size: .zero); start = p
    }
    private func selectDrag(_ p: NSPoint) {
        if resizingHandle >= 0 { selRect = resizeRect(dragStartRect, resizingHandle, p); updateSelSize(); needsDisplay = true; return }
        if movingSel, let r = selRect { selRect = NSRect(x: p.x-dragOffset.width, y: p.y-dragOffset.height, width: r.width, height: r.height); needsDisplay = true; return }
        selRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x-start.x), height: abs(p.y-start.y)); updateSelSize(); needsDisplay = true
    }
    private func selectEnd(_ p: NSPoint) {
        if resizingHandle >= 0 { resizingHandle = -1; return }
        if movingSel { movingSel = false; return }
        guard var r = selRect, r.width > 2, r.height > 2 else { selRect = nil; state.selSize = ""; if !undoStack.isEmpty { undoStack.removeLast(); sync() }; needsDisplay = true; return }
        r = r.intersection(NSRect(x: 0, y: 0, width: px, height: py))
        liftSelection(from: r)
    }
    private func updateSelSize() { if let r = selRect { state.selSize = "\(Int(r.width)) × \(Int(r.height))" } }
    private func liftSelection(from r: NSRect) {
        let cap = makeRep(Int(r.width), Int(r.height))
        withContext(cap) { activeRep.draw(in: NSRect(x: 0, y: 0, width: r.width, height: r.height), from: r, operation: .copy, fraction: 1, respectFlipped: false, hints: nil) }
        if state.transparentSelection { makeTransparent(cap, color: state.secondary) }
        selImage = cap; selRect = r; updateSelSize()
        selCleared = false
        selClearAction = { [weak self] in guard let s = self else { return }; s.withContext(s.activeRep) { NSColor.white.setFill(); r.fill() } }
    }
    func commitSelection() {
        if let img = selImage, let r = selRect { withContext(activeRep) { NSGraphicsContext.current?.imageInterpolation = .high; img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil) } }
        selImage = nil; selRect = nil; selClearAction = nil; state.selSize = ""; needsDisplay = true
    }
    func deleteSelection() { clearOriginalIfNeeded(); selImage = nil; selRect = nil; selClearAction = nil; state.selSize = ""; needsDisplay = true }
    func selectAll() { commitSelection(); state.tool = .select; beginChange(); liftSelection(from: NSRect(x: 0, y: 0, width: px, height: py)) }

    // MARK: lasso (free-form)
    private func lassoBegin(_ p: NSPoint) { commitSelection(); beginChange(); lassoPts = [p] }
    private func lassoEnd(_ p: NSPoint) {
        guard lassoPts.count > 2 else { lassoPts = []; if !undoStack.isEmpty { undoStack.removeLast(); sync() }; return }
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minY
        for pt in lassoPts { minX = min(minX, pt.x); minY = min(minY, pt.y); maxX = max(maxX, pt.x); maxY = max(maxY, pt.y) }
        let r = NSRect(x: minX, y: minY, width: maxX-minX, height: maxY-minY).intersection(NSRect(x: 0, y: 0, width: px, height: py))
        guard r.width > 2, r.height > 2 else { lassoPts = []; return }
        let path = NSBezierPath(); path.move(to: lassoPts[0]); lassoPts.dropFirst().forEach { path.line(to: $0) }; path.close()
        let cap = makeRep(Int(r.width), Int(r.height))
        withContext(cap) {
            let shifted = path.copy() as! NSBezierPath
            let t = AffineTransform(translationByX: -r.minX, byY: -r.minY); shifted.transform(using: t); shifted.addClip()
            activeRep.draw(in: NSRect(x: -r.minX, y: -r.minY, width: CGFloat(px), height: CGFloat(py)))
        }
        if state.transparentSelection { makeTransparent(cap, color: state.secondary) }
        let pathCopy = path.copy() as! NSBezierPath
        selCleared = false
        selClearAction = { [weak self] in guard let s = self else { return }; s.withContext(s.activeRep) { pathCopy.addClip(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: s.px, height: s.py).fill() } }
        selImage = cap; selRect = r; updateSelSize(); lassoPts = []; state.tool = .select
    }

    // MARK: polygon shape
    func commitPolygon() {
        guard polyPts.count > 1 else { polyPts = []; return }
        withContext(activeRep) {
            let path = NSBezierPath(); path.move(to: polyPts[0]); polyPts.dropFirst().forEach { path.line(to: $0) }; path.close()
            path.lineWidth = state.lineWidth; path.lineJoinStyle = .round
            let other = (activeColor == state.primary) ? state.secondary : state.primary
            if state.fillStyle == .solid { activeColor.setFill(); path.fill() }
            else if state.fillStyle == .both { other.setFill(); path.fill(); activeColor.setStroke(); path.stroke() }
            else { activeColor.setStroke(); path.stroke() }
        }
        polyPts = []; needsDisplay = true
    }
    private func makeTransparent(_ rep: NSBitmapImageRep, color: NSColor) {
        guard let d = rep.bitmapData else { return }
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let cr = UInt8(c.redComponent*255), cg = UInt8(c.greenComponent*255), cb = UInt8(c.blueComponent*255)
        let n = rep.bytesPerRow*rep.pixelsHigh
        var i = 0; while i < n { if abs(Int(d[i])-Int(cr)) <= 12 && abs(Int(d[i+1])-Int(cg)) <= 12 && abs(Int(d[i+2])-Int(cb)) <= 12 { d[i+3] = 0 }; i += 4 }
    }

    // MARK: text
    private var textField: NSTextField?
    private func currentFont() -> NSFont {
        var f = NSFont(name: state.fontName, size: state.fontSize) ?? NSFont.systemFont(ofSize: state.fontSize)
        var traits: NSFontTraitMask = []
        if state.bold { traits.insert(.boldFontMask) }
        if state.italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty { f = NSFontManager.shared.convert(f, toHaveTrait: traits) }
        return f
    }
    private func placeText(at p: NSPoint) {
        commitText()
        let font = currentFont(); let fs = state.fontSize
        let tf = NSTextField(frame: NSRect(x: p.x, y: p.y-fs, width: 280, height: fs+10))
        tf.isBordered = false; tf.drawsBackground = false; tf.focusRingType = .none
        tf.font = font; tf.textColor = activeColor; tf.placeholderString = "Text"
        tf.target = self; tf.action = #selector(textCommitted)
        addSubview(tf); window?.makeFirstResponder(tf); textField = tf
    }
    @objc private func textCommitted() { commitText() }
    func commitText() {
        guard let tf = textField else { return }
        let s = tf.stringValue, origin = NSPoint(x: tf.frame.minX, y: tf.frame.minY)
        let color = tf.textColor ?? .black, font = tf.font ?? NSFont.systemFont(ofSize: 16)
        tf.removeFromSuperview(); textField = nil
        guard !s.isEmpty else { return }
        undoStack.append(makeSnap()); redoStack.removeAll(); sync()
        withContext(activeRep) { (s as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: color]) }
    }

    // MARK: image ops
    private func mapRep(_ src: NSBitmapImageRep, outW: Int, outH: Int, _ map: (Int, Int) -> (Int, Int)) -> NSBitmapImageRep {
        let out = makeRep(outW, outH)
        guard let s = src.bitmapData, let d = out.bitmapData else { return out }
        let sbpr = src.bytesPerRow, dbpr = out.bytesPerRow, sw = src.pixelsWide, sh = src.pixelsHigh
        for oy in 0..<outH { for ox in 0..<outW {
            let (sx, sy) = map(ox, oy); let di = oy*dbpr + ox*4
            if sx >= 0, sy >= 0, sx < sw, sy < sh { let si = sy*sbpr + sx*4; d[di] = s[si]; d[di+1] = s[si+1]; d[di+2] = s[si+2]; d[di+3] = s[si+3] }
            else { d[di+3] = 0 }
        }}
        return out
    }
    func rotate(cw: Bool) {
        beginChange(); commitSelection()
        for l in layers { l.rep = mapRep(l.rep, outW: py, outH: px) { ox, oy in cw ? (oy, px-1-ox) : (py-1-oy, ox) } }
        swap(&px, &py); frame = NSRect(x: 0, y: 0, width: px, height: py); state.dims = "\(px) × \(py)"; needsDisplay = true
    }
    func flip(horizontal: Bool) {
        beginChange(); commitSelection()
        for l in layers { l.rep = mapRep(l.rep, outW: px, outH: py) { ox, oy in horizontal ? (px-1-ox, oy) : (ox, py-1-oy) } }
        needsDisplay = true
    }
    func rotate180() {
        beginChange(); commitSelection()
        for l in layers { l.rep = mapRep(l.rep, outW: px, outH: py) { ox, oy in (px-1-ox, py-1-oy) } }
        needsDisplay = true
    }
    func resizeImage(_ w: Int, _ h: Int) {   // resample (scale) content
        beginChange(); commitSelection()
        for l in layers { let old = l.rep; let nr = makeRep(w, h); clearRep(nr, color: nil)
            withContext(nr) { NSGraphicsContext.current?.imageInterpolation = .high; old.draw(in: NSRect(x: 0, y: 0, width: w, height: h)) }
            l.rep = nr }
        px = w; py = h; frame = NSRect(x: 0, y: 0, width: w, height: h); state.dims = "\(w) × \(h)"; needsDisplay = true
    }
    func invertColors() {
        beginChange()
        guard let d = activeRep.bitmapData else { return }
        let n = activeRep.bytesPerRow*activeRep.pixelsHigh
        var i = 0; while i < n { d[i] = 255-d[i]; d[i+1] = 255-d[i+1]; d[i+2] = 255-d[i+2]; i += 4 }
        needsDisplay = true
    }
    func cropToSelection() {
        guard let r = selRect else { return }
        let x0 = Int(r.minX), top = py - Int(r.maxY), w = Int(r.width), h = Int(r.height)
        commitSelection(); beginChange()
        for l in layers { l.rep = mapRep(l.rep, outW: w, outH: h) { ox, oy in (x0+ox, top+oy) } }
        px = w; py = h; frame = NSRect(x: 0, y: 0, width: w, height: h); state.dims = "\(w) × \(h)"; selRect = nil; needsDisplay = true
    }
    func resize(_ w: Int, _ h: Int) {
        beginChange(); commitSelection()
        for l in layers { let old = l.rep; let nr = makeRep(w, h); clearRep(nr, color: nil)
            withContext(nr) { old.draw(in: NSRect(x: 0, y: CGFloat(h-old.pixelsHigh), width: CGFloat(old.pixelsWide), height: CGFloat(old.pixelsHigh))) }
            l.rep = nr }
        // background white fill on bottom layer
        px = w; py = h; frame = NSRect(x: 0, y: 0, width: w, height: h); state.dims = "\(w) × \(h)"; needsDisplay = true
    }

    // MARK: clipboard
    func copySelection() {
        let img: NSImage
        if let sel = selImage, let r = selRect { let i = NSImage(size: r.size); i.addRepresentation(sel); img = i }
        else { img = NSImage(size: NSSize(width: px, height: py)); img.addRepresentation(flatten()) }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img])
    }
    func cutSelection() { copySelection(); if selImage != nil { deleteSelection() } }
    func paste() {
        guard let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        commitSelection(); beginChange(); state.tool = .select
        if state.transparentSelection { makeTransparent(rep, color: state.secondary) }
        selImage = rep; let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        selRect = NSRect(x: 10, y: CGFloat(py)-h-10, width: w, height: h); updateSelSize()
        selClearAction = nil; selCleared = true            // pasted content has no original footprint to clear
        needsDisplay = true
    }

    // Standard Edit-menu responder actions (so ⌘C/⌘X/⌘V/⌘A/Delete work).
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    @objc func copy(_ sender: Any?) { copySelection() }
    @objc func cut(_ sender: Any?) { cutSelection() }
    @objc func paste(_ sender: Any?) { paste() }
    @objc override func selectAll(_ sender: Any?) { selectAll() }
    @objc func delete(_ sender: Any?) { if selImage != nil { deleteSelection() } }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): return selImage != nil
        default: return true
        }
    }

    // MARK: layers API
    func addLayer() { beginChange(); let l = Layer(rep: makeRep(px, py), name: "Layer \(layers.count)"); clearRep(l.rep, color: nil); layers.insert(l, at: active+1); active += 1; publish(); needsDisplay = true }
    func deleteLayer() { guard layers.count > 1 else { return }; beginChange(); layers.remove(at: active); active = max(0, active-1); publish(); needsDisplay = true }
    func duplicateLayer() { beginChange(); let src = layers[active]; let nr = makeRep(px, py); clearRep(nr, color: nil); let g = NSGraphicsContext(bitmapImageRep: nr)!; NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g; src.rep.draw(at: .zero); g.flushGraphics(); NSGraphicsContext.restoreGraphicsState(); let l = Layer(rep: nr, name: src.name + " copy"); layers.insert(l, at: active+1); active += 1; publish(); needsDisplay = true }
    func selectLayer(_ i: Int) { guard i >= 0, i < layers.count else { return }; active = i; publish() }
    func toggleVisible(_ i: Int) { guard i < layers.count else { return }; layers[i].visible.toggle(); publish(); needsDisplay = true }
    func setOpacity(_ i: Int, _ v: Double) { guard i < layers.count else { return }; layers[i].opacity = CGFloat(v); publish(); needsDisplay = true }
    func moveLayer(up: Bool) { let j = active + (up ? 1 : -1); guard j >= 0, j < layers.count else { return }; beginChange(); layers.swapAt(active, j); active = j; publish(); needsDisplay = true }
    func mergeDown() { guard active > 0 else { return }; beginChange(); let top = layers[active], below = layers[active-1]
        withContext(below.rep) { top.rep.draw(in: NSRect(x: 0, y: 0, width: px, height: py), from: .zero, operation: .sourceOver, fraction: top.opacity, respectFlipped: false, hints: nil) }
        layers.remove(at: active); active -= 1; publish(); needsDisplay = true }

    // MARK: file
    private func flatten() -> NSBitmapImageRep {
        let out = makeRep(px, py); clearRep(out, color: .white)
        let g = NSGraphicsContext(bitmapImageRep: out)!; NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        for l in layers where l.visible { l.rep.draw(in: NSRect(x: 0, y: 0, width: px, height: py), from: .zero, operation: .sourceOver, fraction: l.opacity, respectFlipped: false, hints: nil) }
        g.flushGraphics(); NSGraphicsContext.restoreGraphicsState(); return out
    }
    func clearCanvas() { beginChange(); commitSelection(); clearRep(activeRep, color: .white); needsDisplay = true }
    func newDocument() { setup(width: 900, height: 600) }
    func loadImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation, let src = NSBitmapImageRep(data: tiff) else { return }
        beginChange(); px = src.pixelsWide; py = src.pixelsHigh
        let base = Layer(rep: makeRep(px, py), name: "Background"); clearRep(base.rep, color: .white)
        withContext(base.rep) { src.draw(in: NSRect(x: 0, y: 0, width: px, height: py)) }
        layers = [base]; active = 0; frame = NSRect(x: 0, y: 0, width: px, height: py); state.dims = "\(px) × \(py)"
        publish(); needsDisplay = true
    }
    func currentImage() -> NSImage { let img = NSImage(size: NSSize(width: px, height: py)); img.addRepresentation(flatten()); return img }

    // Programmatic sample for snapshot verification.
    func demo() {
        withContext(activeRep) {
            NSColor.systemTeal.setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: 60, y: 520)); line.line(to: NSPoint(x: 300, y: 430)); line.lineWidth = 6; line.lineCapStyle = .round; line.stroke()
            NSColor.systemOrange.setFill(); NSColor.black.setStroke()
            let rect = NSBezierPath(rect: NSRect(x: 80, y: 250, width: 180, height: 120)); rect.lineWidth = 4; rect.fill(); rect.stroke()
            NSColor.systemPurple.setFill()
            NSBezierPath(ovalIn: NSRect(x: 330, y: 250, width: 160, height: 160)).fill()
            NSColor.systemRed.setStroke()
            let star = NSBezierPath(); let cx: CGFloat = 620, cy: CGFloat = 330, R: CGFloat = 90
            for i in 0..<10 { let rad = i % 2 == 0 ? R : R*0.42; let a = CGFloat.pi/2 + CGFloat(i) * .pi/5; let p = NSPoint(x: cx+cos(a)*rad, y: cy+sin(a)*rad); if i == 0 { star.move(to: p) } else { star.line(to: p) } }
            star.close(); star.lineWidth = 4; star.stroke()
            NSColor.systemBlue.setStroke()
            let free = NSBezierPath(); free.move(to: NSPoint(x: 540, y: 500))
            for t in stride(from: 0.0, through: 1.0, by: 0.03) { free.line(to: NSPoint(x: 540 + t*260, y: 500 + sin(t*12)*26)) }
            free.lineWidth = 3; free.lineCapStyle = .round; free.stroke()
            ("Paint — recreated" as NSString).draw(at: NSPoint(x: 80, y: 150), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 32), .foregroundColor: NSColor.black])
        }
        // demonstrate select → copy → paste → (resizable floating selection with handles)
        state.tool = .select
        liftSelection(from: NSRect(x: 470, y: 230, width: 330, height: 210))
        copySelection()          // → NSPasteboard
        commitSelection()        // stamp original back (deferred-clear means nothing was erased)
        paste()                  // ← NSPasteboard: floating copy at top-left with handles
        needsDisplay = true
    }

    // MARK: draw
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        for l in layers where l.visible { l.rep.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: l.opacity, respectFlipped: false, hints: nil) }
        if state.showGrid {
            NSColor(white: 0.5, alpha: 0.28).setStroke(); let g = NSBezierPath(); g.lineWidth = 0.6
            var x: CGFloat = 0; while x <= CGFloat(px) { g.move(to: NSPoint(x: x, y: 0)); g.line(to: NSPoint(x: x, y: CGFloat(py))); x += 32 }
            var y: CGFloat = 0; while y <= CGFloat(py) { g.move(to: NSPoint(x: 0, y: y)); g.line(to: NSPoint(x: CGFloat(px), y: y)); y += 32 }
            g.stroke()
        }
        if drawing && previewing { drawShape(start, current) }
        if state.tool == .lasso, drawing, lassoPts.count > 1 {
            NSColor.controlAccentColor.setStroke(); let lp = NSBezierPath(); lp.move(to: lassoPts[0]); lassoPts.dropFirst().forEach { lp.line(to: $0) }
            lp.lineWidth = 1; lp.setLineDash([4, 3], count: 2, phase: 0); lp.stroke()
        }
        if state.tool == .shape, state.shape == .polygon, !polyPts.isEmpty {
            activeColor.setStroke(); let pp = NSBezierPath(); pp.move(to: polyPts[0]); polyPts.dropFirst().forEach { pp.line(to: $0) }; pp.line(to: polyCursor)
            pp.lineWidth = state.lineWidth; pp.lineJoinStyle = .round; pp.stroke()
        }
        if let r = selRect {
            if let img = selImage { NSGraphicsContext.current?.imageInterpolation = .high; img.draw(in: r) }
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: r); p.lineWidth = 1; p.setLineDash([4, 3], count: 2, phase: 0); p.stroke()
            if selImage != nil {
                for c in handleCenters(r) {
                    let hr = NSRect(x: c.x-handleR, y: c.y-handleR, width: handleR*2, height: handleR*2)
                    NSColor.white.setFill(); NSBezierPath(ovalIn: hr).fill()
                    NSColor.controlAccentColor.setStroke(); let hp = NSBezierPath(ovalIn: hr); hp.lineWidth = 1.5; hp.stroke()
                }
            }
        }
    }
}
