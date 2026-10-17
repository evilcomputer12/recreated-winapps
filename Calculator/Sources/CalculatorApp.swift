import SwiftUI
import AppKit

// MARK: - Mode
enum Mode: Hashable {
    case standard, scientific, programmer, graphing, date
    case converter(String)
}

// MARK: - App model
final class AppModel: ObservableObject {
    @Published var mode: Mode = .standard
    @Published var history: [HistoryItem] = []
    @Published var memory: [Double] = []
    @Published var keepOnTop = false
    let graph = GraphVM()
    func toggleKeepOnTop() { keepOnTop.toggle(); NSApp.windows.forEach { $0.level = keepOnTop ? .floating : .normal } }

    let standard = StandardVM()
    let scientific = ScientificVM()
    let programmer = ProgrammerVM()
    let dateVM = DateVM()
    @Published var converter = ConverterVM(Converters.all[0])

    private var monitor: Any?

    static weak var shared: AppModel?
    init() {
        standard.history = { [weak self] e, r in self?.history.insert(HistoryItem(expr: e, result: r), at: 0) }
        scientific.history = { [weak self] e, r in self?.history.insert(HistoryItem(expr: e, result: r), at: 0) }
        installKeyMonitor()
        AppModel.shared = self
    }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    var showsHistory: Bool { if case .standard = mode { return true }; if case .scientific = mode { return true }; return false }

    // Memory
    var hasMemory: Bool { !memory.isEmpty }
    func currentValue() -> Double {
        switch mode {
        case .standard: return standard.value
        case .scientific: return Double(scientific.display.replacingOccurrences(of: ",", with: "")) ?? 0
        default: return 0
        }
    }
    func recall(_ v: Double) {
        switch mode {
        case .standard: standard.setValue(v)
        case .scientific: scientific.setValue(v)
        case .programmer: programmer.setValue(v)
        default: break
        }
    }
    func memoryOp(_ op: String) {
        let v = currentValue()
        switch op {
        case "MS": memory.insert(v, at: 0)
        case "M+": if memory.isEmpty { memory.insert(v, at: 0) } else { memory[0] += v }
        case "M-": if memory.isEmpty { memory.insert(-v, at: 0) } else { memory[0] -= v }
        case "MC": memory.removeAll()
        case "MR": if let f = memory.first { recall(f) }
        default: break
        }
    }

    // Keyboard
    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self else { return ev }
            if let r = NSApp.keyWindow?.firstResponder, r is NSTextView { return ev }
            if ev.modifierFlags.contains(.command) { return ev }
            return self.handleKey(ev) ? nil : ev
        }
    }
    private func handleKey(_ ev: NSEvent) -> Bool {
        let chars = ev.charactersIgnoringModifiers ?? ""
        let key = ev.keyCode
        switch mode {
        case .standard: return route(chars, key, digit: standard.digit, op: { standard.setOp($0) }, eq: standard.equals, back: standard.backspace, clr: standard.clearAll, dot: { standard.digit(".") })
        case .scientific: return route(chars, key, digit: scientific.digit, op: { scientific.op($0) }, eq: scientific.equals, back: scientific.backspace, clr: scientific.clear, dot: { scientific.digit(".") })
        case .programmer:
            if let c = chars.first, c.isHexDigit { if programmer.isEnabled(String(c).uppercased()) { programmer.digit(String(c).uppercased()); return true } }
            return route(chars, key, digit: programmer.digit, op: { programmer.setOp(String($0)) }, eq: programmer.equals, back: programmer.backspace, clr: programmer.clearAll, dot: {})
        case .converter:
            if let c = chars.first, c.isNumber { converter.key(String(c)); objectWillChange.send(); return true }
            if chars == "." { converter.key("."); objectWillChange.send(); return true }
            if key == 51 { converter.key("back"); objectWillChange.send(); return true }
            if key == 53 { converter.key("C"); objectWillChange.send(); return true }
            return false
        default: return false
        }
    }
    private func route(_ chars: String, _ key: UInt16, digit: (String)->Void, op: (Character)->Void, eq: ()->Void, back: ()->Void, clr: ()->Void, dot: ()->Void) -> Bool {
        if let c = chars.first, c.isNumber { digit(String(c)); return true }
        switch chars {
        case "+": op("+"); return true
        case "-": op("-"); return true
        case "*": op("*"); return true
        case "/": op("/"); return true
        case ".": dot(); return true
        case "=": eq(); return true
        default: break
        }
        if key == 36 || key == 76 { eq(); return true }   // return / enter
        if key == 51 { back(); return true }               // delete
        if key == 53 { clr(); return true }                // escape
        return false
    }
}

