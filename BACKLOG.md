# 澜台 / Lantai 后续事项

## 实现记录：新建任务选模型（2026-08-17）

手机新建任务时可以从官方 `model/list` 里挑模型。目录挂在快照每个 agent 的 `models` 上；`POST /api/commands` 的 `start` 接受可选 `modelID`。不选就不传 `model`，继承 `~/.codex/config.toml`。

第 0 步实测（`/tmp/lantai-model-probe.py`，自起 `codex app-server --listen stdio://`，没跑 `turn/start`）：

- `model/list` 第一页 6 个可见模型，`nextCursor` 为空。`id` 与 `model` 相同。官方 `isDefault` 是 `gpt-5.6-sol`，本机 config.toml 默认是 `gpt-5.6-luna`。
- `thread/start` 传 `model=gpt-5.6-sol` 后，`ThreadStartResponse.model` 回显就是 `gpt-5.6-sol`，不是 config 里的 luna。所以 model 加在 `thread/start`，不碰 `turn/start`。
- 同一次响应里 `reasoningEffort` 仍是 config 的 `high`，不是 sol 自己的 `defaultReasoningEffort=low`。按既定决策不暴露 effort 选择器，也就没传 `effort`。

刻意没做：Mac 端模型白名单或设置 UI（官方目录本身就是校验依据）；effort / `collaborationMode`；`steer` 带模型；`model/list` 翻页（只取第一页，`limit=50`，注释写明了）。`model/list` 失败（含 `-32601`）只让目录变空，不把 driver 判不健康。

还没验：真机从手机开一个带模型的任务，看 Codex 后继 turn 是否一直用这个模型；手机端 JS 没有自测，只做了 `node --check`。

自测 8 项都做过反向验证（回退对应实现后该项变红，再还原）。`snap-empty` 最初用了「不健康 stub + 空目录」，回退 `isHealthy` 检查时断言仍绿——测不出问题。已改成不健康 stub 仍带着一条过期模型，漏检健康度就会把那条漏给手机。

---

## 实现记录：Codex / Kimi 额度（2026-08-17）

菜单栏显示两家用量百分比。HUD 标题右侧放 CodexBar 那种两根短胶囊（上粗下细、按已用比例填色），悬停看「周限额 57%」。工作台不显示额度。窗口标题按分钟数归类（5小时 / 周 / 月），不写死 primary=会话。

- Codex：`CPCodexDriver` 调已握手的 `account/rateLimits/read`，澜台不读 `auth.json`、不自己发 HTTPS。
- Kimi：只读 `kimi-desktop/Cookies` 里明文 `kimi-auth`，POST GetUsages + GetSubscriptionStats。优先 `ratio`，不用截断过的 `used`。CLI 那份 15 分钟 token 不用。
- 两分钟刷新一次，点开菜单且超过 30 秒也会再取。读不到显示「额度不可用」。
- 解析与文案有自测；自测不打真实网络。

Kimi 这条接口没有公开文档，对方改版会变成「额度不可用」。设置里贴 API key 的正规备选还没做。

---


记录日期：2026-08-12，命名与路线于 2026-08-13 更新。除「已落地」标注的条目外，其余仅作为后续设计与优化清单。

## 版本路线（整体）

- **v0.3（已完成）** Mac 版稳定化：`main.m` 模块化、SPM 骨架、XCTest 迁移、Codex 数据源 glob 探测与健康度、多显示器统一。
- **v0.4（进行中）** 命名与涟漪设计语言。命名已落地；运行时涟漪已按定稿写入 `CPRippleView`。还剩身份件：菜单栏同心弧、Logo、空状态、详情页返回入口。
- **v0.5** 接入更多 GUI Agent。
- **v0.6** 首次公开（Alpha）：许可证、README 风险说明、不含真实截图。身份件和打码截图可以在公开之后补，不必挡第一次上传。
- **v0.7 起** Agent 待办联动（原阶段二）。
- **v0.8 起** 澜台 Bridge + 手机 Web/PWA（原阶段三）。

必须串行的一处：涟漪身份件（图标、Logo）要在皮肤之前做完，否则色板会围着一套即将废弃的符号去定。原先「开源必须排在接入更多 Agent 之后」已取消——第一次公开按当前 Alpha 能力写清楚限制即可，能力清单随适配器再改 README。

## 命名（已落地）

产品定名**澜台**，英文 **Lantai**。澜取涟漪，台取观察台，正好对应「用涟漪表达状态的本地 Agent 观察台」。

完整的候选清单、每个名字的排除理由和检索证据见 [docs/NAMING.md](docs/NAMING.md)。简述：Buoy、Pond、Sonar、Ripple、Crest、Tarn、观澜、Lagoon 八个候选全部已被占用，其中四个直接撞在 AI Agent 工具这一小块上；听澜、静池、枕流、漪台查过无同名但因词义或读音落选。

已完成：

- 界面可见文案全部改为澜台：菜单栏菜单与退出项、菜单栏悬停提示、工作台卡片标题、添加 Agent 空态说明、快捷栏与悬浮球 tooltip。
- 本地化显示名：`Resources/zh-Hans.lproj` 显示「澜台」，`Resources/en.lproj` 显示「Lantai」，中文系统与英文系统各自干净，不用 `澜台 (Lantai)` 这种括号并列写法。仅 README 与仓库标题使用中英并列。
- 构建产物改为 `outputs/Lantai.app`；`build-app.sh` 在签名前拷贝 `.lproj` 资源。

刻意未改（改名不做数据迁移）：

- `CFBundleIdentifier` 仍为 `com.codexpulse.menubar`，可执行文件仍为 `CodexPulse`。单实例检测依赖这两项，保持不变可避免改名前后出现两个实例。
- 待办数据库仍在 `~/Library/Application Support/Codex Pulse/`。
- 源码目录 `Sources/CodexPulse/` 与 `CP` 类前缀不变。

以上三项留到首次正式发布时一次性迁移，届时需要同时提供待办数据搬迁逻辑。

## 涟漪设计语言

完整规格、实验室三条路线的取舍、以及身份件怎么做，见 [docs/DESIGN.md](docs/DESIGN.md)。下面只列待办。

**已落地（不要重开三条路线）：** HUD 选中态与悬浮球的运行时涟漪，`CPRippleView`，8 层明暗成对、基准 12s、状态只改周期。定稿原型是 `ripple-selection-preview.html`。`ripple-style-lab.html` 是实验室。`multitask-status-prototype.html` 已否决。

**还没做的身份件：**

- 菜单栏不要再按状态换 SF Symbol（现在是 `sparkles` / `pause.fill` / `moon.zzz.fill` 等）。改成**同一套**同心弧模板图标，用 tint 表示状态。16pt / 32pt，浅色与深色菜单栏分别验。菜单栏不开动画。
- Logo 与悬浮球中心、工作台标题旁、快捷栏「工作台」按钮，停用 `waveform.path.ecg`。静止同心弧，和 `CPRippleView` 同一套几何。
- 应用图标 1024（Finder / 关于 / GitHub 用）。App 是 `LSUIElement`，不占 Dock，但公开仓库需要能看见的图标。
- 「暂无活动任务」画静止水面；「数据源不可用」保持文字，不要画成空水面。

