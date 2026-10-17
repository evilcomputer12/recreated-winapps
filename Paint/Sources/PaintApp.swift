import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    static func findCanvas(in v: NSView) -> PaintCanvasView? {
        if let c = v as? PaintCanvasView { return c }
        for sub in v.subviews { if let c = findCanvas(in: sub) { return c } }
        return nil
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i+1 < args.count else { return }
        let path = args[i+1]
        let demo = args.contains("--demo")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) ?? NSApp.windows.first,
                  let v = w.contentView else { NSApp.terminate(nil); return }
            if demo, let cv = Self.findCanvas(in: v) { cv.demo() }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { NSApp.terminate(nil); return }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: URL(fileURLWithPath: path)) }
            NSApp.terminate(nil)
        }
    }
}

@main
struct PaintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = CanvasState()
    var body: some Scene {
        WindowGroup {
            PaintRootView().environmentObject(state).frame(minWidth: 940, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { state.canvas?.newDocument() }.keyboardShortcut("n")
                Button("Open…") { PaintIO.open(state) }.keyboardShortcut("o")
                Button("Save As…") { PaintIO.save(state) }.keyboardShortcut("s")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { state.canvas?.undo() }.keyboardShortcut("z").disabled(!state.canUndo)
                Button("Redo") { state.canvas?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!state.canRedo)
            }
            CommandMenu("Image") {
                Button("Rotate right 90°") { state.canvas?.rotate(cw: true) }
                Button("Rotate left 90°") { state.canvas?.rotate(cw: false) }
                Button("Rotate 180°") { state.canvas?.rotate180() }
                Button("Flip horizontal") { state.canvas?.flip(horizontal: true) }
                Button("Flip vertical") { state.canvas?.flip(horizontal: false) }
                Divider()
                Button("Crop to selection") { state.canvas?.cropToSelection() }
                Button("Invert colours") { state.canvas?.invertColors() }
            }
            CommandMenu("View") {
                Toggle("Gridlines", isOn: $state.showGrid)
                Toggle("Rulers", isOn: $state.showRulers)
                Divider()
                Button("Zoom in") { state.zoom = min(8, state.zoom*1.25) }.keyboardShortcut("+", modifiers: .command)
                Button("Zoom out") { state.zoom = max(0.1, state.zoom/1.25) }.keyboardShortcut("-", modifiers: .command)
                Button("Actual size (100%)") { state.zoom = 1 }.keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

enum PaintIO {
    static func open(_ s: CanvasState) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heic]
        if p.runModal() == .OK, let u = p.url, let img = NSImage(contentsOf: u) { s.canvas?.loadImage(img) }
    }
    static func save(_ s: CanvasState) {
        guard let c = s.canvas else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif]; p.nameFieldStringValue = "Untitled.png"
        if p.runModal() == .OK, let u = p.url {
            let ext = u.pathExtension.lowercased()
            let t: NSBitmapImageRep.FileType
            switch ext { case "jpg", "jpeg": t = .jpeg; case "tif", "tiff": t = .tiff; case "bmp": t = .bmp; case "gif": t = .gif; default: t = .png }
            if let tiff = c.currentImage().tiffRepresentation, let r = NSBitmapImageRep(data: tiff),
               let d = r.representation(using: t, properties: [:]) { try? d.write(to: u) }
        }
    }
}

