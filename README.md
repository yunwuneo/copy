# Copy

面向 macOS、iPhone 和 iPad 的剪贴板工具，目标是对标并逐步替代 Paste。Copy 是仓库暂用名，正式产品名称尚未确定。

## 当前阶段

2026-10-15：完成竞品调研、完整产品功能规格、实施计划与验收基线。当前没有应用代码、Xcode 工程或可运行安装包。

确定方向：**只做完整版；先完成 macOS 全部适用功能并验收，再开发 iOS/iPadOS。功能对标 Paste，UI 独立设计。** 内部任务拆分不代表另行发布精简产品。

- [Paste 功能调研](docs/research/paste-feature-research.md)：功能矩阵、平台差异、权限、数据生命周期、商业模式、证据来源和待实测问题。
- [完整产品功能规格 v1](docs/product/product-spec-v1.md)：24 个需求模块、独立 UI、内容与数据规则、权限、错误恢复及性能目标。
- [完整实施计划 v1](docs/product/implementation-plan-v1.md)：T00–T29 共 30 项任务，先 Mac 后移动，两个完整交付门槛。
- [功能对照与验收](docs/product/acceptance-and-traceability.md)：F01–F63 全量映射及 Q01–Q69 验收用例；当前均未执行。
- [原实施建议入口](docs/product/implementation-outline.md)：已由上述 v1 文档取代。

## 工作原则

- 先明确行为、数据与验收标准，再实现；产品界面与品牌独立设计。
- 区分官方声明、历史发布记录、实际测试和本项目建议。
- macOS 与 iOS 的采集能力分别定义，不承诺 iOS 全局后台连续记录。
- 优先本地数据与可选同步，明确敏感内容、删除、共享及 AI 访问边界。
- 节省本地存储：不保存竞品安装包、网页镜像、重复截图或构建缓存。

## 仓库

现有远程：`git@github.com:yunwuneo/copy.git`。系统门槛、技术路径与默认值详见功能规格的设计基线；这些属于本项目方案，仍须实施验证。收费方式尚未选定，不切割完整版功能。