边界：涟漪不铺到任务卡、待办行、按钮、返回入口。速度绑运行状态，颜色绑状态语义，两者都不随皮肤变。

## 皮肤与主题（后续）

可行，但只做「换色」，不做「整套换皮」。现状已经有一层颜色入口（`CPAccent` / `CPBg` / `CPSurface` / 状态色），数值仍写死在 `CPDyn` 里；部分 `CALayer.CGColor` 是快照，换肤时要重新赋值，否则灯和描边会留在旧色上。

首版范围：

- 内置 2～4 套深色皮肤（例如当前石墨、更冷的午夜、更高对比），设置里切换，写入 `NSUserDefaults`。
- 皮肤只覆盖背景、表面、强调色、文字、状态灯。涟漪、圆角、布局、悬浮球尺寸不随皮肤改。
- 换肤后 HUD / 悬浮球 / 工作台 / 待办栏必须同一套色，不允许三处各画各的。

明确不做（除非皮肤稳定之后再开）：

- 用户导入自定义皮肤包、CSS、壁纸蒙层。
- 浅色皮肤（窗口目前强制深色；浅色要重做对比和菜单栏模板图标）。
- 按 Agent 换不同皮肤（容易让多 Agent 状态更难读）。

依赖：命名已定，还需先完成涟漪设计语言那一轮（图标、Logo、空状态），再抽可切换色板。不要和改返回按钮、改 Logo 抢同一批 diff。

与涟漪设计语言的边界（避免两节打架）：皮肤换的是背景、表面、强调色和文字；涟漪的几何、环数、速度不随皮肤变。状态灯属于语义色，倾向于固定，否则换一套皮肤就要重新教用户认颜色。

待决策：皮肤是设置里的隐藏项，还是工作台里的正式入口。

## 工作台 UI

- 重新设计“工作台 → 具体任务”详情页左上角返回入口。当前版本仍不满意；后续只重做视觉与交互反馈，不改变返回任务列表的逻辑。
- 后续评审详情页 Agent 直达入口的视觉表现，确保它与工作台整体风格一致。

## 状态与提示

- 再次确认五种提示灯的产品语义及颜色，尤其是“已完成”是否应统一显示为绿色。目前代码中任务完成色与 Agent 汇总灯的完成色仍需统一决策。
- 优化悬浮球提示气泡的可解释性：让用户能直接知道数字对应哪些任务、为什么出现，以及如何逐项或一次性清除。
- 评估是否需要把“已查看”和“已处理”拆成两个概念，避免点开详情后状态语义不清。

## 接入更多 Agent