// MARK: - Root
struct PaintRootView: View {
    @EnvironmentObject var state: CanvasState
    var body: some View {
        VStack(spacing: 0) {
            CommandBar()
            Divider()
            if state.tool == .text { TextFormatBar(); Divider() }
            HStack(spacing: 0) {
                CanvasRepresentable(state: state).background(Color(nsColor: NSColor(white: 0.74, alpha: 1)))
                if state.showLayers { Divider(); LayersPanel().frame(width: 234) }
            }
            Divider()
            StatusBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Command bar
struct CommandBar: View {
    @EnvironmentObject var state: CanvasState
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ToolCluster(icon: "arrow.uturn.backward", label: "Undo") { state.canvas?.undo() }.disabled(!state.canUndo)
                ToolCluster(icon: "arrow.uturn.forward", label: "Redo") { state.canvas?.redo() }.disabled(!state.canRedo)
                sep
                ToolCluster(icon: "doc.on.clipboard", label: "Paste") { state.canvas?.paste() }
                ToolCluster(icon: "scissors", label: "Cut") { state.canvas?.cutSelection() }
                ToolCluster(icon: "doc.on.doc", label: "Copy") { state.canvas?.copySelection() }
                sep
                SelectMenu()
                ToolToggle(.pencil, "pencil", "Pencil")
                FillPicker()
                ToolToggle(.text, "textformat", "Text")
                ToolToggle(.eraser, "eraser", "Eraser")
                ToolToggle(.picker, "eyedropper", "Colour picker")
                sep
                BrushesMenu()
                ShapesGallery()
                sep
                SizeMenu()
                sep
                ColorsBlock()
                sep
                ImageMenu()
                ToolCluster(icon: "square.3.layers.3d", label: "Layers", active: state.showLayers) { state.showLayers.toggle() }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(height: 70)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    var sep: some View { Divider().frame(height: 48).padding(.horizontal, 2) }
}

// Generic command-bar button with icon over a small label (Win11 style)
struct ToolCluster: View {
    let icon: String; let label: String; var active: Bool = false; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 16)).frame(height: 20)
                Text(label).font(.system(size: 9))
            }
            .frame(width: 50, height: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.22) : (hover ? Color.primary.opacity(0.07) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        .onHover { hover = $0 }
    }
}

struct ToolToggle: View {
    @EnvironmentObject var state: CanvasState
    let tool: Tool; let icon: String; let label: String
    init(_ t: Tool, _ i: String, _ l: String) { tool = t; icon = i; label = l }
    var body: some View {
        ToolCluster(icon: icon, label: label, active: state.tool == tool) {
            state.canvas?.commitText(); if tool != .select { state.canvas?.commitSelection() }
            state.tool = tool
        }
    }
}

struct SelectMenu: View {
    @EnvironmentObject var state: CanvasState
    var body: some View {
        Menu {
            Button("Rectangular selection") { state.tool = .select }
            Button("Free-form selection") { state.tool = .lasso }
            Button("Select all") { state.canvas?.selectAll() }
            Button("Delete") { state.canvas?.deleteSelection() }
            Divider()
            Toggle("Transparent selection", isOn: $state.transparentSelection)
        } label: {
            VStack(spacing: 2) { Image(systemName: "dashed.rectangle").font(.system(size: 16)).frame(height: 20); Text("Select").font(.system(size: 9)) }
                .frame(width: 50, height: 52)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .background(RoundedRectangle(cornerRadius: 6).fill(state.tool == .select || state.tool == .lasso ? Color.accentColor.opacity(0.22) : .clear))
    }
}

struct FillPicker: View {
    @EnvironmentObject var state: CanvasState
    var body: some View { ToolToggle(.fill, "drop.fill", "Fill") }
}

struct BrushesMenu: View {
    @EnvironmentObject var state: CanvasState
    var body: some View {
        Menu {
            ForEach(BrushType.allCases, id: \.self) { b in
                Button { state.brush = b; state.tool = .brush; state.canvas?.commitSelection() } label: {
                    Label(b.rawValue, systemImage: state.brush == b && state.tool == .brush ? "checkmark" : "paintbrush")
                }
            }
        } label: {
            VStack(spacing: 2) { Image(systemName: "paintbrush.pointed.fill").font(.system(size: 16)).frame(height: 20); Text("Brushes").font(.system(size: 9)) }
                .frame(width: 56, height: 52)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .background(RoundedRectangle(cornerRadius: 6).fill(state.tool == .brush ? Color.accentColor.opacity(0.22) : .clear))
    }
}

struct ShapesGallery: View {
    @EnvironmentObject var state: CanvasState
    @State private var show = false
    let cols = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 5)
    var body: some View {
        Button { show.toggle() } label: {
            VStack(spacing: 2) {
                HStack(spacing: 3) { ShapeIcon(kind: .rectangle); ShapeIcon(kind: .ellipse) }.frame(height: 20)
                Text("Shapes").font(.system(size: 9))
            }.frame(width: 56, height: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(state.tool == .shape ? Color.accentColor.opacity(0.22) : .clear))
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shapes").font(.headline)
                LazyVGrid(columns: cols, spacing: 6) {
                    ForEach(ShapeKind.allCases, id: \.self) { k in
                        Button { state.shape = k; state.tool = .shape; state.canvas?.commitSelection(); show = false } label: {
                            ShapeIcon(kind: k).frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 5).fill(state.shape == k ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                        }.buttonStyle(.plain).help(k.rawValue)
                    }
                }
                Divider()
                Picker("Fill", selection: $state.fillStyle) { Text("Outline").tag(FillStyle.outline); Text("Fill").tag(FillStyle.solid); Text("Both").tag(FillStyle.both) }
                    .pickerStyle(.radioGroup)
            }.padding(12).frame(width: 240)
        }
    }
}