final class CalcAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i+1 < args.count else { return }
        let path = args[i+1]
        if let mi = args.firstIndex(of: "--mode"), mi+1 < args.count {
            let m = args[mi+1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                switch m { case "programmer": AppModel.shared?.mode = .programmer
                case "graphing": AppModel.shared?.mode = .graphing
                case "scientific": AppModel.shared?.mode = .scientific
                default: break }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) ?? NSApp.windows.first,
                  let v = w.contentView else { NSApp.terminate(nil); return }
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
            w.setContentSize(NSSize(width: 520, height: 640)); v.displayIfNeeded(); v.display()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { NSApp.terminate(nil); return }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: URL(fileURLWithPath: path)) }
            NSApp.terminate(nil)
        }
    }
}

// MARK: - App
@main
struct CalculatorApp: App {
    @NSApplicationDelegateAdaptor(CalcAppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .frame(minWidth: 460, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("View") {
                Button("Standard") { model.mode = .standard }.keyboardShortcut("1", modifiers: .command)
                Button("Scientific") { model.mode = .scientific }.keyboardShortcut("2", modifiers: .command)
                Button("Programmer") { model.mode = .programmer }.keyboardShortcut("3", modifiers: .command)
                Button("Graphing") { model.mode = .graphing }.keyboardShortcut("4", modifiers: .command)
                Button("Date Calculation") { model.mode = .date }.keyboardShortcut("5", modifiers: .command)
                Divider()
                Toggle("Keep on top", isOn: Binding(get: { model.keepOnTop }, set: { _ in model.toggleKeepOnTop() })).keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - Key button
enum KeyKind { case digit, op, fn, equals }
struct KeyButton: View {
    let label: String
    var kind: KeyKind = .digit
    var enabled: Bool = true
    var fontSize: CGFloat = 19
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: fontSize, weight: kind == .equals ? .semibold : .regular))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(bg)
        )
        .foregroundStyle(kind == .equals ? Color.white : Color.primary)
        .opacity(enabled ? 1 : 0.35)
        .onHover { h in hover = h && enabled }
        .disabled(!enabled)
    }
    private var bg: Color {
        switch kind {
        case .equals: return hover ? Color.accentColor.opacity(0.85) : Color.accentColor
        case .digit: return hover ? Color.primary.opacity(0.14) : Color.primary.opacity(0.06)
        case .op, .fn: return hover ? Color.primary.opacity(0.16) : Color.primary.opacity(0.10)
        }
    }
}

// MARK: - Content
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showHistory = false
    @State private var showMemory = false
    var body: some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            VStack(spacing: 0) {
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                if model.showsHistory {
                    ToolbarItem {
                        Button { showHistory.toggle() } label: { Image(systemName: "clock") }
                            .popover(isPresented: $showHistory) { HistoryView().environmentObject(model).frame(width: 300, height: 360) }
                    }
                    ToolbarItem {
                        Button { showMemory.toggle() } label: { Image(systemName: "m.square") }
                            .popover(isPresented: $showMemory) { MemoryView().environmentObject(model).frame(width: 260, height: 300) }
                    }
                }
            }
        }
    }
    @ViewBuilder var detail: some View {
        switch model.mode {
        case .standard: StandardView(vm: model.standard)
        case .scientific: ScientificView(vm: model.scientific)
        case .programmer: ProgrammerView(vm: model.programmer)
        case .graphing: GraphingView(vm: model.graph)
        case .date: DateView(vm: model.dateVM)
        case .converter(let name): ConverterView(categoryName: name, vm: model.converter)
        }
    }
}

