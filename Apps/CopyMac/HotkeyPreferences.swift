import SwiftUI
import Carbon
import CopyCore

struct HotkeyPreference: Codable, Equatable {
    var letter: String
    var modifier: String
    var enabled: Bool? = true
    var isEnabled: Bool { enabled ?? true }
    static let keys: [String:UInt32] = ["A":0,"S":1,"D":2,"F":3,"H":4,"G":5,"Z":6,"X":7,"C":8,"V":9,"B":11,"Q":12,"W":13,"E":14,"R":15,"Y":16,"T":17,"O":31,"U":32,"I":34,"P":35,"L":37,"J":38,"K":40,"N":45,"M":46]
    var flags: UInt32 { switch modifier { case "option": return UInt32(cmdKey|optionKey); case "control": return UInt32(cmdKey|controlKey); default: return UInt32(cmdKey|shiftKey) } }
    var display: String { isEnabled ? (modifier == "option" ? "⌥⌘" : modifier == "control" ? "⌃⌘" : "⇧⌘") + letter : "未设置" }
    func validate() throws { guard Self.keys[letter] != nil, ["shift","option","control"].contains(modifier) else { throw CopyError.invalid("快捷键需要字母和至少两个修饰键") } }
}
struct HotkeyPreferencesView: View {
    @ObservedObject var model: AppModel
    @State private var panel = HotkeyPreference(letter:"V",modifier:"shift")
    @State private var collect = HotkeyPreference(letter:"C",modifier:"shift")
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            row("快捷面板",binding:$panel); row("顺序采集",binding:$collect)
            HStack {
                Button("应用快捷键") { model.configureHotkeys(panel:panel,collect:collect) }
                Button("恢复默认") { panel = HotkeyPreference(letter:"V",modifier:"shift"); collect = HotkeyPreference(letter:"C",modifier:"shift"); model.configureHotkeys(panel:panel,collect:collect) }
            }
            Text("检测到全局快捷键冲突时保留原配置；其他应用内的局部快捷键不能预先保证无冲突。").font(.caption).foregroundStyle(.secondary)
        }.onAppear { panel = model.panelHotkey; collect = model.collectHotkey }
    }
    func row(_ title: String, binding: Binding<HotkeyPreference>) -> some View {
        HStack { Toggle(title,isOn:Binding(get:{ binding.wrappedValue.isEnabled },set:{ binding.wrappedValue.enabled = $0 })); Picker("修饰键",selection:binding.modifier) { Text("⇧⌘").tag("shift"); Text("⌥⌘").tag("option"); Text("⌃⌘").tag("control") }.labelsHidden().disabled(!binding.wrappedValue.isEnabled); Picker("字母",selection:binding.letter) { ForEach(HotkeyPreference.keys.keys.sorted(),id:\.self) { Text($0).tag($0) } }.labelsHidden().disabled(!binding.wrappedValue.isEnabled) }
    }
}
