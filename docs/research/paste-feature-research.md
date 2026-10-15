# Paste 功能调研与替代范围

调研日期：2026-10-15（Asia/Shanghai）。对象：Paste Team 的 Paste，官方网站 pasteapp.io，App Store ID 967805235。

## 1. 结论与证据口径

Paste 的完整替代范围包括：采集与历史、内容预览和编辑、搜索、快速与批量粘贴、Pinboards 收藏、跨设备同步、共享协作、移动扩展、自动化、隐私控制、智能推荐及 MCP。仅有“历史列表 + 搜索 + iCloud”只能覆盖基础使用。

本报告覆盖查阅到的官方公开功能面，不宣称穷尽未公开菜单或内部实现。本轮未安装/运行 Paste，未操作桌面、读取用户剪贴板或连接 Paste MCP。表中“确认”均指文档证据，不等于实测通过。

证据标记：**D**＝当前官方帮助明确说明；**R**＝官方发布记录，当前入口或行为仍需复核；**S**＝商店开发者声明；**U**＝未找到足够证据。每个功能行保留来源链接。产品建议集中在另一份文档，不能当作 Paste 现状。

### 当前版本与兼容性快照

美区商店当前显示移动端 7.0.2；最低 iOS/iPadOS 26，macOS 14；支持简体/繁体中文。商店还列出 visionOS 26 兼容性，但不能据此认定存在独立原生 visionOS 产品。Mac 的独立发行版具体版本号本轮未核实。[商店][store] [下载页][download]

官网说明仍支持符合系统要求的 Intel Mac，并原生支持 Apple Silicon；智能推荐另有更高要求，不能把基本运行门槛等同于 AI 门槛。[架构兼容][intel] [智能推荐][intelligence]

## 2. 功能清单

平台缩写：M＝macOS；I＝iPhone；P＝iPad。未标某平台表示证据没有覆盖该平台，不自动表示不支持。

### A. 内容采集与历史

| ID | 能力 | 平台与行为边界 | 证据 |
|---|---|---|---|
| F01 | 自动采集 | M 后台运行期间记录复制；关面板不等于退出应用 | D [采集][capture] |
| F02 | 移动采集 | I/P 打开应用后读取当前剪贴板，也可经分享/操作扩展或 Paste Keyboard 收集；不能补回后台已被覆盖的多次复制 | D [移动历史][ios-history] |
| F03 | iPad 可见时采集 | P 与其他应用并排、Stage Manager 或 Slide Over 可见时自动采集；受设备和系统多任务能力约束 | D [iPad][ipad] |
| F04 | 内容类型 | 明确包含文本、链接、图片、文件和颜色；默认回贴保留原格式。具体富文本/应用专用格式覆盖需实测 | D [采集][capture] |
| F05 | 颜色识别 | 独立六位 HEX，带 # 或至少一个 A–F 字母时识别为颜色；纯六位数字、#FFF、rgb()、颜色名和夹杂其他文字的代码仍作文本 | D [采集][capture] |
| F06 | 历史呈现 | 时间顺序、内容预览、来源应用和复制时间；M 最新项在前 | D [Mac][mac] [iPad][ipad] |
| F07 | 保留期限 | M 默认 30 天；可选 1 天、1 周、1 月、1 年、永久；I/P 没有 Keep History 设置入口 | D [保留期限][retention] |
| F08 | 清空与过期 | 未收藏项按期限清理；清空历史保留收藏板和收藏项；缩短期限会确认删除旧项，且该删除不可撤销 | D [保留期限][retention] |
| F09 | 常驻与登录启动 | M 有 Open at login；App Store 版另有 Run in background | D [登录启动][login] [采集][capture] |

### B. 调用、浏览与粘贴