// MARK: - Sidebar
struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List(selection: Binding(get: { model.mode }, set: { if let m = $0 { select(m) } })) {
            Section("Calculator") {
                row(.standard, "Standard", "number.square")
                row(.scientific, "Scientific", "function")
                row(.programmer, "Programmer", "chevron.left.forwardslash.chevron.right")
                row(.graphing, "Graphing", "chart.xyaxis.line")
                row(.date, "Date Calculation", "calendar")
            }
            Section("Converter") {
                ForEach(Converters.all, id: \.name) { cat in
                    row(.converter(cat.name), cat.name, cat.symbol)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 210)
    }
    func select(_ m: Mode) {
        if case .converter(let n) = m, let cat = Converters.all.first(where: { $0.name == n }) { model.converter.setCategory(cat) }
        model.mode = m
    }
    func row(_ m: Mode, _ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).tag(m)
    }
}

// MARK: - Display
struct DisplayView: View {
    let expr: String
    let result: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(expr).font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(1).truncationMode(.head)
            Text(result).font(.system(size: 46, weight: .semibold)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.3)
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 6)
        .frame(minHeight: 120, alignment: .bottom)
    }
}

// MARK: - Memory bar
struct MemoryBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 2) {
            memBtn("MC", enabled: model.hasMemory)
            memBtn("MR", enabled: model.hasMemory)
            memBtn("M+"); memBtn("M-"); memBtn("MS")
        }
        .padding(.horizontal, 12)
    }
    func memBtn(_ t: String, enabled: Bool = true) -> some View {
        Button(t.replacingOccurrences(of: "M-", with: "M−")) { model.memoryOp(t) }
            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.4))
            .frame(maxWidth: .infinity, minHeight: 30).disabled(!enabled)
    }
}

// MARK: - Standard view
struct StandardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var vm: StandardVM
    let rows: [[(String, KeyKind, String)]] = [
        [("%", .op, "pct"), ("CE", .op, "ce"), ("C", .op, "c"), ("⌫", .op, "back")],
        [("¹⁄ₓ", .op, "recip"), ("x²", .op, "sqr"), ("²√x", .op, "sqrt"), ("÷", .op, "/")],
        [("7", .digit, "7"), ("8", .digit, "8"), ("9", .digit, "9"), ("×", .op, "*")],
        [("4", .digit, "4"), ("5", .digit, "5"), ("6", .digit, "6"), ("−", .op, "-")],
        [("1", .digit, "1"), ("2", .digit, "2"), ("3", .digit, "3"), ("+", .op, "+")],
        [("±", .digit, "neg"), ("0", .digit, "0"), (".", .digit, "."), ("=", .equals, "eq")],
    ]
    var body: some View {
        VStack(spacing: 0) {
            DisplayView(expr: vm.expression, result: vm.display)
            MemoryBar()
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r], id: \.2) { k in
                            KeyButton(label: k.0, kind: k.1) { act(k.2) }
                        }
                    }
                }
            }.padding(10)
        }
    }
    func act(_ a: String) {
        switch a {
        case "ce": vm.clearEntry(); case "c": vm.clearAll(); case "back": vm.backspace(); case "eq": vm.equals()
        case "+","-","*","/": vm.setOp(Character(a))
        case "pct","sqr","sqrt","recip","neg": vm.unary(a)
        default: vm.digit(a)
        }
    }
}

