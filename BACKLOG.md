# Codex Pulse 后续事项

记录日期：2026-08-12。以下仅作为后续设计与优化清单，本版本不实施。

## 品牌与图标

- 继续重构 Codex Pulse 的整体 Logo 设计与品牌识别。
- 重新设计悬浮球中的 Logo，兼顾小尺寸辨识度、状态灯和提示气泡的位置关系。
- 重新设计 macOS 顶部菜单栏 Logo，针对单色模板图标、浅色/深色菜单栏分别验证。

## 工作台 UI

- 重新设计“工作台 → 具体任务”详情页左上角返回入口。当前版本仍不满意；后续只重做视觉与交互反馈，不改变返回任务列表的逻辑。
- 后续评审详情页 Agent 直达入口的视觉表现，确保它与工作台整体风格一致。

## 状态与提示

- 再次确认五种提示灯的产品语义及颜色，尤其是“已完成”是否应统一显示为绿色。目前代码中任务完成色与 Agent 汇总灯的完成色仍需统一决策。
- 优化悬浮球提示气泡的可解释性：让用户能直接知道数字对应哪些任务、为什么出现，以及如何逐项或一次性清除。
- 评估是否需要把“已查看”和“已处理”拆成两个概念，避免点开详情后状态语义不清。

## Todo / 待办整合

核心已于本版本落地：工作台底部常驻待办栏(收起/展开、新增、完成/恢复、行内编辑、删除、滚动),SQLite 本地持久化(`~/Library/Application Support/Codex Pulse/todos.sqlite`),表含 nullable `agent_id`/`thread_id` 预留 Agent 联动;计数只在 Todo 栏内,不进入 HUD/Dock badge/悬浮球/Agent 状态灯等提醒聚合。后续可选方向:

- Agent 联动:有需要时,某条 Todo 可以关联 Agent 或具体任务(写入预留的 agent_id/thread_id),并提供直达入口;普通 Todo 可以完全不关联任何 Agent。
- 可选支持把 Codex 任务里的行动项转成 Todo,但这不是 Todo 功能的前提或主要入口。
- Apple 提醒事项、Obsidian 或其他外部同步以后再评估。
- 对已关联 Agent 的 Todo,再单独评估是否需要状态同步;默认 Todo 的完成状态不影响 Agent 任务。

### 个人待办与 Agent 待办

- 待办后续可按来源或用途分区：“个人待办”由用户直接创建与管理；“Agent 待办”与某个 Agent、会话或任务关联。是否在界面上硬性分成两区，还是使用来源筛选/分组，待界面设计时评估。
- 个人待办保持轻量和独立，不强制绑定 Agent，也不因 Agent 任务的完成或失败自动更改状态。
- Agent 待办除标题和完成状态外，可选保留 `agent_id`、`thread_id`、项目、来源任务标题、创建时间和返回原会话的入口。
- Agent 待办的完成状态默认仍由用户管理；若未来需要与 Agent 任务自动联动，再单独定义映射规则，避免“任务已运行完”被误解为“现实中的待办已完成”。

### 从 Agent 会话创建待办

- 目标交互：用户在 Codex/Kimi 会话中直接说“把这个任务弄成一个待办”或类似指令，Agent 将当前上下文总结为结构化待办，并写入 Codex Pulse。
- Agent 不应只把用户的原句机械复制为标题；它可从会话中提炼简洁标题、必要的下一步、所属项目和来源任务。首版字段保持克制，避免把 Todo 演变成另一套任务管理系统。
- 交互时区分“用户明确要求创建”和“Agent 主动建议”：前者可直接写入并回复创建结果；后者先进入待确认草稿或询问用户，不默认向 Todo 栏批量注入行动项。
- 创建成功后，Agent 应返回清晰确认，例如“已添加到 Codex Pulse · Agent 待办”；Pulse 中的待办保留返回该会话/任务的入口。
- 反向流程也作为后续构想：可以在 Codex Pulse 中新建 Agent 待办，选择对应 Agent 后从该待办启动一个新任务，或将其作为补充指令发送到已关联任务。