| ID | 能力 | 平台与行为边界 | 证据 |
|---|---|---|---|
| F10 | 快捷唤起与面板 | M 默认 ⇧⌘V，或菜单栏入口；底部面板高度可调，缩小切换 Compact Mode；随当前工作显示器出现，无固定显示器选项 | D [Mac][mac] |
| F11 | 键盘导航和多选 | M 方向键、范围选择、全选；可多项一起粘贴；I/P 批量选择见历史发布记录 | D [快捷键][keys]；R [更新][updates] |
| F12 | Direct Paste | M 回车/双击将条目插入原应用；依赖辅助功能权限；不授权则只写回系统剪贴板，用户手动粘贴 | D [直接粘贴][direct] |
| F13 | Quick Paste | M 先打开 Paste，再用 ⌘1–9 粘贴当前列表对应项；没有单条 snippet 自定义快捷键 | D [数字粘贴][quick] |
| F14 | 纯文本输出 | M 单次 ⇧Return、上下文菜单或全局 Always paste as Plain Text；只在经 Paste 输出时去格式，不自动改写任意当前剪贴板 | D [纯文本][plain] |
| F15 | Paste Stack | M ⇧⌘C 开启临时队列，复制项按序入队；⌘V 逐条输出，可反向、移除待用项，已用项自动出队；依赖辅助功能权限 | D [队列][stack] [直接粘贴][direct] |
| F16 | 拖放 | M 可拖入目标应用；P 支持应用间双向拖放；键盘扩展也提供拖放 | D [Mac][mac] [iPad][ipad] [键盘][keyboard] |
| F17 | 图片作为文件输出 | 图片可按文件拖放/粘贴，供上传等场景使用；具体目标应用兼容性需验证 | R [更新][updates] |
| F18 | 原生打开与撤销 | M ⌘O 打开链接/文件、Delete 删除、⌘Z 撤销；不能把撤销泛化到清空、过期删除和云端操作 | D [快捷键][keys] [保留期限][retention] |
| F19 | 快捷键定制 | 唤起、Stack、前后收藏板可改；Quick Paste 与纯文本修饰键可改并能恢复默认；并非每项快捷键都可重绑 | D [快捷键][keys] |

### C. 预览、编辑与内容复用

| ID | 能力 | 平台与行为边界 | 证据 |
|---|---|---|---|
| F20 | 完整预览 | M 空格 Quick Look：文本、图片、PDF 等；链接有内置网页预览；I/P 长按进入预览/操作 | D [Mac][mac] [iPhone][iphone] |
| F21 | 原位编辑和命名 | 编辑文本并保留格式，改名帮助识别与搜索；M ⌘E/⌘R；修改保存到原条目 | D [编辑][edit] |
| F22 | 手工创建 | M ⌘N 新建文本；历史发布还提及创建链接与格式编辑 | D [Mac][mac]；R [更新][updates] |
| F23 | 图片文字提取 | 从预览提取文字；图片支持旋转等快捷操作 | D [编辑][edit] |
| F24 | 扩展编辑工具 | 内置颜色选择器、修改链接、从预览分享；通过 iPhone 扫描文档进入 Paste | R [更新][updates]；具体端侧入口待确认 |
| F25 | Writing Tools | 支持的设备上编辑文本时使用 Apple Intelligence 写作工具；与下述智能推荐是两个功能 | D [编辑][edit] |

### D. 搜索与定位

| ID | 能力 | 平台与行为边界 | 证据 |
|---|---|---|---|
| F26 | 全局即时搜索 | M/I/P 搜索内容、标题、元数据；包含历史与收藏项，不默认仅搜索当前收藏板 | D [搜索][search] [收藏板][pinboards] |
| F27 | 条件组合 | 按类型、来源应用、设备、日期过滤；搜索时建议条件，已选条件可见并可移除 | D [搜索][search] |
| F28 | 收藏板筛选 | 可限定一个或多个收藏板 | R [更新][updates]，2026-03-24 发布 |
| F29 | 图片内搜索 | OCR 检索截图/照片中的文字并高亮命中；没有足够证据支持任意扫描 PDF 全文索引 | D [搜索][search] |
| F30 | 从结果回到原位置 | Show in 跳回历史或收藏板；M 单选时 ⌘G；支持全键盘从搜索结果粘贴 | D [搜索][search] |
| F31 | 系统搜索 | iPad 官方指南明确提及 iOS Spotlight 检索历史；iPhone 当版具体覆盖需实测 | D [iPad][ipad] |