// MARK: - Scientific view
struct ScientificView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var vm: ScientificVM
    var body: some View {
        VStack(spacing: 0) {
            DisplayView(expr: vm.expression, result: vm.display)
            HStack(spacing: 3) {
                ForEach(["DEG","RAD","GRAD"], id: \.self) { a in
                    Button(a) { vm.angle = a; objectWillChangeHack() }
                        .buttonStyle(.plain).font(.system(size: 12))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(vm.angle == a ? Color.accentColor : Color.primary.opacity(0.08)))
                        .foregroundStyle(vm.angle == a ? .white : .primary)
                }
                Button("HYP") { vm.hyp.toggle(); objectWillChangeHack() }
                    .buttonStyle(.plain).font(.system(size: 12))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(vm.hyp ? Color.accentColor : Color.primary.opacity(0.08)))
                    .foregroundStyle(vm.hyp ? .white : .primary)
            }.padding(.horizontal, 10).padding(.bottom, 3)
            MemoryBar()
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow {
                    KeyButton(label: "2nd", kind: .fn, fontSize: 14) { vm.second.toggle(); objectWillChangeHack() }
                    KeyButton(label: "π", kind: .fn, fontSize: 15) { vm.konst("pi") }
                    KeyButton(label: "e", kind: .fn, fontSize: 15) { vm.konst("e") }
                    KeyButton(label: "CE", kind: .fn, fontSize: 15) { vm.clear() }
                    KeyButton(label: "C", kind: .fn, fontSize: 15) { vm.clear() }
                }
                GridRow {
                    KeyButton(label: "x²", kind: .fn, fontSize: 15) { vm.op("^"); vm.digit("2") }
                    KeyButton(label: "¹⁄ₓ", kind: .fn, fontSize: 15) { vm.setValue(1); vm.op("/") }
                    KeyButton(label: "|x|", kind: .fn, fontSize: 15) { vm.fn("abs") }
                    KeyButton(label: "eˣ", kind: .fn, fontSize: 15) { vm.fn("exp") }
                    KeyButton(label: "mod", kind: .fn, fontSize: 14) { vm.mod() }
                }
                GridRow {
                    KeyButton(label: trigLabel("sin"), kind: .fn, fontSize: 13) { vm.fn(trigFn("sin")) }
                    KeyButton(label: trigLabel("cos"), kind: .fn, fontSize: 13) { vm.fn(trigFn("cos")) }
                    KeyButton(label: trigLabel("tan"), kind: .fn, fontSize: 13) { vm.fn(trigFn("tan")) }
                    KeyButton(label: "(", kind: .fn, fontSize: 15) { vm.paren(true) }
                    KeyButton(label: ")", kind: .fn, fontSize: 15) { vm.paren(false) }
                }
                GridRow {
                    KeyButton(label: vm.second ? "∛" : "√x", kind: .fn, fontSize: 15) { vm.fn(vm.second ? "cbrt" : "sqrt") }
                    KeyButton(label: "xʸ", kind: .fn, fontSize: 15) { vm.op("^") }
                    KeyButton(label: "n!", kind: .fn, fontSize: 15) { vm.postfix(true) }
                    KeyButton(label: "10ˣ", kind: .fn, fontSize: 14) { vm.fn("tfx") }
                    KeyButton(label: "÷", kind: .op) { vm.op("/") }
                }
                GridRow {
                    KeyButton(label: "log", kind: .fn, fontSize: 14) { vm.fn("log") }
                    KeyButton(label: "7") { vm.digit("7") }; KeyButton(label: "8") { vm.digit("8") }; KeyButton(label: "9") { vm.digit("9") }
                    KeyButton(label: "×", kind: .op) { vm.op("*") }
                }
                GridRow {
                    KeyButton(label: "ln", kind: .fn, fontSize: 14) { vm.fn("ln") }
                    KeyButton(label: "4") { vm.digit("4") }; KeyButton(label: "5") { vm.digit("5") }; KeyButton(label: "6") { vm.digit("6") }
                    KeyButton(label: "−", kind: .op) { vm.op("-") }
                }
                GridRow {
                    KeyButton(label: "⌫", kind: .fn, fontSize: 15) { vm.backspace() }
                    KeyButton(label: "1") { vm.digit("1") }; KeyButton(label: "2") { vm.digit("2") }; KeyButton(label: "3") { vm.digit("3") }
                    KeyButton(label: "+", kind: .op) { vm.op("+") }
                }
                GridRow {
                    KeyButton(label: "±") { vm.neg() }
                    KeyButton(label: "0") { vm.digit("0") }
                    KeyButton(label: ".") { vm.digit(".") }
                    KeyButton(label: "%", kind: .fn, fontSize: 15) { vm.postfix(false) }
                    KeyButton(label: "=", kind: .equals) { vm.equals() }
                }
            }.padding(10)
        }
    }
    func objectWillChangeHack() { model.scientific.objectWillChange.send() }
    func trigFn(_ b: String) -> String { (vm.second ? "a" : "") + b + (vm.hyp ? "h" : "") }
    func trigLabel(_ b: String) -> String { b + (vm.hyp ? "h" : "") + (vm.second ? "⁻¹" : "") }
}