struct SizeMenu: View {
    @EnvironmentObject var state: CanvasState
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            VStack(spacing: 2) { Image(systemName: "lineweight").font(.system(size: 16)).frame(height: 20); Text("Size").font(.system(size: 9)) }
                .frame(width: 50, height: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Size: \(Int(state.lineWidth)) px").font(.subheadline)
                Slider(value: $state.lineWidth, in: 1...80).frame(width: 180)
                HStack(spacing: 10) {
                    ForEach([1, 3, 5, 8, 16], id: \.self) { w in
                        Button { state.lineWidth = CGFloat(w) } label: {
                            Capsule().fill(Color.primary).frame(width: 34, height: max(1, CGFloat(w)))
                                .frame(height: 20)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(14)
        }
    }
}

struct ColorsBlock: View {
    @EnvironmentObject var state: CanvasState
    private var editBinding: Binding<Color> {
        Binding(get: { Color(nsColor: state.colorTarget == 1 ? state.primary : state.secondary) },
                set: { if state.colorTarget == 1 { state.primary = NSColor($0) } else { state.secondary = NSColor($0) } })
    }
    let palette: [NSColor] = [
        .black, NSColor(white: 0.5, alpha: 1), NSColor(red: 0.53, green: 0, blue: 0.08, alpha: 1), .red, .orange, .systemYellow, .green, NSColor(red: 0, green: 0.64, blue: 0.91, alpha: 1), .blue, .purple,
        .white, NSColor(white: 0.75, alpha: 1), .brown, .systemPink, NSColor(red: 1, green: 0.79, blue: 0.06, alpha: 1), NSColor(red: 0.94, green: 0.89, blue: 0.69, alpha: 1), NSColor(red: 0.71, green: 0.9, blue: 0.11, alpha: 1), .cyan, NSColor(red: 0.44, green: 0.57, blue: 0.75, alpha: 1), .magenta]
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                swatch(state.secondary, size: 26).offset(x: 9, y: 9)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(state.colorTarget == 2 ? Color.accentColor : Color.primary.opacity(0.3), lineWidth: state.colorTarget == 2 ? 2 : 1).offset(x: 9, y: 9))
                    .onTapGesture { state.colorTarget = 2 }
                swatch(state.primary, size: 28)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(state.colorTarget == 1 ? Color.accentColor : Color.primary.opacity(0.3), lineWidth: state.colorTarget == 1 ? 2 : 1))
                    .onTapGesture { state.colorTarget = 1 }
            }.frame(width: 46, height: 46)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 3), count: 10), spacing: 3) {
                ForEach(palette.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: palette[i])).frame(width: 16, height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.18)))
                        .onTapGesture { if state.colorTarget == 1 { state.primary = palette[i] } else { state.secondary = palette[i] } }
                }
            }.frame(width: 185)
            VStack(spacing: 2) {
                ColorPicker("", selection: editBinding).labelsHidden().frame(width: 36)
                Text("Edit").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    func swatch(_ c: NSColor, size: CGFloat) -> some View { RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: c)).frame(width: size, height: size) }
}