### E. Pinboards 与共享

| ID | 能力 | 平台与行为边界 | 证据 |
|---|---|---|---|
| F32 | 收藏板管理 | M/I/P 创建、命名、配色、修改、删除，拖动排序 | D [收藏板][pinboards] |
| F33 | 收藏条目 | 上下文菜单、拖放、移动分享扩展加入；M 支持批量；收藏不移除历史中的条目 | D [收藏板][pinboards] |
| F34 | 归属与永久保留 | 一项只能属于一个收藏板，换板为移动；板内手动排序；收藏不受历史期限影响 | D [收藏板][pinboards] |
| F35 | 移除与删板 | 可取消收藏；删除收藏板会移除其内容，历史中是否仍留独立表示需实测 | D [收藏板][pinboards] |
| F36 | 共享邀请 | M/I/P 使用原生 iCloud 分享；参与者须安装 Paste 并登录 iCloud；可邀请指定人员或开放链接 | D [共享][sharing] |
| F37 | 共享权限 | 只读或可编辑；可增删参与者、调整权限，协作者可按权限增删条目 | D [共享][sharing] |
| F38 | 停止共享 | 所有者可撤销；文档称共享板及内容从参与者设备移除；离线撤权时机与已导出副本不在此承诺内 | D [共享][sharing] |

### F. 同步与数据管理

| ID | 能力 | 平台与行为边界 | 证据 |
|---|---|---|---|
| F39 | 本地存储、可选 iCloud | 历史和收藏板保存本机，启用后通过个人 iCloud 同步；普通同步开关逐设备设置，默认关闭 | D [数据][storage] [同步][sync] |
| F40 | 跨设备变化传播 | 同步收藏板名称、内容与变化；首次大量同步需等待；不是可保证实时完成的传输 | D [同步][sync] |
| F41 | 共享与同步开关联动 | 官方同时描述共享独立同步，并警告关闭 iCloud 同步可能删除自己共享给参与者的板/移除别人共享的板；不能当作无损暂停 | D [同步][sync]；需版本级实测澄清 |
| F42 | 迁移与恢复 | 新 Mac 同 Apple Account 启用同步后下载；Time Machine 可恢复整机所含数据；iOS 卸载删除本地副本 | D [数据][storage] |
| F43 | Universal Clipboard 配合 | 商店明确表示可与系统通用剪贴板协同；它与长期历史同步不是同一能力 | S [商店][store]；系统机制见 [Apple][universal] |

### G. iPhone/iPad 专属入口

| ID | 能力 | 平台与行为边界 | 证据 |
|---|---|---|---|
| F44 | Share Extension | 分享面板中选择存入历史或指定收藏板 | D [扩展][extensions] |
| F45 | Action Extension | Copy to Clipboard History 一步存入历史；与可选目的地的 Share Extension 区分 | D [扩展][extensions] |
| F46 | Paste Keyboard | 启用键盘及 Full Access；地球键切换，浏览历史/收藏、复用内容、长按纯文本操作；P 横竖屏适配 | D [键盘][keyboard] |
| F47 | 粘贴读取授权引导 | 引导设置 Paste from Other Apps；Allow/Ask 的选择不会解除后台采集限制 | D [iOS 权限][ios-permission] [移动历史][ios-history] |
| F48 | 桌面小组件 | I 小号/中号组件，配置历史或收藏板入口，点击打开相应列表；不是后台监听组件 | D [iPhone][iphone] |
| F49 | 移动交互 | I 点击回写系统剪贴板、长按预览/编辑；P 侧栏、右滑复制、全屏预览及多窗口工作流 | D [iPhone][iphone] [iPad][ipad] |

### H. 隐私与自动化/AI