判据要先于清单。澜台是只读观察者，能接的前提是对方**有 GUI 应用**，并且**把任务状态落到本地可读文件**。CLI/TUI 类工具（Claude Code CLI、Codex CLI 等）不满足第二条：它们的运行态只存在于终端进程里，除非托管 PTY 才看得见，而托管 PTY 会把澜台从观察者变成宿主，与产品定位冲突。参考 [OneWave-AI/Crest](https://github.com/OneWave-AI/Crest) 走的正是宿主那条路——它能对 CLI Agent 观察得很深，代价是用户必须在它里面开会话。这条边界不因为某个 Agent 流行就放宽。

候选按可行性排序，本地格式一律需要实测确认：

- Claude Desktop：有 GUI，需确认会话是否落本地库以及格式稳定性。
- Cursor：有 GUI，会话数据在 `state.vscdb`（SQLite），需实测键结构与跨版本稳定性。
- ZCode 及其他国产 GUI 客户端：先确认有无本地结构化状态，再决定是否排期。

每接一个都必须满足三条：

- 走 [docs/AGENT_ADAPTERS.md](docs/AGENT_ADAPTERS.md) 已定义的适配器边界，只读，不改写对方数据。
- 带健康度（复用 `CPAgentHealth`）。路径不存在、库打不开、schema 不认识时，界面要明确显示「数据源不可用」，不允许静默退化成「没有任务」——这正是 Codex 数据源那次问题的成因。
- 深链能力要写清楚：能精确跳回具体会话的和只能唤起应用的分开标注，不把「打开了应用」当成「打开了那个任务」。

## Todo / 待办整合

核心已于本版本落地：工作台底部常驻待办栏(收起/展开、新增、完成/恢复、行内编辑、删除、滚动),SQLite 本地持久化(`~/Library/Application Support/Codex Pulse/todos.sqlite`,沿用改名前的目录),表含 nullable `agent_id`/`thread_id` 预留 Agent 联动;计数只在 Todo 栏内,不进入 HUD/Dock badge/悬浮球/Agent 状态灯等提醒聚合。后续可选方向:

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

- 目标交互：用户在 Codex/Kimi 会话中直接说“把这个任务弄成一个待办”或类似指令，Agent 将当前上下文总结为结构化待办，并写入澜台。
- Agent 不应只把用户的原句机械复制为标题；它可从会话中提炼简洁标题、必要的下一步、所属项目和来源任务。首版字段保持克制，避免把 Todo 演变成另一套任务管理系统。
- 交互时区分“用户明确要求创建”和“Agent 主动建议”：前者可直接写入并回复创建结果；后者先进入待确认草稿或询问用户，不默认向 Todo 栏批量注入行动项。
- 创建成功后，Agent 应返回清晰确认，例如“已添加到澜台 · Agent 待办”；澜台中的待办保留返回该会话/任务的入口。
- 反向流程也作为后续构想：可以在澜台中新建 Agent 待办，选择对应 Agent 后从该待办启动一个新任务，或将其作为补充指令发送到已关联任务。

### 候选连通方式

- 不依赖澜台从自然语言日志中猜测“用户刚才是否想建待办”；更稳定的边界是由 Agent 识别用户意图后，显式调用结构化的 Todo 工具。
- 短期可为澜台提供本地受限 API/CLI，例如 `todo.create`，接收标题、Agent ID、Thread ID 和来源信息；只允许本机已授权调用，并使用指令 ID 防止重复创建。
- Codex 方向后续评估以 Skill、MCP 工具或 `codex app-server` 客户能力暴露“创建澜台待办”；Kimi 则通过其可用的工具/协议适配，不通过直接改写会话数据库实现。
- 手机端和 Mac 工作台使用同一套 Todo 写入接口和权限规则，避免将“Agent 转待办”“手机建待办”和“澜台界面建待办”实现成三套不兼容数据流。

### 待决策问题

- 界面是固定分为“个人待办 / Agent 待办”，还是保持一个列表并以来源筛选、标签或自动分组呈现。
- Agent 根据对话总结时，首版只生成标题，还是同时生成说明/下一步；哪些字段应该在 Todo 栏直接展示。
- 用户明确发出“转为待办”指令时是直接创建，还是先让 Agent 回显摘要并等待一次确认。
- 是否允许 Agent 主动提议待办，如果允许，建议项的数量上限、展示位置和拒绝后的降噪规则如何设置。

## 代码债与模块边界（2026-08-13 体检）

现状不是屎山：总量约 8500 行，数据层（`CPModels` / `CPTodoStore` / `CPAgentSources` / `CPStatusEngine` / `CPStateCache`）不依赖任何 UI 控制器，依赖方向干净。已知的债集中在 UI 层，先记账，不要求在做 Bridge 前偿还：

- `CPWorkbenchController.m` 1712 行；其头文件为自测暴露约 50 个内部属性，是最接近 god object 的地方。
- `CPSelfTests.m` 2607 行单文件。
- `CPHUDController` import 了 `CPWorkbenchController`（UI 咬 UI 的唯一一处）。

新增手机/Bridge 代码时的三条硬规矩（防止债扩散）：

1. Bridge 和 Agent driver 永远不 import 任何 Controller；UI 永远不 import Bridge。两边只依赖数据层。
2. 手机端只认识澜台 Bridge 自己的协议；各家 Agent 的协议细节藏在 driver 后面，对外只暴露能力标签（可指挥 / 只可观察 / 可打断 / 可审批）。
3. 每个 driver 自带健康度（复用 `CPAgentHealth` 语义），协议对不上就明确降级只读，不静默出错。

可选加固：若 `Package.swift` 的 SPM 路修通，把数据层拆为独立 target，让「Bridge 不许碰 UI」成为编译错误而非口头纪律。

## 手机联动与远程工作台

目标：为澜台增加手机客户端，可随时查看 Mac 上的 Agent/任务运行情况，完成审阅、处理待办，并在可靠的 Agent 接口范围内下发操作。Mac 端仍是本地任务和工作目录的执行主体，手机端不直接读写 Codex/Kimi 的数据库或任务文件。

### 2026-08-13 实测结论（Codex 控制通路已验证）

在本机实测，原「评估 `codex app-server`」一项已从假设变为事实：

- Codex Desktop 即 `/Applications/ChatGPT.app`，内置 `codex` 二进制（实测版本 0.147.0-alpha.6.5），且桌面端自身就在跑 `app-server`。
- `codex app-server --listen stdio://` 握手成功；`thread/list` 能读到 `~/.codex/sessions` 的真实会话（状态、预览、时间戳）。探测全程只读。
- 协议可用 `generate-json-schema` 自描述：95 个客户端方法（含 `turn/start`、`turn/steer`、`turn/interrupt`、`thread/resume`、`thread/rollback`），70 个服务端通知（逐字输出、命令输出、diff、计划、token 用量）。审批是服务端反向请求（Exec/ApplyPatch/Permissions/ToolRequestUserInput 四类），天然对应手机上的同意/拒绝按钮。
- 官方自带远程能力：`app-server daemon bootstrap --remote-control`（自述 for SSH-driven use）、`enable-remote-control`、`--listen ws://` 加 capability-token 鉴权。澜台不需要自己发明 Agent 控制协议。
- 协议标注 `[experimental]`、版本 alpha，会变。对策：启动时用 schema 自检，认不出就降级只读（接 `CPAgentHealth` 那套「数据源不可用」显示）。
- 待实测的第一个真问题：桌面端已有一个 app-server 在跑，澜台自起一个是双写；控制桌面端活跃会话应验证 `app-server proxy --sock` 接同一 daemon 的路子。→ 2026-08-15 已撞，结论见下一节：不能接。

多 Agent 控制的定调（2026-08-13，2026-08-15 修正）：区别不在「有没有后端」，而在「官方公不公开」。Codex 把协议文档、schema 和远程控制开关摆在明面上供人调用。Kimi 不是没有后端——本机 Kimi CLI 0.36.0（`~/.kimi-code/bin/kimi`）有公开的 `kimi acp`（按 Agent Client Protocol 跑在 stdio 上）和 `kimi web`（自带本地 HTTP + Web UI，默认端口 58627，bearer token 鉴权，`--host` 可绑 0.0.0.0；非 loopback 时 PTY 终端路由默认关、有 DNS-rebinding 检查、远程 shutdown 默认关）。Kimi 桌面端（`/Applications/Kimi.app`）后台跑 `daimon/.../cli.js start --control` 和 `~/.kimi-webbridge/bin/kimi-webbridge start --foreground`；本机 loopback 上 Kimi.app 主进程听 127.0.0.1:64032（HTTP GET / 返回 401）、kimi-webbridge 听 127.0.0.1:10086（404）、另有 node 听 127.0.0.1:51686（404）。桌面端这条本地 HTTP API 没有公开文档、没有稳定性承诺，靠逆向接入会在对方静默更新时失效，和澜台「只读、不改对方数据、对方挂了不影响你」的立身之本冲突。因此**首版仍然只做 Codex driver，Kimi 保持只读观察**，理由从「Kimi 没有协议」改为「Kimi 没有公开协议，逆向的可靠性代价不划算」。Claude Code（Agent SDK / stream-json）仍是次选。其他家若要指挥，走「Codex 编排 CLI + 澜台原生只读观察」（本机已装 Kimi CLI 与 Claude Code CLI，Codex 驱动 Kimi CLI 的模式已有 kimi-cli-supervisor skill 实践）。代价记录在案：观察被压扁成命令输出、双份 token、打断粒度粗。UI 上「通过 Codex 转达」与「原生指挥」必须分开标注。

后续可能性：`kimi acp` 走的是公开标准。澜台若将来支持 ACP，同一份工作量可能顺带覆盖 Kimi CLI 及其他支持 ACP 的 Agent，值得单独评估。但 ACP 类工具多为 CLI，和澜台「只接有 GUI 的 Agent」的现有边界有张力——接 ACP 等于把观察者往宿主挪一步，不能当成「顺便多接一家 GUI」来做。

### 2026-08-15 实测结论（daemon 可接性）

撞了上一节那个「整条路线唯一的真风险」：桌面端已经在跑一个 app-server，澜台能不能用 `app-server proxy --sock` 接上同一个进程，从而观察并（未来）指挥用户在 Codex Desktop 界面里开的会话。

探测（全程只读，没发任何 turn 命令，没开 remote-control，没改 `~/.codex/`）：

- 二进制仍在 `/Applications/ChatGPT.app/Contents/Resources/codex`，版本已从 0.147.0-alpha.6.5 升到 **0.148.0-alpha.9**。
- 桌面端进程命令行是 `codex -c features.code_mode_host=true app-server --analytics-default-enabled`，父进程是 ChatGPT.app。没有 `--listen`，走默认 `stdio://`。`lsof` 看不到 LISTEN 的 TCP 或 unix 插座；stdin/stdout 是连到父进程的管道。
- 官方默认控制插座 `~/.codex/app-server-control/app-server-control.sock` 不存在，连目录都没有。`codex app-server proxy`（默认路径）和 `app-server daemon version` 都立刻报 `failed to connect to .../app-server-control.sock`（No such file or directory）。
- `proxy --sock` 的默认目标就是上面这条路径；帮助里没有别的自动发现。本机这版也没有上游后来加的 `--ensure-listener`。
- `~/.codex/ipc/ipc.sock` 在，但是 ChatGPT 主进程自己的 IPC，不是 app-server 控制面。`proxy --sock` 指过去立刻以 exit 0、空输出退出，接不上协议。
- 对照：自起一个 `app-server --listen stdio://`，握手成功，`thread/list` 能看到桌面端写进 `~/.codex/sessions` 的会话（`source` 为 `vscode`，含当天仍在更新的那条），但全部 `status.type = notLoaded`。桌面端那个 app-server 进程全程还在。说明自起进程读的是落盘历史，不是桌面端进程里正开着的活跃会话。

**结论：不能接。** `proxy --sock` 接的是「托管 daemon」的控制插座；桌面端把自己的 app-server 当子进程、用 stdio 私聊，根本没开这条路。

对产品形态：手机不能指挥用户在 Codex Desktop 界面里已经打开的会话。首版只能指挥澜台自己托管的任务；桌面端已有会话继续只读观察（读 `~/.codex/sessions` 落盘）。「能列出同一批会话」和「接上桌面端那个进程」不是一回事——前者 08-13 就成立，后者今天确认不成立。

后续可选路径（只读帮助，没执行）：

- `daemon bootstrap --remote-control` / `enable-remote-control` 装的是**另一套**托管 daemon，不是把桌面端那个 stdio 进程变成可接的。帮助原文写的是给「currently running managed daemon」开远程控制。没开，也不该为了接桌面端去开——那是再起一个写者，双写风险还在。
- 若将来桌面端自己改成 `--listen unix://`，`proxy --sock` 才可能接上；本机 0.148.0-alpha.9 没有这个迹象。
- 实现 driver 时注意：stdio 是 JSONL；官方 unix 插座走 WebSocket upgrade，`proxy` 只是把字节接到 stdio，不是 JSONL 直连。不要把 `proxy` 对错插座的 exit 0 当成接上了。

### 第一阶段已落地（2026-08-14）

只读观察 + 待办读写这一刀已经可用，契约见 [docs/BRIDGE_API.md](docs/BRIDGE_API.md)：

- `Sources/CodexPulseBridge/`：自写 HTTP + SSE（BSD socket + 独立 accept 队列），配对码 / token / 设备管理独立成 `CPBridgePairing`，token 存 Keychain。
- 手机端 `Resources/mobile/`：无依赖 PWA，色板与涟漪规格直接取自 Mac 端 `CPStatusEngine` 与 `CPRippleView`；`?demo=1` 显式演示态，真实模式连不上只显示离线，不拿假数据兜底。
- 入口：工作台标题栏 iPhone 图标按钮 + 菜单栏「连接手机…」双入口。原打算只放菜单栏（配对是一次性动作，不该占标题栏），实测失败——菜单栏图标多时被系统折叠，用户找不到，只能承认「找不到的入口等于不存在」。工作台按钮只发 `CPConnectPhone` 通知，不 import Bridge。
- `CPPairingSheetController` 显示二维码 + 六位码 + 倒计时，Bridge 未启动时明说而不画空码。
- 配对成功自动关卡片：Bridge 发 `CPBridgeDevicePairedNotification`（只带设备名，token/deviceId 不出 Bridge），卡片显示「<设备> 已连接」并撤掉已失效的码，1.4s 后关闭；自测态不排延迟，直接断言确认态。
- 二维码走 CoreImage `CIQRCodeGenerator`，按整数倍放大后原尺寸显示；自测用 `CIDetector` 回读断言扫得出且内容一致。
- 分层守住：Bridge 不 import 任何 Controller，UI 不 import Bridge，手机端只认澜台协议。
- 自测：`Bridge self-test` 14 项（含鉴权、幂等 opID、锁定、路径脱敏、SSE、SO_SNDTIMEO），`Pairing UI self-test` 7 项。

审阅修掉的三处（记账，避免重犯）：

- SSE 鉴权原本只认 Authorization 头，而浏览器 `EventSource` 无法设自定义头，实时推送必然 401。现仅 `/api/events` 额外接受 query token。
- `activity` / `title` 会把家目录绝对路径带给手机。现在 Bridge 输出层统一脱敏为 `~`，不改 CPTask 与 Mac 端显示。
- SSE 阻塞写跑在状态队列上且未设 `SO_SNDTIMEO`，手机断网可致整个 Bridge 假死。现已设写超时并在失败时清理客户端。

尚未做：手机端指挥 Agent（第二阶段）、异地访问（Tailscale，未实测）。真机配对全链路已由用户实测通过。

### 接下来的五步（2026-08-15 改序：指挥优先）

2026-08-14 的顺序是「先看得准（2A 实时读）→ 再能指挥（2B/2C）」。2026-08-15 用户改成**指挥优先**：先把手机能下指令做出来，实时逐字输出往后放。理由变了——没有指令通道，看得再准也只是观察台；指挥的价值不依赖先看到逐字流。

知情代价（不是疏漏）：没有实时流之前，手机上发完指令要等 `~/.codex/sessions` 落盘才看到结果，有秒级延迟且看不到过程。用户知情后接受。

#### 1. 撞 daemon 可接性（2026-08-15 已做）

就是上一节。结论：不能接。产品形态已定：只指挥澜台自己托管的任务，桌面端已有会话保持只读。

#### 2. 搭控制通道骨架

Bridge 侧先把写通路的架子立住，还不必真的去叫 Codex：

- 指令队列：验设备权限 → 验任务归属 → 验当前状态，再执行，回传已接收/执行中/成功/失败。
- opID 幂等复用第一阶段那套。
- 权限校验；对外只暴露 `capabilities` 能力标签（可指挥 / 只可观察 / 可打断 / 可审批），各家协议细节藏在 driver 后面。
- 端点契约写进 [docs/BRIDGE_API.md](docs/BRIDGE_API.md)，手机端只认澜台自己的协议。

#### 3. 接上 Codex driver，只开三个动作（2026-08-16 已完成）

`CPCodexDriver` 自起 `codex app-server --listen stdio://`，JSONL JSON-RPC。不接桌面端那个进程。只开 `thread/start` + `turn/start` / `turn/steer` / `turn/interrupt`。

实现要点与踩坑：

- `start` 是两步：先 `thread/start`（cwd / `approvalPolicy: on-request` / `sandbox: workspace-write`），再 `turn/start`。`resultTaskID` 是 `thread.id`。任一步失败要说清是哪一步。
- `steer` / `interrupt` 都要 `turnId`，手机不可能知道。Mac 端从 `turn/start` 响应和 `turn/started` 通知跟踪每个线程的活跃 turn，`turn/completed` 时清掉；没有活跃 turn 就明确失败，不发空 id。
- 审批反向请求（Exec / ApplyPatch / Permissions / ToolRequestUserInput，含新旧 method 名）暂时自动拒绝，并写「澜台暂不支持远程审批」。不回复会把 turn 挂死。
- 工作目录是 Mac 白名单 `control.workdirs.v1`（`workdirID` + 显示名 + 绝对路径）。Bridge 解析 ID、把路径填进 `CPAgentCommand.workdir`；快照和命令 JSON 只给 ID/名，路径不出网。driver 不再读 defaults。
- `-32601` 整段降级不健康；请求 30s 超时；子进程意外退出立刻不健康并带 1/2/4s 退避重启最多 3 次。澜台退出杀掉自己拉起的 app-server。

#### 4. 手机端指挥 UI

按 `capabilities` 渲染按钮。不可指挥的 Agent 不给按钮。「原生指挥」与「通过 Codex 转达」（Kimi/Claude 走 CLI 编排那条）必须分开标注，不能让用户以为两者可靠性一样。Mac 端除了设备授权开关，还要有管理项目白名单的界面（增删目录、起显示名）；手机只从快照 `workdirs` 里按 `workdirID` 挑选。

**Mac 端已完成（2026-08-17）：** 菜单栏「手机指挥设置…」可按设备打开「允许指挥」、撤销配对，并增删白名单项目。白名单抽到数据层 `CPWorkdirStore`，设置变更后 Bridge 主动重推快照。手机端指挥按钮由并行任务完成，此处不宣称。

#### 5. 实时逐字输出（原 2A，降级到这里）

现在手机看到的是 `~/.codex/sessions` 落盘后的结果，秒级滞后且没有过程。这一步把 `codex app-server` 的实时通知接进来。

- driver 把服务端通知折叠成澜台自己的少数几种事件（逐字输出、命令输出、diff、计划、token 用量、等待审批）。
- Bridge 侧加事件类型；`docs/BRIDGE_API.md` 同步扩事件表。
- 完成判据：手机上能逐字看到 Codex 正在写的内容，且拔掉 app-server 后手机明确显示降级而不是空白。

#### 2C. 审批（五步之后，真正把手机变成遥控器的那一步）

app-server 的四类反向请求（Exec / ApplyPatch / Permissions / ToolRequestUserInput）天然对应手机上的同意/拒绝。做到这里，「人在外面，Agent 卡在等确认」才算解决。审批请求有超时，手机端要显示剩余时间，过期要如实说明是超时而不是拒绝。依赖第 3 步的 driver 和第 2 步的指令队列，不插到指挥三动作之前。

#### 待办系统升级（已选定范围，2026-08-14 用户确认）

要做：**截止时间 + 到期提醒、四象限、拖拽排序、个人/Agent 分区、已完成归档**。备注/子项这次不做。

`CPTodoStore` 已有 `PRAGMA user_version` 的 switch 式迁移框架（当前 v1），加字段是 v1→v2 一个 case 的事，成本低。

先说清一个必须先解决的矛盾：**四象限装不进现在的待办栏。** 现在展开态给列表的只有 520×158（5 行），2×2 矩阵摊下来每格约 250×70，等于每格两行，加上象限标题就没了。所以四象限不是「加个字段再排一下」，它要求待办有自己的一块地方。三条路：

- A. 待办升级成工作台里可切换的一个独立视图（任务视图 ↔ 待办视图），四象限占满 520×360。底部那条常驻横条保留，只做快速新增和计数，点开进视图。
- B. 待办另开一个窗口。工作台不动，代价是多一个窗口要管，和「一张卡」的产品调性冲突。
- C. 四象限只在手机上做，Mac 保持线性列表。数据同源、呈现分化，成本最低，但两端体验不一致。

倾向 A。指挥通道走完再回头定这个，再动数据层——顺序反了会做出「字段齐了但界面塞不下」的东西。四象限本身不挡手机下指令。

字段草案（v1→v2，一次迁移做完，避免连着改三次表）：

- `due_at REAL NULL`：截止时间。到期提醒的触发在 Mac 端算，不依赖手机在线。
- `urgent INTEGER NOT NULL DEFAULT 0` / `important INTEGER NOT NULL DEFAULT 0`：四象限就是这两个布尔的组合，不要存 `quadrant` 枚举。理由：拖到另一个象限只是改一个布尔，且「重要不紧急」这类筛选天然可做；存枚举以后想单独按重要性排序就得再迁移一次。
- `sort_order REAL NOT NULL`：拖拽排序。用浮点而不是整数，插入两行之间取中间值即可，不必重排整列。排序作用域是「同一象限 + 同一分区内」，跨象限拖拽等于改象限。
- `archived_at REAL NULL`：归档。归档是软状态，不是删除；`allTodos` 默认不返回已归档，另开一个查询。
- 分区复用已有的 `agent_id`：非空即 Agent 待办。不新增分区字段。

其他要注意的：

- 到期提醒的落点取决于推送那一档。HTTPS 没通之前，提醒只能是 Mac 端本地通知 + 手机打开时看到；通了之后才能锁屏推送。所以「截止时间」和「提醒」实际是两步，可以先做前者。
- 已有 34 条真实待办在库里，迁移必须能就地升级而不是重建表；迁移后跑一次自测确认旧数据的 `sort_order` 有确定值（按现有 created_at 升序回填），否则排序会是随机的。
- 手机端 UI 要重新设计：窄屏摊不开 2×2，大概是象限做成四个可折叠分组或者顶部筛选片，和 A/B/C 一起定，不插到指挥五步前面。

硬规矩：Mac 与手机共用同一套写入接口和字段，不允许手机端自己加字段。加字段时同步 `docs/BRIDGE_API.md`，否则两边必然漂移。

#### 开工顺序（2026-08-15 改：指挥优先）

2026-08-14 夜原定「先定待办界面 → 补 PWA → 待办 v2 → 再撞 daemon」。2026-08-15 作废，改成下面五步。待办界面和免费档 PWA 可以插空，但不挡指挥。

1. **撞 daemon 可接性**（已做，见「2026-08-15 实测结论」：不能接）。
2. **搭控制通道骨架**（已做）：Bridge 指令队列、opID 幂等、权限校验、`capabilities` 能力标签、端点契约写进 `docs/BRIDGE_API.md`。
3. **接上 Codex driver**（已做）：自起 app-server，只开 `start` / `steer` / `interrupt`；turnId 由 Mac 跟踪；审批暂自动拒绝；项目白名单按 ID 选择。
4. **手机端指挥 UI**（已做）：Mac 端授权开关与项目白名单在菜单栏「手机指挥设置…」；手机端右下角「+」新建任务（先选项目再写指令），托管任务上有「补充一句」和需二次确认的「打断」，只读任务只标「只读观察」不给灰按钮。按钮一律按 `capabilities` 渲染，不对任何一家 Agent 写死。指令成功的文案是「已送达 Codex」不是「完成」——`succeeded` 只代表 Codex 收下了，活还没干完。
5. **实时逐字输出**（原 2A）。没有这一步之前，发完指令要等落盘才看到结果，有秒级延迟且看不到过程。

第四步做完时留下的三条（2026-08-17）：

- **禁用按钮必须当场说明理由**。多个项目时故意不预选，不替人决定 Agent 往哪个目录里写文件，这个决定要保留。但当时的做法是：没选项目就把发送按钮置灰，而「请先选择要在哪个项目里干活」这句提示写在 `submitSheet` 里，要按下发送才出得来——按钮恰恰按不动，于是那句话永远显示不出来。已改成打开底栏就直接提示。以后再加禁用态，先问一句「用户看得到为什么吗」。
- **`capabilities` 是按 Agent 算的，不分设备**。新配对的手机 `canControl` 默认关闭，但快照里 Codex 仍然带 `control`，所以未授权的手机会看到按钮，点下去才被 403 挡住，提示「这台手机还没有指挥权限，请在 Mac 上的『手机指挥设置』里打开」。提示是可操作的，Mac 端配对卡片也会提一句去菜单栏授权，所以暂不改。真要修得让快照按设备身份下发，得把设备 token 一路穿到 SSE 广播里，代价不小，等有第二台手机再说。
- **手机端 2000 行 JS 没有任何自测覆盖**，ObjC 那套 `--self-test` 管不到。这次是临时用 Playwright 起无头 Chromium 跑了 19 项（渲染、按钮按 `capabilities` 出没、状态流转文案、三个错误码的实际中文、打断二次确认、视口压到 450px 的布局、控制台零报错）。脚本是一次性的，没进仓库。如果手机端还要继续长，值得把它固化成 `scripts/` 里的一个检查项，否则改 JS 只能靠手点。

关于「功能落了 UI 还能不能改」（原 08-14 夜那条，对后续待办升级仍然成立）：数据层加字段和界面怎么长是解耦的，`urgent`/`important`/`sort_order` 这几个字段无论最后画成四象限、列表还是筛选片都用得上，改界面不用动库。真正会锁死的是**尺寸决策**——`CPCardWidth 520` / `CPCardHeight 360` 是硬编码常量，自测里有 `card-520x402` 这类断言钉着；一旦按 520 宽把四象限的布局细节都排完，再改成别的宽度就要连自测一起返工。所以待办升级回头做时，仍先定尺寸和形态，再动布局细节。

#### 装成 iPhone App（PWA，2026-08-14 查证）

结论：**能装成看起来完全像原生 App 的东西（全屏、自己的图标、独立进程），但要拿到推送和角标，必须先解决 HTTPS。**

现状（`Resources/mobile/`）：已有 `apple-mobile-web-app-capable` 等 meta，加到主屏就能全屏无地址栏运行；但没有 manifest、没有图标、没有 service worker。

分成两档，成本差很远：

- **免费的一档（不需要 HTTPS，随时可做）**：补 `manifest.json`（`display: standalone`、图标、`theme_color`、`start_url`）+ 一套 App 图标 + 手机端一句「点分享 → 添加到主屏幕」的引导。iOS 没有 `beforeinstallprompt`，也没有任何 API 能唤起分享面板，装不装只能靠引导文案。做完就有独立图标、全屏、独立进程。iOS 对主屏 Web App 的存储不套用 Safari 那个 7 天清理，token 不会莫名失效。
- **要 HTTPS 的一档（推送 + 图标角标）**：`navigator.setAppBadge()`（把待办数/待审批数打到图标上）和 Web Push 都只在「已加到主屏的 Web App」里存在，且 **service worker 与 Push 强制要求 HTTPS，iOS 连 localhost 都不豁免**。我们现在是 `http://192.168.x.x:8787`，注册不了 service worker，这一档一行代码都不通。

HTTPS 两条路，建议选第一条：

1. **Tailscale + `tailscale serve`**：拿到 `*.ts.net` 的真证书，顺带把「异地访问」一起解决（本来就在 backlog 里）。代价是 Mac 和手机都要装 Tailscale。
2. **mkcert 自签 + 手机装根证书**：不依赖外部服务，但用户要在 iOS 设置里手动「证书信任设置」开完全信任，讲不清就是劝退。

Web Push 的其他硬约束（做之前照着核对，避免白写）：manifest 必须 `display: standalone`（否则 iOS 上 `registration.pushManager` 直接是 undefined）；权限必须由真实点击触发，页面加载时请求会被自动拒；不支持静默推送，收到 push 必须 `showNotification`，否则 iOS 会吊销通知权限；`actions` 按钮、`image`、`vibrate` 等选项被 WebKit 静默忽略，通知内容全部塞进 title 和 body；VAPID 走标准协议，Mac 端 Bridge 可以自己直接向 `web.push.apple.com` 发，不需要第三方服务器。可靠性上留一手：iOS Web Push 有重启后不触发、静默掉订阅的既有毛病，`pushsubscriptionchange` 要处理，每次启动重查 `getSubscription()`；关键信息不能只走推送这一条路。

待验证：`setAppBadge` 是否也需要先拿到通知权限（多处实践称需要，未在本机确认）。

### 第一阶段：Mac 本地 Bridge + 手机端 MVP

- 在澜台内置轻量 Bridge，对手机提供结构化 API，不把本地 SQLite、JSONL、登录信息或工作目录直接暴露给网络。
- REST 负责快照和写操作，WebSocket 或 SSE 负责实时任务状态、活动、审批请求和 Todo 变化。
- 手机端先实现响应式 Web/PWA，验证任务列表、详情、审阅和 Todo 交互；需要更稳定的后台通知、相机/文件和系统集成时，再评估 SwiftUI iOS 客户端。
- 首版支持：电脑在线状态、Agent 汇总状态、任务列表/详情、实时活动、已审阅标记，以及 Todo 的新增、编辑、完成/恢复和删除。
- 手机端维持可丢弃的本地缓存；第一阶段以 Mac 上的澜台数据为唯一真实来源，不做两份 SQLite 文件同步。

### 连接、配对与安全

- 局域网内可用 mDNS 发现；异地访问的首个可用方案优先采用 Tailscale 等私有组网，暂不自行实现 NAT 打洞。
- Mac 显示一次性二维码，手机扫码后完成设备配对；二维码不存放长期明文密钥。
- 设备凭据保存到 Keychain，支持在 Mac 上查看已配对设备、撤销设备和查看最近活动。
- 权限分级：只读查看、管理 Todo、标记审阅、查看 diff/文件、控制 Agent、执行高风险操作。
- 写操作使用 UUID 指令 ID、版本号和幂等处理；删除文件、执行命令、放宽权限等操作在手机上二次确认，Mac 保留审计结果。

### Agent 审阅与控制边界

- 现有 Codex Desktop/Kimi App 任务继续保持只读观察与原应用跳转，不通过改写它们的 SQLite/JSONL 实现控制。
- 新增“澜台托管任务”概念：由澜台通过可支持的 Agent 接口启动与管理，才开放手机端输入、审批、中断和恢复等完整控制。
- Codex 方向评估使用官方 `codex app-server`：澜台 Bridge 对手机提供稳定协议，内部通过 stdio 或 Unix socket 转换 JSON-RPC，不直接依赖其实验性 WebSocket transport。
- 手机审阅界面后续支持：回答 Agent 问题、命令/网络/文件修改审批、Git diff 查看、补充指令、中断运行中 Turn，以及完成/失败/等待处理通知。
- 所有 Agent 控制指令先进入 Mac 端指令队列，由澜台验证任务所有权、当前状态和设备权限后执行，再回传已接收/执行中/成功/失败结果。

### Todo 多端同步

- 第一阶段不要求中心服务器：手机通过 Bridge 操作 Mac 上的 Todo Store，Mac 保持在线时实时同步。
- 不使用 iCloud Drive、Syncthing 或其他文件同步方式直接复制正在使用的 `todos.sqlite`；同步对象应为 Todo 记录或操作日志。
- 为未来同步迁移 Todo ID 为 UUID，并增加 `version`、`device_id`、`updated_at`、`deleted_at`/墓碑等字段；将需要跨设备共享的已审阅状态从 `NSUserDefaults` 迁入可同步的存储。
- 明确冲突策略：完成状态可采用最后写入优先；标题同时修改时保留版本或提示冲突，避免静默覆盖。
- 若仅面向个人 Apple 设备，评估 Core Data/CloudKit：无需自建服务器，可在 Mac 离线时继续用手机修改 Todo，恢复联网后同步。
- 若需要 Web/Android/多人或脱离私有组网，后续增加可自托管的澜台 Relay；参考 Happy 的零知识模式，服务器只保存端到端加密的 Todo 变更、任务摘要和待投递指令。

### 通知与离线体验

- 定义通知类型：任务完成、执行失败、等待审批、等待用户回答，以及手机指令执行失败。
- PWA 首版在前台通过实时连接更新；如需稳定的锁屏/后台推送，评估原生 iOS + APNs，或为 Web Push 引入最小通知服务。
- Mac 离线时手机明确显示“最后同步时间”；仅 Bridge 模式下不伪造已成功的写操作，引入 CloudKit/Relay 后才允许将离线变更排队待同步。

### 参考项目与选型依据

- [Happy](https://github.com/slopus/happy)：手机/Web/CLI + 云端加密同步，参考其端到端加密、多设备和异步指令。
- [CC Pocket](https://github.com/K9i-0/ccpocket)：手机 Flutter 客户端 + Mac Bridge + WebSocket/Tailscale，是首版本地 Bridge 架构的主要参考。
- [MobileCLI](https://github.com/MobileCLI/mobilecli)：Rust daemon + PTY + WebSocket + 二维码配对；参考配对和指令安全，不把终端字节流作为澜台主协议。
- [Yep Anywhere](https://github.com/kzahel/yepanywhere)：手机优先的响应式 Web 界面、本地进程持有与可选加密中继，参考 PWA 产品形态。
- [RustDesk](https://github.com/rustdesk/rustdesk)：参考发现/P2P/中继分层；当前阶段用私有组网替代自研打洞和中继。
- [Codex app-server](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)：Codex 托管任务的官方协议基础，参考 Thread/Turn、实时事件、审批和用户输入流程。

### 待决策问题

- 首版是否只面向个人使用，并要求 Mac 必须在线。
- ~~手机首版是 PWA，还是直接开发 SwiftUI iOS 客户端~~ → 已定 PWA 并落地；加主屏后即为独立全屏 App，暂无换原生的理由。
- 异地访问是否接受用户安装 Tailscale，以及什么阶段引入澜台 Relay。倾向接受：Tailscale 同时解决 HTTPS（`*.ts.net` 真证书），是通往推送与图标角标的唯一低摩擦路径。

2026-08-17 复核（用户问「别人也必须装吗，是不是叠床架屋」）：不是叠床架屋，这是同类工具的标准做法，且不进澜台的代码——Bridge 本来就 `INADDR_ANY`，Tailscale 一通即用。三条路的实际取舍：

- **私有组网（Tailscale）**：两端各装一个 App、登同一账号。流量端到端加密，不碰公网。最接近的开源同类 [Wakili](https://github.com/AhmeedGamil/wakili)（手机控制 Claude Code 与 Codex）给的就是 LAN / Tailscale / Cloudflare 三档，Tailscale 那档同样要求两端都装。社区那批「手机跑 Claude Code」教程主流也是 Tailscale + SSH + tmux。**仍是首选。**
- **厂商转发**：Claude Code 2026-02 的 Remote Control（research preview）纯出站 HTTPS、零网络配置，但限 Pro 及以上订阅、API key 不给用、不能从手机新建会话、断连约 10 分钟后会话就死。澜台不是厂商，走这条得自己跑 relay，排除。
- **公网隧道（Cloudflare Tunnel / ngrok）**：只在 Mac 装，手机什么都不用装，代价是澜台挂上公网、只靠 token 挡，且 Cloudflare 在边缘终结 TLS（能看到明文）。澜台能让 Codex 往用户项目里写文件，属于「敏感服务」那一类，业界建议对这类优先选传输型而非 TLS-MITM 型。**不采用。**

唯一要改的代码：配对二维码印的是 `preferredLANAddress`（优先 `en0`），出门就不认。需要同时给出 tailnet 地址（`100.x.y.z`），否则得手输。另注意 token 存在 localStorage 里按 origin 隔离，WiFi 地址和 tailnet 地址是两个 origin，要在家先用 tailnet 地址配一次。用户 2026-08-17 决定先做实时输出，此项押后。
- ~~待办升级先做哪几项~~ → 已定：截止时间+提醒、四象限、拖拽排序、个人/Agent 分区、已完成归档；备注/子项不做。
- 待办四象限放在哪（工作台内独立视图 / 另开窗口 / 只在手机做）。指挥五步走完再定，不挡手机下指令。
- ~~桌面端已有会话能否通过同一 daemon 指挥~~ → 已定：不能接；首版只指挥澜台托管任务，桌面端会话保持只读。
- ~~先看得准再指挥，还是指挥优先~~ → 已定：指挥优先；实时逐字输出降到五步最后，知情代价是落盘延迟、看不到过程。
- Todo 是否要支持 Mac 离线时在手机修改；若需要，优先选 CloudKit 还是跨平台 Relay/CRDT。
- “已审阅”是账号级状态还是每设备状态，是否与现有“已查看/已处理”语义一起重新设计。

## 性能

- 分析两秒刷新、SQLite 查询、rollout 文件尾部读取、AppKit 重建视图及涟漪动画的开销。
- 优先采用增量刷新和缓存，减少无变化时的数据库、文件读取和视图重建。
- 增加空闲、任务运行中、HUD 展开时的 CPU/内存基准，优化后做前后对比。

关于在自测里断言墙钟（2026-08-17）：不要拿紧边界当门槛。Kimi 的 `lru-stable` 原本把「600 个 state 两轮遍历各自 <0.5s」和缓存正确性绑在一条断言里，结果自测一旦与构建或别的任务同时跑就随机变红——实测同一份代码，闲时 0.17s，紧跟构建之后 1.36s，八倍差距全来自机器负载。已拆成 `lru-stable`（解析计数、条目数，与负载无关）和 `lru-timing`（上限放到 3.0s，只挡数量级退化）。真正守住这里性能的是「第二轮解析器必须只被调用 600 次」这类计数断言，墙钟只是兜底。后续加性能断言照此办理：机器忙不忙是环境事实，和「本机有没有装 Codex」是同一类，不该判失败。

## 开源准备

首次公开按当前 Alpha 上传，不等身份件、不等更多 Agent、也不做 bundle id 迁移。早期 clone 的人会经历一次内部 ID 搬家，README 写明即可。

已完成 / 本轮要完成：

- LICENSE：MIT。
- README：非官方、只读、私有格式可能失效、不承诺兼容；中文正文，附简短英文说明。
- `.gitignore`：不提交 `.od-skills/`、`*.artifact.json`、否决原型、构建产物。
- 不提交个人绝对路径；`.agents/skills/` 已忽略。
- 不发布 `outputs/`，使用者自行 `zsh scripts/build-app.sh`。

仍待补（公开之后可以再做）：

- 打码截图。工作台里的项目名、绝对路径、任务标题一律打码；没有打码的实机图不要放。
- 菜单栏 / Logo / 应用图标替换完成后，再换 README 顶图。
- GitHub 仓库名用 `lantai`；显示名写「澜台 / Lantai」。

## 实现记录：实时活动流 Mac 侧（2026-08-17）

按 `docs/BRIDGE_API.md`「实时活动流（第三阶段）」落地，契约未改。分工按文档原话切：**driver 只负责折叠，Bridge 负责限流、截断、补抓**。

- Agents 层新增 `CPActivityEntry` / `CPActivityKind` / `CPActivityMerge`（`CPAgentControl.h`）。`CPCodexDriver` 把 app-server 的通知折进七种 kind，暴露 `onActivityEntry` / `onActivityFlush` / `onActivityLive` 三个 block，全程不认识 HTTP/SSE；接线只发生在 `CPAppDelegate` 这个组装根。
- Bridge 侧每任务一条流：合并中的那条 `pending` 定稿后才分配 `seq`（从 1 起，不复用不回退），推送受每任务 250ms 闸门约束，kind / item / 合并方式一变就把手里那条定稿以保证顺序。上限 40 条 / 10 个任务 / text 400 / detail 2000（保留尾部）。
- 路径脱敏两层都做：driver 折叠时按该任务 workdir 换项目名（新增 `CPAgentCommand.workdirName`，由 Bridge 从白名单带过去，不进任何给手机的 JSON），Bridge 序列化前再跑一遍 `CPBridgeRedactPaths`——跨 delta 被劈成两半的路径只有合并后才补得掉。
- 几处契约没写死、由实现拍板的地方：`item/started` 只用来记住命令行给 `run` 当标题，本身不产生条目、不占 `seq`；快照式通知（`turn/plan/updated`、`turn/diff/updated`、`thread/tokenUsage/updated`、`fileChange/patchUpdated`）按覆盖而不是追加合并，告警各自成条；`command/exec/outputDelta` 只带 connection 级 `processId`，无法归属任务，落在丢弃分支。

自测新增一组 22 项（`Activity stream self-test`），用真 driver + 假 transport + 真 Bridge，不跑真 turn、不碰用户 defaults。限流一项断言的是**次数**（100 条 delta 只产生 1 条 entry、1 次推送），不是耗时；唯一沾墙钟的 `timer-push` 用 3.0s 上限只验「到点确实会自己推」，与本文件「关于在自测里断言墙钟」那条一致。已在满负载（8 路 CPU 占满）下连跑验证不抖。

## 实现记录：实时活动流手机侧 + 契约回填（2026-08-17）

手机侧只动 `Resources/mobile/assets/app.js` 与 `app.css`，`index.html` 未改（面板整个由 JS 建）。七种 kind 各有图标、颜色与排版；未知 kind 走中性的 `other` 样式而不是归并到 `note`——那会把普通输出画成警告。日志框固定高度独立滚动，贴底才自动跟，用户往上翻时新条目只在角落亮一个「新内容 ↓」，不抢滚动位置。`prefers-reduced-motion` 下动画全关。

补抓按契约实现：`expected = 上次 seq + entries.length`，不等就重拉 `/api/snapshot`，一条都不自己拼。重对齐做了 1.5 秒合批限速，弱网连着漏几次也只拉一次。快照回来时是**合并**不是替换——快照只带最近 40 条，直接替换会砍掉用户正在往上翻的历史；洞比服务端窗口还大时在断点处画虚线写明「中间漏了 N 条」，不假装连续。

### 契约回填

上面两侧是**并行独立**写的，事后核对发现关键处正好一致（空批沿用尾部 seq、`stream` 缺失退回 `activity`），但这几条契约里原本没写死，靠的是两边各自猜对。已回填 `docs/BRIDGE_API.md`，把默契变成明文：

- **空批次合法且必须不占 `seq`。** 只翻转 `live` 时发 `entries: []` 并沿用当前尾部 seq。若给降级通知配 +1 的 seq，手机每次断开都会误判漏批、白拉一次整包快照。
- **`stream` 缺失 ≠ 空对象。** 托管任务没输出、或被「只跟踪最近 10 个」挤出去时字段缺失；空对象会让手机以为实时流是空的。手机遇到「`managed == true` 但无 `stream`」不清屏，只改标断开。
- **「立即冲刷」= 定稿并分配 seq，不是立刻发帧。** 原文与「最多每 250ms 推一次」字面冲突。唯一立刻发的是 `live` 翻转，那是状态变化不是吞吐。
- **截断方向分开写明**：`text` 保留头部（标题价值在开头），`detail` 保留尾部（命令输出价值在末尾）。原文只对 detail 说了。
- **快照式通知按覆盖合并**，告警各自成条；原文只规定了 delta 必须合并。
- 手机无基线时 `上次见到的 seq` 取 0，中途加入必然走一次快照对齐；SSE 重连若重放最后一批同理。都是设计如此。

### 两处已知空缺（未修，已写进契约）

- `command/exec/outputDelta` 从 `run` 的来源表里移除：它的 params 没有 `threadId`，`processId` 是客户端发 `command/exec` 时自带的连接级 id，而澜台从不发这个请求，所以这条通知既不会来、来了也归不到任务上。
- **没有输出的命令不留痕迹。** `run` 只由 outputDelta 触发，`rm x` 这类静默命令在手机上看不到任何 `run` 条目。命令行其实在 `item/started` 里，但让它产生条目会改 `seq` 语义，属于改契约，留到下一阶段。

### 还没验的

两边都没跑过真实 Codex turn。Mac 侧用真 driver + 假 transport，手机侧用 Playwright + mock 数据，各自都绿，但**折叠逻辑对上真实 app-server 通知流的表现没有验过**。这是当前最大的未知，下一步就做：加一个白名单项目，从手机开一个真任务。
