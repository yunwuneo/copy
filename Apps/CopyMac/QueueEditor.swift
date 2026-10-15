import SwiftUI
import CopyCore

struct QueueEditorSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("管理顺序队列").font(.title2); Spacer(); Button("完成") { dismiss() } }
            Text("已发送 \(model.queue.cursor) 项，剩余 \(max(0,model.queue.ids.count-model.queue.cursor)) 项。调整后队列暂停；已发送项保持原顺序。").font(.caption)
            if !model.queue.canEdit { Text("发送结果尚未确认，请关闭此窗口并先对账。").foregroundStyle(.orange) }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            Button("反转剩余顺序") { model.editQueue { try $0.reverseRemaining() } }.disabled(!model.queue.canEdit)
            ScrollView { LazyVStack(spacing:12) { ForEach(Array(model.queue.ids.enumerated()),id:\.offset) { index,id in
                HStack {
                    Text("\(index+1)").monospacedDigit().frame(width:30)
                    Text(model.settings.conceal ? "内容已隐藏" : ((try? model.store.item(id))?.displayTitle ?? "条目已删除，需移除")).lineLimit(2)
                    Spacer()
                    if index < model.queue.cursor { Text("已发送").foregroundStyle(.secondary) }
                    else {
                        Button("上移") { model.editQueue { try $0.movePending(from:index,to:index-1) } }.disabled(!model.queue.canEdit || index == model.queue.cursor)
                        Button("下移") { model.editQueue { try $0.movePending(from:index,to:index+1) } }.disabled(!model.queue.canEdit || index+1 == model.queue.ids.count)
                        Button("移除") { model.editQueue { try $0.removePending(at:index) } }.disabled(!model.queue.canEdit)
                    }
                }.accessibilityElement(children:.contain)
                Divider()
            } } }
        }.padding(20).frame(width:680,height:440)
    }
}