// MARK: - Programmer view
struct ProgrammerView: View {
    @ObservedObject var vm: ProgrammerVM
    var body: some View {
        VStack(spacing: 0) {
            DisplayView(expr: vm.expression, result: vm.display)
            Picker("", selection: Binding(get: { vm.wordBits }, set: { vm.setWordSize($0) })) {
                Text("QWORD").tag(64); Text("DWORD").tag(32); Text("WORD").tag(16); Text("BYTE").tag(8)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.bottom, 4)
            VStack(spacing: 0) {
                baseRow("HEX", vm.hexStr, .hex); baseRow("DEC", vm.decStr, .dec)
                baseRow("OCT", vm.octStr, .oct); baseRow("BIN", vm.binStr, .bin)
            }.padding(.horizontal, 14).padding(.bottom, 4)
            BitGrid(vm: vm).padding(.horizontal, 14).padding(.bottom, 6)
            HStack(spacing: 3) {
                ForEach([("NAND", "nand"), ("NOR", "nor"), ("RoL", "rol"), ("RoR", "ror")], id: \.0) { p in
                    KeyButton(label: p.0, kind: .fn, fontSize: 12) { vm.setOp(p.1) }
                }
            }.frame(height: 36).padding(.horizontal, 10).padding(.bottom, 2)
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow {
                    hexKey("A"); KeyButton(label: "≪", kind: .fn, fontSize: 15) { vm.setOp("lsh") }
                    KeyButton(label: "≫", kind: .fn, fontSize: 15) { vm.setOp("rsh") }
                    KeyButton(label: "CE", kind: .fn, fontSize: 14) { vm.clearEntry() }
                    KeyButton(label: "C", kind: .fn, fontSize: 15) { vm.clearAll() }
                }
                GridRow {
                    hexKey("B"); KeyButton(label: "AND", kind: .fn, fontSize: 12) { vm.setOp("and") }
                    KeyButton(label: "OR", kind: .fn, fontSize: 13) { vm.setOp("or") }
                    KeyButton(label: "%", kind: .fn, fontSize: 14) { vm.setOp("mod") }
                    KeyButton(label: "⌫", kind: .fn, fontSize: 15) { vm.backspace() }
                }
                GridRow {
                    hexKey("C"); digitKey("7"); digitKey("8"); digitKey("9"); KeyButton(label: "÷", kind: .op) { vm.setOp("/") }
                }
                GridRow {
                    hexKey("D"); digitKey("4"); digitKey("5"); digitKey("6"); KeyButton(label: "×", kind: .op) { vm.setOp("*") }
                }
                GridRow {
                    hexKey("E"); digitKey("1"); digitKey("2"); digitKey("3"); KeyButton(label: "−", kind: .op) { vm.setOp("-") }
                }
                GridRow {
                    hexKey("F"); KeyButton(label: "XOR", kind: .fn, fontSize: 12) { vm.setOp("xor") }
                    digitKey("0"); KeyButton(label: "NOT", kind: .fn, fontSize: 12) { vm.unary("not") }
                    KeyButton(label: "+", kind: .op) { vm.setOp("+") }
                }
                GridRow {
                    KeyButton(label: "±") { vm.unary("neg") }
                    Color.clear.gridCellColumns(2)
                    KeyButton(label: "=", kind: .equals) { vm.equals() }.gridCellColumns(2)
                }
            }.padding(10)
        }
    }
    func baseRow(_ tag: String, _ val: String, _ b: ProgrammerVM.Base) -> some View {
        HStack {
            Text(tag).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            Text(val).font(.system(size: 15)).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(vm.base == b ? Color.primary.opacity(0.08) : Color.clear))
        .contentShape(Rectangle()).onTapGesture { vm.setBase(b) }
    }
    func hexKey(_ ch: String) -> some View { KeyButton(label: ch, kind: .fn, enabled: vm.isEnabled(ch)) { vm.digit(ch) } }
    func digitKey(_ ch: String) -> some View { KeyButton(label: ch, kind: .digit, enabled: vm.isEnabled(ch)) { vm.digit(ch) } }
}