| ID | 能力 | 平台与行为边界 | 证据 |
|---|---|---|---|
| F50 | 应用排除 | M Ignore Applications 阻止后续采集；不删已存历史；I/P 无此列表 | D [排除][exclude] |
| F51 | 敏感/临时内容过滤 | 忽略可检测的 confidential/transient 数据；浏览器密码扩展可能漏检，不能承诺密码永不入库 | D [排除][exclude] |
| F52 | 暂停采集 | M ⌘T 或菜单，按选定时长恢复，也可手动恢复 | D [Mac][mac] [排除][exclude] |
| F53 | 屏幕分享保护 | Show during screen sharing 可关闭，官方宣称覆盖分享、录制及截图；各系统/录屏链路的保护效果待实测 | R [更新][updates] |
| F54 | Siri / Shortcuts | 2020 文档提供：添加文本/链接到板、取板内最近文本/链接、按索引取条目；2021 扩展到 Mac；当前动作名称及参数需复核 | R [Siri][siri] [Mac Shortcuts][shortcuts] |
| F55 | 智能推荐 | M macOS 26+，开启 Apple Intelligence；结合当前工作内容推荐历史项，本地处理；可单独关闭 | D [智能推荐][intelligence] |
| F56 | 推荐的屏幕授权 | 需 Screen Recording；官方称仅面板打开时读取目标应用，关面板不保留屏幕内容；跳过排除应用和密码字段 | D [智能推荐][intelligence] |
| F57 | 本地 MCP | M 内置服务器；用户启用并授权客户端；支持查询历史、读取内容作为上下文 | D [MCP][mcp] |
| F58 | MCP 写操作 | 自定义客户端说明包含保存新条目、管理收藏板；不能把 MCP 当作仅查询接口 | D [自定义 MCP][custom-mcp] |
| F59 | MCP 连接与撤销 | 提供 Claude Desktop/Code、Codex、Cursor、VS Code、Windsurf 等指南；可查看连接、撤销或全局关闭；自定义连接使用 Server URL 和 Token | D [MCP][mcp] [自定义 MCP][custom-mcp] |
| F60 | AI 的数据边界 | MCP 本地运行，但获授权客户端可能将取出的数据发往模型提供商；本地服务器不等于端到端不出网 | D [MCP][mcp] |

### I. 产品配套

| ID | 能力 | 平台与行为边界 | 证据 |
|---|---|---|---|
| F61 | 无障碍与语言 | 商店声明 VoiceOver、大字体、深色界面、不仅靠颜色区分；含中文；尚未实际验收 | S [商店][store] |
| F62 | 多种授权渠道 | App Store、官网 Direct license、Setapp；恢复购买/许可证激活；不同渠道更新可能不同步 | D [套餐][plans] [MCP][mcp] [迁移][intel] |
| F63 | 家庭和团队 | 家庭年付最多 6 人；团队统一账单、许可证槽位、设备停用释放槽位；席位数量变化需联系官方 | D [价格][pricing] [团队][teams] |

## 3. 平台差异速查

下表是上述功能的归纳，不另行推断平台支持。

| 能力 | Mac | iPhone | iPad |
|---|---|---|---|
| 其他应用复制时自动记录 | 运行期间后台可采集 | 后台不支持 | 仅应用可见等受支持状态 |
| 历史、收藏、图片文字搜索 | 支持 | 支持 | 支持 |
| 系统级唤起和直接回贴 | 全局快捷键 + 辅助功能授权 | 键盘/手动复制粘贴 | 键盘/手动/拖放 |
| 数字 Quick Paste、Paste Stack | 明确支持 | 未发现支持证据 | 未发现支持证据 |
| 分享和操作扩展、Paste Keyboard | 非同类入口 | 支持 | 支持 |
| 应用排除、历史保留期设置 | 支持 | 无设置入口 | 无设置入口 |
| iCloud 与共享板 | 支持 | 支持 | 支持 |
| 智能推荐、MCP 服务端 | 支持，前者有 AI 条件 | 未发现支持证据 | 未发现支持证据 |
| Shortcuts | 历史官方支持 | 历史官方支持 | 历史官方支持 |