struct ImageMenu: View {
    @EnvironmentObject var state: CanvasState
    @State private var show = false
    var body: some View {
        Menu {
            Button("Rotate right 90°") { state.canvas?.rotate(cw: true) }
            Button("Rotate left 90°") { state.canvas?.rotate(cw: false) }
            Button("Rotate 180°") { state.canvas?.rotate180() }
            Button("Flip horizontal") { state.canvas?.flip(horizontal: true) }
            Button("Flip vertical") { state.canvas?.flip(horizontal: false) }
            Divider()
            Button("Crop to selection") { state.canvas?.cropToSelection() }
            Button("Invert colours") { state.canvas?.invertColors() }
            Divider()
            Button("Resize image… (scale)") { resize(scale: true) }
            Button("Resize canvas…") { resize(scale: false) }
        } label: {
            VStack(spacing: 2) { Image(systemName: "crop.rotate").font(.system(size: 16)).frame(height: 20); Text("Image").font(.system(size: 9)) }.frame(width: 50, height: 52)
        }.menuStyle(.borderlessButton).fixedSize()
    }
    func resize(scale: Bool) {
        let a = NSAlert(); a.messageText = scale ? "Resize image (scale content)" : "Resize canvas"
        let s = NSStackView(frame: NSRect(x: 0, y: 0, width: 230, height: 28)); s.spacing = 6
        let wf = NSTextField(string: state.dims.components(separatedBy: " ").first ?? "900"); wf.frame.size = NSSize(width: 70, height: 22)
        let hf = NSTextField(string: state.dims.components(separatedBy: " ").last ?? "600"); hf.frame.size = NSSize(width: 70, height: 22)
        s.addArrangedSubview(NSTextField(labelWithString: "W")); s.addArrangedSubview(wf)
        s.addArrangedSubview(NSTextField(labelWithString: "H")); s.addArrangedSubview(hf)
        a.accessoryView = s; a.addButton(withTitle: "Resize"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            let w = max(1, Int(wf.stringValue) ?? 900), h = max(1, Int(hf.stringValue) ?? 600)
            if scale { state.canvas?.resizeImage(w, h) } else { state.canvas?.resize(w, h) }
        }
    }
}