// MARK: - Date view
struct DateView: View {
    @ObservedObject var vm: DateVM
    @State private var tab = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $tab) {
                    Text("Difference between dates").tag(0); Text("Add or subtract").tag(1)
                }.pickerStyle(.segmented).labelsHidden()
                if tab == 0 {
                    labeled("From") { DatePicker("", selection: $vm.from, displayedComponents: .date).labelsHidden() }
                    labeled("To") { DatePicker("", selection: $vm.to, displayedComponents: .date).labelsHidden() }
                    card {
                        Text(vm.difference.headline).font(.system(size: 26, weight: .semibold))
                        Divider().padding(.vertical, 4)
                        HStack { Text("Total").foregroundStyle(.secondary); Spacer(); Text("\(vm.difference.totalDays) days") }
                        HStack { Text("Or").foregroundStyle(.secondary); Spacer(); Text("\(abs(vm.difference.totalDays)/7) weeks, \(abs(vm.difference.totalDays)%7) days") }
                    }
                } else {
                    labeled("Start date") { DatePicker("", selection: $vm.startDate, displayedComponents: .date).labelsHidden() }
                    Picker("", selection: $vm.addMode) { Text("Add").tag(true); Text("Subtract").tag(false) }.pickerStyle(.segmented).labelsHidden()
                    stepperRow("Years", $vm.years); stepperRow("Months", $vm.months); stepperRow("Days", $vm.days)
                    card { Text(vm.computed).font(.system(size: 22, weight: .semibold)) }
                }
                Spacer()
            }.padding(20)
        }
    }
    func labeled<V: View>(_ t: String, @ViewBuilder _ c: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(t).font(.system(size: 13)).foregroundStyle(.secondary); c() }
    }
    func stepperRow(_ t: String, _ b: Binding<Int>) -> some View {
        HStack { Text(t).frame(width: 70, alignment: .leading); Stepper(value: b, in: 0...100000) { Text("\(b.wrappedValue)") } }
    }
    func card<V: View>(@ViewBuilder _ c: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) { c() }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Converter view