移动键盘的“可粘贴内容”还取决于宿主应用、内容类型及系统限制，不能把介绍中的“任何应用”当作无条件兼容保证。

## 4. 三条关键数据路径

1. **Mac 日常使用**：复制 → 排除/敏感/暂停规则 → 历史保存 → 搜索或收藏 → 原格式或纯文本输出 → 有权限直接回贴、无权限手动粘贴。
2. **iPhone 收集与跨端复用**：分享/操作扩展、键盘或打开主应用 → 本地保存 → 可选 iCloud → 另一设备历史/收藏 → 粘贴。不能在连续复制后恢复所有已覆盖内容。
3. **共享或 AI 使用**：先明确所共享的集合/所授权的客户端 → 允许读取或修改 → 变化同步/工具取得内容 → 用户可撤权。已被他人或模型取走的数据与撤回共享访问是两件事。

路径分别依据 [采集][capture]、[直接粘贴][direct]、[移动历史][ios-history]、[共享][sharing] 和 [MCP][mcp]；这是行为归纳，并非内部架构逆向结论。

## 5. 隐私、同步和存储的实际含义

- **剪贴板内容不进 Paste 自家服务器，不代表整个产品零遥测。** 隐私政策（2026-06-27 生效）列出 PostHog 使用分析和 Sentry 崩溃报告；本地数据含二进制与人类可读格式，不能据此宣称整个本地数据库另有应用级加密。[隐私政策][privacy]
- **iCloud 同步不等于独立版本备份。** 官方提供 Time Machine 与同步迁移指导，但没有给出通用 JSON/CSV 导入导出规范。云端清空可能影响恢复来源，应把“备份、同步、迁移”分开设计。[数据][storage] [同步][sync]
- **“无限历史”是可选永久保留，不是默认值，也不是零存储成本。** 已确认默认 30 天；条数上限、附件上限、缩略图缓存与磁盘回收细则未公开。[保留期限][retention]
- **隐私过滤有边界。** 排除来源应用仅阻止新采集；扩展复制的密码可能无法识别；显示器录制保护的效果也需分系统验证。[排除][exclude] [更新][updates]

以上工程含义是本报告分析；未对网络流量、加密方式或系统 API 进行测试。

## 6. 商业模式快照

截至调研日，美区商店列出的公开价格如下，不能替代中国区或最终结账报价。[商店][store]

| 套餐 | 美元价格 | 备注 |
|---|---|---|
| 个人月付 | 3.99/月 | Mac + iOS |
| 个人年付 | 29.99/年 | 官网显示折合 2.49/月，实际按年付款 |
| Lifetime | 99.99 一次性 | 官网说明包含未来更新 |
| Family | 59.99/年 | 家庭组最多 6 人，App Store 独有 |
| Teams | 本轮未确认报价 | 官网购买，月/年计费，统一账单 |

个人计划核心功能一致。官网 7 天试用不需要信用卡；App Store 首次订阅试用有自动续费条件。官网称到期保留历史，购买后恢复访问。Setapp 的 iOS 使用取决于所购计划。[价格与试用][pricing]

团队帮助页同时使用“按用户计费”和“五个席位最多激活五台设备”的口径，个人多设备权益不能直接套用团队，应作为商务待确认项。[团队][teams]

## 7. 尚不能声称已经确认的能力

