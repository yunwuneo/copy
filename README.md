# Copy

面向 macOS、iPhone 和 iPad 的剪贴板工具，目标是对标并逐步替代 Paste。Copy 是仓库暂用名，正式产品名称尚未确定。

## 当前阶段

2026-10-15：已从 T00 开始实施，仓库现有原生 macOS 应用、SQLite 数据层、自动化接口与可运行开发构建。具体实现、测试证据及未完成项见 [实施记录](docs/implementation-progress.md)。

确定方向：**只做完整版；先完成 macOS 全部适用功能并验收，再开发 iOS/iPadOS。功能对标 Paste，UI 独立设计。** 内部任务拆分不代表另行发布精简产品。

- [Paste 功能调研](docs/research/paste-feature-research.md)：功能矩阵、平台差异、权限、数据生命周期、商业模式、证据来源和待实测问题。
- [完整产品功能规格 v1](docs/product/product-spec-v1.md)：24 个需求模块、独立 UI、内容与数据规则、权限、错误恢复及性能目标。
- [完整实施计划 v1](docs/product/implementation-plan-v1.md)：T00–T29 共 30 项任务，先 Mac 后移动，两个完整交付门槛。
- [功能对照与验收](docs/product/acceptance-and-traceability.md)：F01–F63 全量映射及 Q01–Q69 验收用例；逐项完成状态以实施记录为准。
- [原实施建议入口](docs/product/implementation-outline.md)：已由上述 v1 文档取代。

## 工作原则

- 先明确行为、数据与验收标准，再实现；产品界面与品牌独立设计。
- 区分官方声明、历史发布记录、实际测试和本项目建议。
- macOS 与 iOS 的采集能力分别定义，不承诺 iOS 全局后台连续记录。
- 优先本地数据与可选同步，明确敏感内容、删除、共享及 AI 访问边界。
- 节省本地存储：不保存竞品安装包、网页镜像或重复截图；增量构建缓存集中在 work/，仅保留继续开发所需部分。

## 仓库

现有远程：`git@github.com:yunwuneo/copy.git`。系统门槛、技术路径与默认值详见功能规格的设计基线；这些属于本项目方案，仍须实施验证。收费方式尚未选定，不切割完整版功能。

## 开发实现（2026-10-15）

原生 macOS 实现已开始，详情见 [实施记录](docs/implementation-progress.md)。目前为开发中构建，尚未通过 macOS 完整验收；iOS 未开始。

```sh
./scripts/test.sh
./scripts/build-app.sh
# 独立合成资料库；禁用通用剪贴板读取、输出和自动粘贴
./scripts/build-app.sh --ui-test
# 可选：生成并自动清理 10 万行临时性能样本
COPY_PERF=1 ./scripts/test.sh
```

构建输出 `work/Copy.app`，不自动启动。全部依赖来自 Apple SDK/系统 SQLite，无需下载第三方库。首次启动默认不采集，需在应用内同意。MCP、系统搜索、模型推荐均需独立开启。正式签名与 iCloud 配置尚未具备。