struct ConverterView: View {
    @EnvironmentObject var model: AppModel
    let categoryName: String
    @ObservedObject var vm: ConverterVM
    let padRows = [["7","8","9","back"],["4","5","6","C"],["1","2","3","neg"],["0",".","",""]]
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    block(active: vm.topActive, value: vm.topDisplay, unit: $vm.fromUnit) { vm.topActive = true; model.objectWillChange.send() }
                    Button { let a = vm.fromUnit; vm.fromUnit = vm.toUnit; vm.toUnit = a; model.objectWillChange.send() } label: {
                        Label("Swap", systemImage: "arrow.up.arrow.down")
                    }.buttonStyle(.bordered)
                    block(active: !vm.topActive, value: vm.botDisplay, unit: $vm.toUnit) { vm.topActive = false; model.objectWillChange.send() }
                }.padding(16)
            }
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(padRows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(padRows[r].indices, id: \.self) { ci in
                            let k = padRows[r][ci]
                            if k.isEmpty { Color.clear }
                            else { KeyButton(label: label(k), kind: ["back","C","neg"].contains(k) ? .op : .digit) { vm.key(k); model.objectWillChange.send() } }
                        }
                    }
                }
            }.padding(10).frame(height: 230)
        }
    }
    func label(_ k: String) -> String { k == "back" ? "⌫" : k == "neg" ? "±" : k }
    func block(active: Bool, value: String, unit: Binding<String>, tap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value).font(.system(size: 32, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: unit) { ForEach(vm.category.units.map { $0.0 }, id: \.self) { Text($0).tag($0) } }
                .labelsHidden().onChange(of: unit.wrappedValue) { _, _ in model.objectWillChange.send() }
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Rectangle()).onTapGesture(perform: tap)
    }
}

// MARK: - History & memory popovers
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("History").font(.headline); Spacer(); Button("Clear") { model.history.removeAll() }.buttonStyle(.link) }.padding(12)
            Divider()
            if model.history.isEmpty { Spacer(); Text("There’s no history yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer() }
            else {
                List(model.history) { h in
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(h.expr).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(h.result).font(.system(size: 20, weight: .semibold))
                    }.frame(maxWidth: .infinity, alignment: .trailing).contentShape(Rectangle())
                        .onTapGesture { model.recall(Double(h.result.replacingOccurrences(of: ",", with: "")) ?? 0) }
                }.listStyle(.plain)
            }
        }
    }
}
struct MemoryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Memory").font(.headline); Spacer(); Button("Clear") { model.memory.removeAll() }.buttonStyle(.link) }.padding(12)
            Divider()
            if model.memory.isEmpty { Spacer(); Text("Nothing saved in memory.").foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer() }
            else {
                List(model.memory.indices, id: \.self) { i in
                    Text(Num.fmt(model.memory[i])).font(.system(size: 20, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .trailing).contentShape(Rectangle())
                        .onTapGesture { model.recall(model.memory[i]) }
                }.listStyle(.plain)
            }
        }
    }
}