| 问题 | 本轮结论 | 替代产品定义前需要什么证据 |
|---|---|---|
| 重复内容去重/再次复制置顶 | U | 相同文本、不同来源、富文本差异、多设备重复分别测试 |
| 文件是快照还是原路径引用 | U | 移动/删除原文件后回贴；跨设备离线、未下载、下载失败行为 |
| 所有富文本/专用对象还原 | U | HTML、RTF、表格、多文件及设计工具对象的类型和回贴矩阵 |
| 多选粘贴分隔符和顺序 | 部分 D | 选择顺序与时间顺序、文本/图片混合、目标应用差异 |
| 任意 PDF 全文搜索 | U | 区分可预览 PDF、原生文本索引、扫描 PDF OCR |
| 多标签、嵌套收藏板、智能板 | U | 当前未确认；单条仅属于一个板已有 D 证据 |
| 模板变量/缩写自动展开 | U | 可保存模板文本不等于动态模板引擎 |
| 单条 snippet 专属快捷键 | 明确未支持 | Quick Paste 文档称仍在路线图中 |
| 导入其他剪贴板工具、通用导出 | U | 官方格式说明或获授权后的小样本迁移测试 |
| 端到端加密、应用锁、Face ID | U | 不从“私有 iCloud”或“private”营销措辞推断 |
| 本地大小上限/按容量淘汰 | U | 设置检查与磁盘实验；不使用用户真实历史做破坏性测试 |
| 同步冲突/删除回流/撤销 | U | 两台真机编辑、离线删除、重连、改期限、取消共享 |
| MCP 完整 tools/schema 与权限粒度 | U | 公共帮助确认能力但未给出完整 schema；需授权连接后只读发现 |
| AI 支持地区/语言与推荐准确率 | U | 目标设备、Apple Intelligence 可用性、权限拒绝降级 |
| 当前 Shortcuts 全部动作 | R | 旧博客动作清单需在当前安装版本核对 |
| Handoff 独立交互 | U | 商店描述不够精确，不能等同独立已验证功能 |

后续实测应使用合成内容，并记录版本、系统、来源/目标应用和步骤。完成公开资料调研并不要求此时申请屏幕或剪贴板权限。

## 8. 对替代范围的判断

这是本项目建议，不是 Paste 的事实描述：

- **可日用替代**先闭环采集、持久化、搜索、收藏、回贴、隐私及删除，再做真实跨端同步和移动分享/键盘。
- **完整功能对标**还要覆盖 OCR、批量/队列、预览编辑、系统入口、共享、Shortcuts、智能推荐、MCP 和无障碍；这些都应在路线图中明确，不能静默遗漏。
- **值得优先改善**的是可见的同步状态、文件失效解释、开放导出、存储预算及读写分离的 AI 授权。它们是候选差异化，不能写成“Paste 一定没有”。
- **UI 独立设计**。底部横向卡片是竞品的现有呈现方式，不是功能等价的必要条件。

阶段建议与验收方向见 [实施建议](../product/implementation-outline.md)。

## 9. 来源登记

以下均为 2026-10-15 访问的官方资料。当前帮助通常没有逐页发布日期；历史博客明确保留年份。仅保存链接与必要摘要，不镜像网页、图片或安装包。