struct TextFormatBar: View {
    @EnvironmentObject var state: CanvasState
    let fonts = ["Helvetica Neue", "Arial", "Times New Roman", "Courier New", "Georgia", "Verdana", "Comic Sans MS", "Impact", "Menlo", "Snell Roundhand"]
    var body: some View {
        HStack(spacing: 12) {
            Picker("Font", selection: $state.fontName) { ForEach(fonts, id: \.self) { Text($0).font(.system(size: 12)) } }.frame(width: 190)
            HStack(spacing: 5) { Text("Size").font(.system(size: 11)); Slider(value: $state.fontSize, in: 8...120).frame(width: 120); Text("\(Int(state.fontSize))").font(.system(size: 11)).monospacedDigit().frame(width: 28) }
            Toggle(isOn: $state.bold) { Image(systemName: "bold") }.toggleStyle(.button)
            Toggle(isOn: $state.italic) { Image(systemName: "italic") }.toggleStyle(.button)
            Text("Click the canvas to place text; press Return to set.").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }.padding(.horizontal, 12).padding(.vertical, 5).background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Shape preview icon
struct ShapeIcon: View {
    let kind: ShapeKind
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(x: 4, y: 4, width: size.width-8, height: size.height-8)
            let cx = r.midX, cy = r.midY
            var p = Path()
            func poly(_ n: Int, _ rot: CGFloat) { for i in 0..<n { let a = rot + CGFloat(i)*2 * .pi/CGFloat(n); let pt = CGPoint(x: cx+cos(a)*r.width/2, y: cy+sin(a)*r.height/2); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) } }; p.closeSubpath() }
            func star(_ n: Int) { for i in 0..<(n*2) { let rad: CGFloat = i % 2 == 0 ? 1 : 0.42; let a = -CGFloat.pi/2 + CGFloat(i) * .pi/CGFloat(n); let pt = CGPoint(x: cx+cos(a)*r.width/2*rad, y: cy+sin(a)*r.height/2*rad); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) } }; p.closeSubpath() }
            switch kind {
            case .line: p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            case .rectangle: p.addRect(r)
            case .roundRect: p = Path(roundedRect: r, cornerRadius: 5)
            case .ellipse: p.addEllipse(in: r)
            case .triangle: p.move(to: CGPoint(x: cx, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.closeSubpath()
            case .rightTriangle: p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.closeSubpath()
            case .diamond: p.move(to: CGPoint(x: cx, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: cy)); p.addLine(to: CGPoint(x: cx, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: cy)); p.closeSubpath()
            case .pentagon: poly(5, -.pi/2)
            case .hexagon: poly(6, 0)
            case .star5: star(5)
            case .star6: star(6)
            case .arrowRight: p.move(to: CGPoint(x: r.minX, y: cy)); p.addLine(to: CGPoint(x: r.maxX-6, y: cy)); p.move(to: CGPoint(x: r.maxX-9, y: cy-5)); p.addLine(to: CGPoint(x: r.maxX, y: cy)); p.addLine(to: CGPoint(x: r.maxX-9, y: cy+5))
            case .arrowLeft: p.move(to: CGPoint(x: r.maxX, y: cy)); p.addLine(to: CGPoint(x: r.minX+6, y: cy)); p.move(to: CGPoint(x: r.minX+9, y: cy-5)); p.addLine(to: CGPoint(x: r.minX, y: cy)); p.addLine(to: CGPoint(x: r.minX+9, y: cy+5))
            case .arrowUp: p.move(to: CGPoint(x: cx, y: r.maxY)); p.addLine(to: CGPoint(x: cx, y: r.minY+6)); p.move(to: CGPoint(x: cx-5, y: r.minY+9)); p.addLine(to: CGPoint(x: cx, y: r.minY)); p.addLine(to: CGPoint(x: cx+5, y: r.minY+9))
            case .arrowDown: p.move(to: CGPoint(x: cx, y: r.minY)); p.addLine(to: CGPoint(x: cx, y: r.maxY-6)); p.move(to: CGPoint(x: cx-5, y: r.maxY-9)); p.addLine(to: CGPoint(x: cx, y: r.maxY)); p.addLine(to: CGPoint(x: cx+5, y: r.maxY-9))
            case .heart:
                let w = r.width, h = r.height, x = r.minX, y = r.minY
                p.move(to: CGPoint(x: x+w/2, y: y+h*0.72))
                p.addCurve(to: CGPoint(x: x, y: y+h*0.3), control1: CGPoint(x: x+w*0.3, y: y+h), control2: CGPoint(x: x, y: y+h*0.6))
                p.addCurve(to: CGPoint(x: x+w/2, y: y+h*0.02), control1: CGPoint(x: x, y: y+h*0.08), control2: CGPoint(x: x+w*0.3, y: y))
                p.addCurve(to: CGPoint(x: x+w, y: y+h*0.3), control1: CGPoint(x: x+w*0.7, y: y), control2: CGPoint(x: x+w, y: y+h*0.08))
                p.addCurve(to: CGPoint(x: x+w/2, y: y+h*0.72), control1: CGPoint(x: x+w, y: y+h*0.6), control2: CGPoint(x: x+w*0.7, y: y+h))
            case .polygon: poly(5, -.pi/2)
            case .lightning:
                let pts = [CGPoint(x: 0.6, y: 0), CGPoint(x: 0.3, y: 0.45), CGPoint(x: 0.5, y: 0.45), CGPoint(x: 0.35, y: 1), CGPoint(x: 0.78, y: 0.4), CGPoint(x: 0.52, y: 0.4), CGPoint(x: 0.66, y: 0)]
                let m = pts.map { CGPoint(x: r.minX+$0.x*r.width, y: r.minY+$0.y*r.height) }
                p.move(to: m[0]); m.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath()
            }
            ctx.stroke(p, with: .color(.primary), lineWidth: 1.4)
        }
    }
}