// MARK: - Programmer bit grid
struct BitGrid: View {
    @ObservedObject var vm: ProgrammerVM
    var body: some View {
        let bits = vm.bits                  // MSB-first
        let perRow = 16
        let rows = Int(ceil(Double(bits.count) / Double(perRow)))
        VStack(spacing: 3) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<perRow, id: \.self) { col in
                        let idx = row*perRow + col
                        if idx < bits.count {
                            let bit = bits[idx]
                            Text("\(bit)")
                                .font(.system(size: 11, weight: bit == 1 ? .bold : .regular)).monospacedDigit()
                                .frame(width: 15, height: 18)
                                .foregroundStyle(bit == 1 ? Color.accentColor : Color.secondary)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(bit == 1 ? 0.14 : 0.04)))
                                .contentShape(Rectangle())
                                .onTapGesture { vm.toggleBit(idx) }
                                .padding(.trailing, col % 4 == 3 ? 5 : 0)
                        } else { Color.clear.frame(width: 15, height: 18) }
                    }
                }
            }
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Graphing view
struct GraphingView: View {
    @ObservedObject var vm: GraphVM
    let colors: [Color] = [.blue, .red, .green, .orange, .purple]
    @State private var dragLast: CGSize = .zero
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ForEach(vm.equations.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Circle().fill(colors[i % colors.count]).frame(width: 10, height: 10)
                        Text("y =").foregroundStyle(.secondary)
                        TextField("f(x)  e.g. sin(x), x^2-3", text: Binding(get: { vm.equations[i] }, set: { vm.equations[i] = $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    }
                }
            }.padding(12)
            Divider()
            GeometryReader { geo in
                Canvas { ctx, size in draw(ctx, size) }
                    .background(Color(nsColor: .textBackgroundColor))
                    .gesture(DragGesture()
                        .onChanged { g in
                            let dx = Double(g.translation.width - dragLast.width) / Double(geo.size.width) * (vm.xmax - vm.xmin)
                            let dy = Double(g.translation.height - dragLast.height) / Double(geo.size.height) * (vm.ymax - vm.ymin)
                            vm.pan(-dx, dy); dragLast = g.translation
                        }
                        .onEnded { _ in dragLast = .zero })
            }
            HStack(spacing: 8) {
                Button { vm.zoom(0.8) } label: { Image(systemName: "plus.magnifyingglass") }
                Button { vm.zoom(1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                Button("Reset view") { vm.reset() }
                Spacer()
                Text(String(format: "x [%.1f, %.1f]   y [%.1f, %.1f]", vm.xmin, vm.xmax, vm.ymin, vm.ymax))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.padding(10)
        }
    }
    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        func sx(_ x: Double) -> CGFloat { CGFloat((x - vm.xmin) / (vm.xmax - vm.xmin)) * w }
        func sy(_ y: Double) -> CGFloat { h - CGFloat((y - vm.ymin) / (vm.ymax - vm.ymin)) * h }
        let stepX = niceStep(vm.xmax - vm.xmin), stepY = niceStep(vm.ymax - vm.ymin)
        var grid = Path()
        var gx = (vm.xmin / stepX).rounded(.up) * stepX
        while gx <= vm.xmax { let X = sx(gx); grid.move(to: CGPoint(x: X, y: 0)); grid.addLine(to: CGPoint(x: X, y: h)); gx += stepX }
        var gy = (vm.ymin / stepY).rounded(.up) * stepY
        while gy <= vm.ymax { let Y = sy(gy); grid.move(to: CGPoint(x: 0, y: Y)); grid.addLine(to: CGPoint(x: w, y: Y)); gy += stepY }
        ctx.stroke(grid, with: .color(.gray.opacity(0.22)), lineWidth: 0.5)
        var axes = Path()
        if vm.xmin <= 0, vm.xmax >= 0 { let X = sx(0); axes.move(to: CGPoint(x: X, y: 0)); axes.addLine(to: CGPoint(x: X, y: h)) }
        if vm.ymin <= 0, vm.ymax >= 0 { let Y = sy(0); axes.move(to: CGPoint(x: 0, y: Y)); axes.addLine(to: CGPoint(x: w, y: Y)) }
        ctx.stroke(axes, with: .color(.secondary), lineWidth: 1)
        let n = max(2, Int(w))
        for (i, eq) in vm.equations.enumerated() where !eq.trimmingCharacters(in: .whitespaces).isEmpty {
            var path = Path(); var started = false; var lastY = Double.nan
            for px in 0...n {
                let x = vm.xmin + Double(px) / Double(n) * (vm.xmax - vm.xmin)
                guard let y = GraphExpr.eval(eq, x: x), y.isFinite else { started = false; continue }
                if started, abs(y - lastY) > (vm.ymax - vm.ymin) * 4 { started = false }
                let pt = CGPoint(x: CGFloat(px), y: sy(y))
                if !started { path.move(to: pt); started = true } else { path.addLine(to: pt) }
                lastY = y
            }
            ctx.stroke(path, with: .color(colors[i % colors.count]), lineWidth: 2)
        }
    }
    func niceStep(_ range: Double) -> Double {
        let raw = range / 10, mag = pow(10, floor(log10(max(raw, 1e-9)))), n = raw / mag
        let step: Double = n < 1.5 ? 1 : n < 3 ? 2 : n < 7 ? 5 : 10
        return step * mag
    }
}