| 编号 | 来源 | 用途 |
|---|---|---|
| S01 | [Mac 使用说明][mac] | 桌面工作流 |
| S02 | [iPhone 使用说明][iphone] | 移动主应用与组件 |
| S03 | [iPad 使用说明][ipad] | 多任务、Spotlight、拖放 |
| S04 | [采集范围][capture] | 内容类型与识别规则 |
| S05 | [移动历史限制][ios-history] | 采集时机 |
| S06 | [历史期限][retention] | 过期与清空 |
| S07 | [登录启动][login] | 常驻设置 |
| S08 | [快捷键][keys] | 操作与定制 |
| S09 | [直接粘贴][direct] | 辅助功能与降级 |
| S10 | [数字粘贴][quick] | 1–9、snippet 快捷键限制 |
| S11 | [纯文本粘贴][plain] | 输出格式 |
| S12 | [Paste Stack][stack] | 顺序输出 |
| S13 | [编辑条目][edit] | 编辑/OCR/写作工具 |
| S14 | [搜索][search] | 索引、过滤、回到历史 |
| S15 | [收藏板][pinboards] | 单板归属与生命周期 |
| S16 | [共享收藏板][sharing] | 邀请、权限、撤销 |
| S17 | [数据与迁移][storage] | 本地/iCloud/Time Machine |
| S18 | [同步故障说明][sync] | 默认开关及共享副作用 |
| S19 | [移动扩展][extensions] | Share/Action |
| S20 | [Paste Keyboard][keyboard] | Full Access 与键盘入口 |
| S21 | [iOS 读取权限][ios-permission] | Ask/Allow |
| S22 | [排除应用][exclude] | 敏感内容与漏检 |
| S23 | [智能推荐][intelligence] | AI 条件与屏幕权限 |
| S24 | [Paste MCP][mcp] | 本地服务与客户端管理 |
| S25 | [自定义 MCP][custom-mcp] | 写入能力与令牌 |
| S26 | [官方更新][updates] | 历史增量功能 |
| S27 | [Siri 博客（2020）][siri] | 历史动作清单 |
| S28 | [Mac Shortcuts（2021）][shortcuts] | Mac 自动化支持 |
| S29 | [隐私政策][privacy] | 存储和遥测声明 |
| S30 | [美区 App Store][store] | 移动版本、兼容性、价格、无障碍 |
| S31 | [价格][pricing] | 试用、渠道、套餐 |
| S32 | [套餐说明][plans] | 付费权益 |
| S33 | [团队管理][teams] | 账单、设备授权槽位 |
| S34 | [下载页][download] | macOS 最低版本 |
| S35 | [Intel 与迁移][intel] | 芯片支持与恢复授权 |
| S36 | [Apple 通用剪贴板][universal] | 系统功能区分 |

[mac]: https://pasteapp.io/help/paste-on-mac
[iphone]: https://pasteapp.io/help/paste-on-iphone
[ipad]: https://pasteapp.io/help/paste-on-ipad
[capture]: https://pasteapp.io/help/what-paste-captures
[ios-history]: https://pasteapp.io/help/clipboard-history-on-iphone
[retention]: https://pasteapp.io/help/control-history-retention
[login]: https://pasteapp.io/help/paste-doesn-t-launch-on-system-startup
[keys]: https://pasteapp.io/help/keyboard-shortcuts
[direct]: https://pasteapp.io/help/paste-directly-to-other-applications
[quick]: https://pasteapp.io/help/quick-paste-with-numbered-shortcuts
[plain]: https://pasteapp.io/help/paste-as-plain-text
[stack]: https://pasteapp.io/help/using-paste-stack
[edit]: https://pasteapp.io/help/edit-items-before-pasting
[search]: https://pasteapp.io/help/search-and-filters
[pinboards]: https://pasteapp.io/help/organize-with-pinboards
[sharing]: https://pasteapp.io/help/shared-pinboards
[storage]: https://pasteapp.io/help/where-paste-stores-your-data
[sync]: https://pasteapp.io/help/icloud-sync-doesn-t-work
[extensions]: https://pasteapp.io/help/how-to-enable-paste-extensions
[keyboard]: https://pasteapp.io/help/enable-and-use-paste-keyboard
[ios-permission]: https://pasteapp.io/help/allow-paste-permissions-in-ios
[exclude]: https://pasteapp.io/help/exclude-apps
[intelligence]: https://pasteapp.io/help/intelligent-clipboard
[mcp]: https://pasteapp.io/help/paste-mcp
[custom-mcp]: https://pasteapp.io/help/connect-custom-mcp
[updates]: https://pasteapp.io/updates
[siri]: https://pasteapp.io/blog/hey-siri
[shortcuts]: https://pasteapp.io/blog/paste-with-shortcuts-for-macos-monterey
[privacy]: https://pasteapp.io/privacy
[store]: https://apps.apple.com/us/app/paste-limitless-clipboard/id967805235
[pricing]: https://pasteapp.io/pricing
[plans]: https://pasteapp.io/help/choose-a-plan
[teams]: https://pasteapp.io/help/paste-for-teams
[download]: https://pasteapp.io/download
[intel]: https://pasteapp.io/help/intel-to-apple-silicon
[universal]: https://support.apple.com/guide/iphone/copy-and-paste-between-devices-iph220ea8dca/26/ios/26