### 候选连通方式

- 不依赖 Pulse 从自然语言日志中猜测“用户刚才是否想建待办”；更稳定的边界是由 Agent 识别用户意图后，显式调用结构化的 Todo 工具。
- 短期可为 Codex Pulse 提供本地受限 API/CLI，例如 `todo.create`，接收标题、Agent ID、Thread ID 和来源信息；只允许本机已授权调用，并使用指令 ID 防止重复创建。
- Codex 方向后续评估以 Skill、MCP 工具或 `codex app-server` 客户能力暴露“创建 Pulse 待办”；Kimi 则通过其可用的工具/协议适配，不通过直接改写会话数据库实现。
- 手机端和 Mac 工作台使用同一套 Todo 写入接口和权限规则，避免将“Agent 转待办”“手机建待办”和“Pulse 界面建待办”实现成三套不兼容数据流。

### 待决策问题

- 界面是固定分为“个人待办 / Agent 待办”，还是保持一个列表并以来源筛选、标签或自动分组呈现。
- Agent 根据对话总结时，首版只生成标题，还是同时生成说明/下一步；哪些字段应该在 Todo 栏直接展示。
- 用户明确发出“转为待办”指令时是直接创建，还是先让 Agent 回显摘要并等待一次确认。
- 是否允许 Agent 主动提议待办，如果允许，建议项的数量上限、展示位置和拒绝后的降噪规则如何设置。

## 手机联动与远程工作台

目标：为 Codex Pulse 增加手机客户端，可随时查看 Mac 上的 Agent/任务运行情况，完成审阅、处理待办，并在可靠的 Agent 接口范围内下发操作。Mac 端仍是本地任务和工作目录的执行主体，手机端不直接读写 Codex/Kimi 的数据库或任务文件。

### 第一阶段：Mac 本地 Bridge + 手机端 MVP

- 在 Codex Pulse 内置轻量 Bridge，对手机提供结构化 API，不把本地 SQLite、JSONL、登录信息或工作目录直接暴露给网络。
- REST 负责快照和写操作，WebSocket 或 SSE 负责实时任务状态、活动、审批请求和 Todo 变化。
- 手机端先实现响应式 Web/PWA，验证任务列表、详情、审阅和 Todo 交互；需要更稳定的后台通知、相机/文件和系统集成时，再评估 SwiftUI iOS 客户端。
- 首版支持：电脑在线状态、Agent 汇总状态、任务列表/详情、实时活动、已审阅标记，以及 Todo 的新增、编辑、完成/恢复和删除。
- 手机端维持可丢弃的本地缓存；第一阶段以 Mac 上的 Pulse 数据为唯一真实来源，不做两份 SQLite 文件同步。

### 连接、配对与安全

- 局域网内可用 mDNS 发现；异地访问的首个可用方案优先采用 Tailscale 等私有组网，暂不自行实现 NAT 打洞。
- Mac 显示一次性二维码，手机扫码后完成设备配对；二维码不存放长期明文密钥。
- 设备凭据保存到 Keychain，支持在 Mac 上查看已配对设备、撤销设备和查看最近活动。
- 权限分级：只读查看、管理 Todo、标记审阅、查看 diff/文件、控制 Agent、执行高风险操作。
- 写操作使用 UUID 指令 ID、版本号和幂等处理；删除文件、执行命令、放宽权限等操作在手机上二次确认，Mac 保留审计结果。

### Agent 审阅与控制边界

- 现有 Codex Desktop/Kimi App 任务继续保持只读观察与原应用跳转，不通过改写它们的 SQLite/JSONL 实现控制。
- 新增“Pulse 托管任务”概念：由 Pulse 通过可支持的 Agent 接口启动与管理，才开放手机端输入、审批、中断和恢复等完整控制。
- Codex 方向评估使用官方 `codex app-server`：Pulse Bridge 对手机提供稳定协议，内部通过 stdio 或 Unix socket 转换 JSON-RPC，不直接依赖其实验性 WebSocket transport。
- 手机审阅界面后续支持：回答 Agent 问题、命令/网络/文件修改审批、Git diff 查看、补充指令、中断运行中 Turn，以及完成/失败/等待处理通知。
- 所有 Agent 控制指令先进入 Mac 端指令队列，由 Pulse 验证任务所有权、当前状态和设备权限后执行，再回传已接收/执行中/成功/失败结果。