// MARK: - Layers panel
struct LayersPanel: View {
    @EnvironmentObject var state: CanvasState
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Layers").font(.headline); Spacer() }.padding(10)
            HStack(spacing: 4) {
                tool("plus", "Add layer") { state.canvas?.addLayer() }
                tool("plus.square.on.square", "Duplicate") { state.canvas?.duplicateLayer() }
                tool("trash", "Delete") { state.canvas?.deleteLayer() }
                tool("arrow.up", "Move up") { state.canvas?.moveLayer(up: true) }
                tool("arrow.down", "Move down") { state.canvas?.moveLayer(up: false) }
                tool("arrow.triangle.merge", "Merge down") { state.canvas?.mergeDown() }
            }.padding(.horizontal, 8).padding(.bottom, 6)
            Divider()
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(state.layers.enumerated().reversed()), id: \.element.id) { idx, info in
                        LayerRow(index: idx, info: info)
                    }
                }.padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    func tool(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 30, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        .help(help)
    }
}

struct LayerRow: View {
    @EnvironmentObject var state: CanvasState
    let index: Int; let info: LayerInfo
    var active: Bool { state.activeLayer == index }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { state.canvas?.toggleVisible(index) } label: { Image(systemName: info.visible ? "eye" : "eye.slash").foregroundStyle(info.visible ? Color.primary : .secondary) }.buttonStyle(.plain)
                Text(info.name).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                Spacer()
            }
            if active {
                HStack(spacing: 6) {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { info.opacity }, set: { state.canvas?.setOpacity(index, $0) }), in: 0...1)
                    Text("\(Int(info.opacity*100))%").font(.system(size: 10)).monospacedDigit().frame(width: 34)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.accentColor.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { state.canvas?.selectLayer(index) }
    }
}

// MARK: - Status bar
struct StatusBar: View {
    @EnvironmentObject var state: CanvasState
    var body: some View {
        HStack(spacing: 14) {
            Label(state.coords, systemImage: "cursorarrow").font(.system(size: 11)).monospacedDigit()
            Label(state.dims, systemImage: "ruler").font(.system(size: 11))
            if !state.selSize.isEmpty { Label(state.selSize, systemImage: "selection.pin.in.out").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary) }
            Button("Clear") { state.canvas?.clearCanvas() }.buttonStyle(.link).font(.system(size: 11))
            Toggle(isOn: $state.showGrid) { Image(systemName: "grid") }.toggleStyle(.button).controlSize(.small).help("Gridlines")
            Toggle(isOn: $state.showRulers) { Image(systemName: "ruler") }.toggleStyle(.button).controlSize(.small).help("Rulers")
            Spacer()
            Text(state.tool == .shape ? state.shape.rawValue : state.tool.rawValue.capitalized).font(.system(size: 11)).foregroundStyle(.secondary)
            Button { state.zoom = max(0.1, state.zoom/1.25) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.plain)
            Slider(value: $state.zoom, in: 0.1...8).frame(width: 130)
            Button { state.zoom = min(8, state.zoom*1.25) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.plain)
            Button("\(Int(state.zoom*100))%") { state.zoom = 1 }.buttonStyle(.plain).font(.system(size: 11)).monospacedDigit().frame(width: 46).help("Reset to 100%")
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Canvas bridge
struct CanvasRepresentable: NSViewRepresentable {
    @ObservedObject var state: CanvasState
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.allowsMagnification = true; scroll.minMagnification = 0.1; scroll.maxMagnification = 8
        scroll.backgroundColor = NSColor(white: 0.74, alpha: 1); scroll.drawsBackground = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 26, left: 26, bottom: 26, right: 26)
        let canvas = PaintCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        canvas.wantsLayer = true
        canvas.layer?.shadowColor = NSColor.black.cgColor
        canvas.layer?.shadowOpacity = 0.3; canvas.layer?.shadowRadius = 6
        canvas.layer?.shadowOffset = CGSize(width: 0, height: -2); canvas.layer?.masksToBounds = false
        canvas.state = state; state.canvas = canvas; canvas.setup(width: 900, height: 600)
        scroll.documentView = canvas
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if abs(scroll.magnification - state.zoom) > 0.001 { scroll.magnification = state.zoom }
        if scroll.rulersVisible != state.showRulers { scroll.rulersVisible = state.showRulers; scroll.hasHorizontalRuler = state.showRulers; scroll.hasVerticalRuler = state.showRulers }
    }
}