### Todo 多端同步

- 第一阶段不要求中心服务器：手机通过 Bridge 操作 Mac 上的 Todo Store，Mac 保持在线时实时同步。
- 不使用 iCloud Drive、Syncthing 或其他文件同步方式直接复制正在使用的 `todos.sqlite`；同步对象应为 Todo 记录或操作日志。
- 为未来同步迁移 Todo ID 为 UUID，并增加 `version`、`device_id`、`updated_at`、`deleted_at`/墓碑等字段；将需要跨设备共享的已审阅状态从 `NSUserDefaults` 迁入可同步的存储。
- 明确冲突策略：完成状态可采用最后写入优先；标题同时修改时保留版本或提示冲突，避免静默覆盖。
- 若仅面向个人 Apple 设备，评估 Core Data/CloudKit：无需自建服务器，可在 Mac 离线时继续用手机修改 Todo，恢复联网后同步。
- 若需要 Web/Android/多人或脱离私有组网，后续增加可自托管的 Pulse Relay；参考 Happy 的零知识模式，服务器只保存端到端加密的 Todo 变更、任务摘要和待投递指令。

### 通知与离线体验

- 定义通知类型：任务完成、执行失败、等待审批、等待用户回答，以及手机指令执行失败。
- PWA 首版在前台通过实时连接更新；如需稳定的锁屏/后台推送，评估原生 iOS + APNs，或为 Web Push 引入最小通知服务。
- Mac 离线时手机明确显示“最后同步时间”；仅 Bridge 模式下不伪造已成功的写操作，引入 CloudKit/Relay 后才允许将离线变更排队待同步。

### 参考项目与选型依据

- [Happy](https://github.com/slopus/happy)：手机/Web/CLI + 云端加密同步，参考其端到端加密、多设备和异步指令。
- [CC Pocket](https://github.com/K9i-0/ccpocket)：手机 Flutter 客户端 + Mac Bridge + WebSocket/Tailscale，是首版本地 Bridge 架构的主要参考。
- [MobileCLI](https://github.com/MobileCLI/mobilecli)：Rust daemon + PTY + WebSocket + 二维码配对；参考配对和指令安全，不把终端字节流作为 Pulse 主协议。
- [Yep Anywhere](https://github.com/kzahel/yepanywhere)：手机优先的响应式 Web 界面、本地进程持有与可选加密中继，参考 PWA 产品形态。
- [RustDesk](https://github.com/rustdesk/rustdesk)：参考发现/P2P/中继分层；当前阶段用私有组网替代自研打洞和中继。
- [Codex app-server](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)：Codex 托管任务的官方协议基础，参考 Thread/Turn、实时事件、审批和用户输入流程。

### 待决策问题

- 首版是否只面向个人使用，并要求 Mac 必须在线。
- 手机首版是 PWA，还是直接开发 SwiftUI iOS 客户端。
- 异地访问是否接受用户安装 Tailscale，以及什么阶段引入 Pulse Relay。
- Todo 是否要支持 Mac 离线时在手机修改；若需要，优先选 CloudKit 还是跨平台 Relay/CRDT。
- “已审阅”是账号级状态还是每设备状态，是否与现有“已查看/已处理”语义一起重新设计。

## 性能

- 分析两秒刷新、SQLite 查询、rollout 文件尾部读取、AppKit 重建视图及涟漪动画的开销。
- 优先采用增量刷新和缓存，减少无变化时的数据库、文件读取和视图重建。
- 增加空闲、任务运行中、HUD 展开时的 CPU/内存基准，优化后做前后对比。
