# 澜台 / Lantai 后续事项

记录日期：2026-08-12。命名与路线于 2026-08-13 更新；手机第一阶段、待办升级范围、UI 可变性于 2026-08-14 更新。除「已落地」标注的条目外，其余仅作为后续设计与优化清单。

所有计划、决策、规格都只写在 `docs/` 里，索引见 [README.md](README.md)。不要在根目录再放一份计划。

## 下一轮开工顺序（2026-08-14 夜定）

用户当天收工，下一轮按这个顺序。四象限的交互已经定了（四格缩略 + 点选放大），所以原先「先纯设计、不写代码」那一步已经做完。

1. **把本机未入库的第一阶段提交进 git。** Bridge、手机 PWA、配对卡目前只在用户 Mac 的工作区里，这个仓库的 `main` 还没有那些文件。不先入库，后面所有手机/待办改动都会和那批 diff 缠在一起。
2. **补免费那档 PWA**：`manifest.json` + 一套图标 + 「添加到主屏幕」引导。半小时的事，做完手机上就是独立 App 图标，不需要 HTTPS。
3. **待办升级**：四象限（四格缩略 + 点选放大）+ 截止时间 + 拖拽排序 + 个人/Agent 分区 + 已完成归档。新界面按 [UI_ARCHITECTURE.md](UI_ARCHITECTURE.md) 的三条规矩写，不进 `CPWorkbenchController.m`。
4. **2A：撞 `codex app-server` 那个风险点**，把实时事件流打通。一行控制命令都不发。
5. 之后才是 2B 指挥、2C 审批、Tailscale/HTTPS。

## 版本路线（整体）

- **v0.3（已完成）** Mac 版稳定化：`main.m` 模块化、SPM 骨架、XCTest 迁移、Codex 数据源 glob 探测与健康度、多显示器统一。
- **v0.4（进行中）** 命名与涟漪设计语言。命名已落地；运行时涟漪已按定稿写入 `CPRippleView`。还剩身份件：菜单栏同心弧、Logo、空状态、详情页返回入口。
- **v0.5** 接入更多 GUI Agent。
- **v0.6** 首次公开（Alpha）：许可证、README 风险说明、不含真实截图。身份件和打码截图可以在公开之后补，不必挡第一次上传。
- **v0.7** 待办升级：四象限、截止时间、拖拽排序、个人/Agent 分区、已完成归档。范围已定，下一轮做。
- **v0.8（本机已落地，未入库）** 澜台 Bridge + 手机 Web/PWA 第一阶段：只读观察 + 待办读写 + 扫码配对。2026-08-14 真机配对成功。代码还在本机工作区，没有进这个 git 仓库。
- **v0.9** 手机指挥 Agent：先读侧事件流（2A），再三个写动作（2B），再审批（2C）。

必须串行的一处：涟漪身份件（图标、Logo）要在皮肤之前做完，否则色板会围着一套即将废弃的符号去定。原先「开源必须排在接入更多 Agent 之后」已取消——第一次公开按当前 Alpha 能力写清楚限制即可，能力清单随适配器再改 README。

## 命名（已落地）

产品定名**澜台**，英文 **Lantai**。澜取涟漪，台取观察台，正好对应「用涟漪表达状态的本地 Agent 观察台」。

完整的候选清单、每个名字的排除理由和检索证据见 [NAMING.md](NAMING.md)。简述：Buoy、Pond、Sonar、Ripple、Crest、Tarn、观澜、Lagoon 八个候选全部已被占用，其中四个直接撞在 AI Agent 工具这一小块上；听澜、静池、枕流、漪台查过无同名但因词义或读音落选。

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

完整规格、实验室三条路线的取舍、以及身份件怎么做，见 [DESIGN.md](DESIGN.md)。下面只列待办。

**已落地（不要重开三条路线）：** HUD 选中态与悬浮球的运行时涟漪，`CPRippleView`，8 层明暗成对、基准 12s、状态只改周期。定稿原型是 `ripple-selection-preview.html`。`ripple-style-lab.html` 是实验室。`multitask-status-prototype.html` 已否决。

**还没做的身份件：**

- 菜单栏不要再按状态换 SF Symbol（现在是 `sparkles` / `pause.fill` / `moon.zzz.fill` 等）。改成**同一套**同心弧模板图标，用 tint 表示状态。16pt / 32pt，浅色与深色菜单栏分别验。菜单栏不开动画。
- Logo 与悬浮球中心、工作台标题旁、快捷栏「工作台」按钮，停用 `waveform.path.ecg`。静止同心弧，和 `CPRippleView` 同一套几何。
- 应用图标 1024（Finder / 关于 / GitHub 用）。App 是 `LSUIElement`，不占 Dock，但公开仓库需要能看见的图标。
- 「暂无活动任务」画静止水面；「数据源不可用」保持文字，不要画成空水面。

边界：涟漪不铺到任务卡、待办行、按钮、返回入口。速度绑运行状态，颜色绑状态语义，两者都不随皮肤变。

## 皮肤与主题（后续）

可行，但只做「换色」，不做「整套换皮」。现状已经有一层颜色入口（`CPAccent` / `CPBg` / `CPSurface` / 状态色），数值仍写死在 `CPDyn` 里；部分 `CALayer.CGColor` 是快照，换肤时要重新赋值，否则灯和描边会留在旧色上。

成本已实测量化，见 [UI_ARCHITECTURE.md](UI_ARCHITECTURE.md)：换色便宜（12 个函数覆盖 142 个调用点），运行时切换要处理 65 处 `CGColor` 快照，换密度要先收拢 116 个约束字面量 + 23 个圆角 + 19 个字号。那份文档还定死了一条边界——**皮肤不许承载交互变化**，否则皮肤配置会长成万能开关。

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

2026-08-14 看过 DeepSeek Harness 的「一切皆插件」之后的补充定案：澜台**不做成插件平台**。Harness 那套是给「会来换零件的开发者」付税的；澜台要的是「以后我能换零件」。两者不是一回事。皮肤继续只换色；换 UI = 新视图文件对同一数据层。完整对照见 [UI_ARCHITECTURE.md](UI_ARCHITECTURE.md) 最后一节。

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

- 走 [AGENT_ADAPTERS.md](AGENT_ADAPTERS.md) 已定义的适配器边界，只读，不改写对方数据。
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

- ~~界面是固定分为“个人待办 / Agent 待办”，还是保持一个列表并以来源筛选、标签或自动分组呈现~~ → 已定：分区复用已有 `agent_id`（非空即 Agent 待办），界面上分开。
- Agent 根据对话总结时，首版只生成标题，还是同时生成说明/下一步；哪些字段应该在 Todo 栏直接展示。
- 用户明确发出“转为待办”指令时是直接创建，还是先让 Agent 回显摘要并等待一次确认。
- 是否允许 Agent 主动提议待办，如果允许，建议项的数量上限、展示位置和拒绝后的降噪规则如何设置。

### 待办升级（已选定范围，2026-08-14 用户确认）

要做：**截止时间 + 到期提醒、四象限、拖拽排序、个人/Agent 分区、已完成归档**。备注/子项这次不做。

`CPTodoStore` 已有 `PRAGMA user_version` 的 switch 式迁移框架（当前 v1），加字段是 v1→v2 一个 case 的事，成本低。已有真实待办在库里，迁移必须就地升级而不是重建表。

#### 交互：四格常在 + 就地放大/再点缩回（已定，2026-08-14）

用户参考了一套手机设计的交互逻辑，**只取交互，不取视觉**——配色一律按澜台的深石墨走，不做白底大留白那套。

逻辑是一个开关，不是翻页：常态四格同时在场、各自显示条目；点一格就地胀大、其余缩成窄条；再点一次缩回；点条目即完成。放大态只干一件事——录入，默认焦点在输入框，不堆筛选和排序。

完整规格（含手机端表现）见 [`design-systems/lantai/DESIGN.md`](../design-systems/lantai/DESIGN.md) 的四象限一节。

**位置是通行约定**，重要在上排、紧急在左列，从左上往右下读即优先级顺序。用户给的参考图是举例，不作为依据。

**叫法待拍板。** ~~`现在做` / `早点做` / `顺手做` / `先放着`~~ 已弃用（准确但没味道，和「澜」不搭）。候选一是全套水象 `急流` / `深潭` / `浅滩` / `静水`，候选二是轴字直拼 `急重` / `徐重` / `急轻` / `徐轻`。任一套的硬条件：网格边缘标出两条轴、每格带一行说明，诗意名字只能是结构之上的装饰。

#### 尚未拍板：展开高度要不要加大

现在的 `CPTodoExpandedExtra = 210` 是当初为「5 行线性列表」定的，换算下来四象限每格只有约 66 高、**两行**。用户要求「常态四格的待办都看得见」，与这个高度冲突。三条路：A 守住 158（每格两行，看全靠放大，零返工）；B 加大到约 300（每格三行，代价是工作台几何自测要跟着返工）；C 四象限单独更大的视图（最灵活，多一个视图要维护）。

原型先按 A 画：A 是下界，A 里读得通，B/C 必然读得通，反之不成立。**这是尺寸决策，一旦按某个宽高把布局细节排完就会锁死**（见 [UI_ARCHITECTURE.md](UI_ARCHITECTURE.md)），所以要在写 AppKit 之前定。

#### 字段草案（v1→v2，一次迁移做完）

- `due_at REAL NULL`：截止时间。到期提醒的触发在 Mac 端算，不依赖手机在线。
- `urgent INTEGER NULL` / `important INTEGER NULL`：四象限是这两个布尔的组合，不要存 `quadrant` 枚举。拖到另一个象限只是改一个布尔；以后想单独按重要性筛选也不用再迁移。
  - ~~`NOT NULL DEFAULT 0`~~ → 改为**可空**。空 = 还没判断轻重，**不等于**「不重要不紧急」。理由见下面「待分类」，这是留 Agent 口子逼出来的。
- `sort_order REAL NOT NULL`：拖拽排序。用浮点而不是整数，插入两行之间取中间值即可，不必重排整列。排序作用域是「同一象限 + 同一分区内」，跨象限拖拽等于改象限。
- `archived_at REAL NULL`：归档是软状态，不是删除；`allTodos` 默认不返回已归档。
- `source TEXT NOT NULL DEFAULT 'user'`：`user` / `agent` / `api`。界面据此显示来源标记，也用于「Agent 建议的只进待分类」这条规则。
- 分区复用已有的 `agent_id`：非空即 Agent 待办。不新增分区字段。

迁移后必须跑一次自测，确认旧数据的 `sort_order` 有确定值（按现有 `created_at` 升序回填），否则排序会是随机的；并确认旧数据的 `urgent` / `important` 是 NULL 而不是 0，否则存量待办会一次性涌进「先放着」。

#### 待分类：Agent 口子逼出来的第五块

用户要求为「以后一句话就能让 Codex / 手机上的 ChatGPT / 某个 API 帮我建待办」留口子。这个口子有一个必须先解决的连带后果：

**Agent 通常不该替你判断轻重缓急。** 如果 `urgent` / `important` 默认 `0`，Agent 建的每一条都会静静掉进「先放着」——四格里你最少看的那格。口子建好了，进来的东西自动被藏起来，等于没建。

所以定案：

- 两个布尔可空；空 = 待分类。
- 总览顶部一条窄横条 `待分类 N`，点开逐条指派到某格。Mac 的 158 高里给它约 20。
- 这条横条同时服务人：随手记一句、还没想清轻重，也进这里。
- Agent **主动建议**的只进待分类；用户**明确要求**建的可以带格子直接落。这条与上文「从 Agent 会话创建待办」里「建议不默认注入」是同一条规则的落地。

#### 口子本身：大半已经建好了

不需要为 Agent 联动新造一套管道，现有的三样东西已经是那个口子：

1. **唯一写入路径。** 手机、Mac 界面、Agent 一律走同一套 Todo 写入接口（这条规矩上文已有）。Bridge 的 `POST /api/todos` 已经带 opID 幂等，Agent 重试不会建出两条。
2. **来源字段。** `source` + 已预留的 `agent_id` / `thread_id`，够界面显示来源并回跳原会话。
3. **待分类作为收件箱。** 让「谁都能塞进来」不等于「界面被塞乱」。

还差的只有：Mac 上给本机 Agent 用的受限入口（`todo.create`，只许本机已授权调用），以及在 Codex 侧以 Skill / MCP 工具的形式把它暴露出去。这两件事排在待办升级之后、不与四象限抢同一批 diff。

**不做的：** 不让澜台去猜自然语言（「他刚才是不是想建个待办」）。必须是 Agent 识别意图后显式调用结构化接口。猜的那条路会在你不想要的时候造出待办，比不做更糟。

#### 截止时间 ≠ 到期提醒

HTTPS 没通之前，提醒只能是 Mac 端本地通知 + 手机打开时看到；通了之后才能锁屏推送。所以「截止时间」和「提醒」是两步，可以先做前者。

硬规矩：Mac 与手机共用同一套写入接口和字段，不允许手机端自己加字段。加字段时同步 `BRIDGE_API.md`（待那份文件入库），否则两边必然漂移。

## 代码债与模块边界（2026-08-13 体检，2026-08-14 补数字）

现状不是屎山：总量约 8500 行，数据层（`CPModels` / `CPTodoStore` / `CPAgentSources` / `CPStatusEngine` / `CPStateCache`）不依赖任何 UI 控制器，依赖方向干净。已知的债集中在 UI 层。改 UI 各层的实际成本已经量化，见 [UI_ARCHITECTURE.md](UI_ARCHITECTURE.md)，这里只记账，不要求现在偿还：

- `CPWorkbenchController.m` 1712 行；头文件暴露 52 个属性，是最接近 god object 的地方。**行数和属性数都不许再涨。**
- `CPSelfTests.m` 2607 行单文件。
- `CPHUDController` import 了 `CPWorkbenchController`（UI 咬 UI 的唯一一处）。
- 密度字面量：约束 116、圆角 23、字号 19。`CGColor` 快照 65 处。绕过调色板直写颜色 7 处。

新增手机/Bridge/待办四象限代码时的三条硬规矩（防止债扩散）：

1. Bridge 和 Agent driver 永远不 import 任何 Controller；UI 永远不 import Bridge。两边只依赖数据层。
2. 手机端只认识澜台 Bridge 自己的协议；各家 Agent 的协议细节藏在 driver 后面，对外只暴露能力标签（可指挥 / 只可观察 / 可打断 / 可审批）。
3. 每个 driver 自带健康度（复用 `CPAgentHealth` 语义），协议对不上就明确降级只读，不静默出错。

新界面额外三条（从四象限这一版开始执行，详见 [UI_ARCHITECTURE.md](UI_ARCHITECTURE.md)）：

1. 新界面不进 `CPWorkbenchController.m`，各自成文件。
2. 新界面不许出现新的密度字面量，走 token（表还没有就先在自己文件顶部定命名常量）。
3. 新界面的自测只钉行为，不钉像素。

现在不要重构那个 1712 行的类。在不知道未来界面长什么样的时候拆，是凭想象划边界。正确时机是真的开始改布局那一次。

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
- 待实测的第一个真问题：桌面端已有一个 app-server 在跑，澜台自起一个是双写；控制桌面端活跃会话应验证 `app-server proxy --sock` 接同一 daemon 的路子。这是整条指挥路线唯一的真风险，必须先撞。

多 Agent 控制的定调（2026-08-13）：原生控制协议只有 Codex 一家全套，Claude Code（Agent SDK / stream-json）次之，Kimi App GUI 无。首版只做 Codex driver；其他家走「Codex 编排 CLI + 澜台原生只读观察」（本机已装 Kimi CLI 与 Claude Code CLI，Codex 驱动 Kimi CLI 的模式已有 kimi-cli-supervisor skill 实践）。代价记录在案：观察被压扁成命令输出、双份 token、打断粒度粗。UI 上「通过 Codex 转达」与「原生指挥」必须分开标注。

### 第一阶段已落地（2026-08-14，代码尚未入库）

只读观察 + 待办读写这一刀在用户本机已经可用，真机扫码配对成功。契约见 `BRIDGE_API.md`（随那批代码一起进仓库，目前还不在这个 git 副本里）：

- `Sources/CodexPulseBridge/`：自写 HTTP + SSE（BSD socket + 独立 accept 队列），配对码 / token / 设备管理独立成 `CPBridgePairing`，token 存 Keychain。
- 手机端 `Resources/mobile/`：无依赖 PWA，色板与涟漪规格直接取自 Mac 端 `CPStatusEngine` 与 `CPRippleView`；`?demo=1` 显式演示态，真实模式连不上只显示离线，不拿假数据兜底。
- 入口：工作台标题栏 iPhone 图标按钮 + 菜单栏「连接手机…」双入口。原打算只放菜单栏（配对是一次性动作，不该占标题栏），实测失败——菜单栏图标多时被系统折叠，用户找不到。**找不到的入口等于不存在。** 工作台按钮只发 `CPConnectPhone` 通知，不 import Bridge。
- `CPPairingSheetController` 显示二维码 + 六位码 + 倒计时，Bridge 未启动时明说而不画空码。
- 二维码走 CoreImage `CIQRCodeGenerator`，按整数倍放大后原尺寸显示；自测用 `CIDetector` 回读断言扫得出且内容一致。
- 配对成功自动关卡片：Bridge 发 `CPBridgeDevicePairedNotification`（只带设备名，token/deviceId 不出 Bridge），卡片显示「<设备> 已连接」并撤掉已失效的码，1.4s 后关闭；自测态不排延迟，直接断言确认态。
- 分层守住：Bridge 不 import 任何 Controller，UI 不 import Bridge，手机端只认澜台协议。
- 自测：`Bridge self-test` 14 项（含鉴权、幂等 opID、锁定、路径脱敏、SSE、SO_SNDTIMEO），`Pairing UI self-test` 含 `paired-state`。

审阅修掉的三处（记账，避免重犯）：

- SSE 鉴权原本只认 Authorization 头，而浏览器 `EventSource` 无法设自定义头，实时推送必然 401。现仅 `/api/events` 额外接受 query token。
- `activity` / `title` 会把家目录绝对路径带给手机。现在 Bridge 输出层统一脱敏为 `~`，不改 CPTask 与 Mac 端显示。
- SSE 阻塞写跑在状态队列上且未设 `SO_SNDTIMEO`，手机断网可致整个 Bridge 假死。现已设写超时并在失败时清理客户端。

另记一处产品级坑：澜台是单实例应用。旧实例还在跑时，新构建的功能（菜单项、按钮）全部看不见。`main.m` 已加提示：「若刚更新过却看不到新功能，请先退出再打开」。以后凡是「我明明加了怎么没有」先查是不是旧进程。

尚未入库：上述全部代码仍在用户 Mac 工作区。这个仓库的 `main` 没有 `Sources/CodexPulseBridge/`、`Resources/mobile/`、`CPPairingSheetController`。下一轮第一件事就是提交它们。

尚未做：手机端指挥 Agent（第二阶段）、异地访问（Tailscale，未实测）、装成主屏 App、推送。

### 指挥路线：先看得准，再能指挥（2026-08-14 定序）

顺序是 **2A → 2B → 2C**。理由：指挥的价值取决于能不能实时看到指挥的后果，事件流没通就发命令，等于闭着眼开车。

#### 2A. 让手机看到「正在发生」（读侧）

现在手机看到的是 `~/.codex/sessions` 落盘后的结果，秒级滞后且没有过程。这一步把 `codex app-server` 的实时通知接进来，仍然一行控制命令都不发。

- 新增 `Sources/CodexPulseAgents/CPCodexDriver`：启动/接上 app-server，跑 JSON-RPC，把 70 类服务端通知折叠成澜台自己的少数几种事件（逐字输出、命令输出、diff、计划、token 用量、等待审批）。
- 开工第一件事是验证 `app-server proxy --sock` 能否接桌面端已在跑的那个 daemon。接不上就只能自起进程，那意味着「只能观察澜台自己启的会话」，产品形态要跟着改。
- 启动时用 `generate-json-schema` 自检协议；认不出就整体降级只读，走 `CPAgentHealth` 的「数据源不可用」显示，不静默出错。
- Bridge 侧只加事件类型，不加控制端点；`BRIDGE_API.md` 同步扩事件表。
- 完成判据：手机上能逐字看到 Codex 正在写的内容，且拔掉 app-server 后手机明确显示降级而不是空白。

#### 2B. 手机能指挥（写侧，只做安全的三个动作）

- 只开三个：`turn/start`（发新指令）、`turn/steer`（补充指令）、`turn/interrupt`（打断）。`thread/rollback` 这类会改历史的先不开。
- 一切写操作走 Mac 端指令队列：验设备权限 → 验任务归属 → 验当前状态，再执行，回传已接收/执行中/成功/失败。opID 幂等复用第一阶段那套。
- 只允许指挥「澜台托管任务」。桌面端已有会话保持只读，除非 2A 证明能接同一 daemon。
- UI 必须区分「原生指挥」与「通过 Codex 转达」（Kimi/Claude 走 CLI 编排那条），不能让用户以为两者可靠性一样。

#### 2C. 审批（真正把手机变成遥控器的那一步）

app-server 的四类反向请求（Exec / ApplyPatch / Permissions / ToolRequestUserInput）天然对应手机上的同意/拒绝。做到这里，「人在外面，Agent 卡在等确认」才算解决。审批请求有超时，手机端要显示剩余时间，过期要如实说明是超时而不是拒绝。

### 装成 iPhone App（PWA，2026-08-14 查证）

结论：**能装成看起来完全像原生 App 的东西（全屏、自己的图标、独立进程），但要拿到推送和角标，必须先解决 HTTPS。**

现状（`Resources/mobile/`，本机已有、未入库）：已有 `apple-mobile-web-app-capable` 等 meta，加到主屏就能全屏无地址栏运行；但没有 manifest、没有图标、没有 service worker。

分成两档，成本差很远：

- **免费的一档（不需要 HTTPS，下一轮做）**：补 `manifest.json`（`display: standalone`、图标、`theme_color`、`start_url`）+ 一套 App 图标 + 手机端一句「点分享 → 添加到主屏幕」的引导。iOS 没有 `beforeinstallprompt`，也没有任何 API 能唤起分享面板，装不装只能靠引导文案。做完就有独立图标、全屏、独立进程。iOS 对主屏 Web App 的存储不套用 Safari 那个 7 天清理，token 不会莫名失效。
- **要 HTTPS 的一档（推送 + 图标角标）**：`navigator.setAppBadge()` 和 Web Push 都只在「已加到主屏的 Web App」里存在，且 **service worker 与 Push 强制要求 HTTPS，iOS 连 localhost 都不豁免**。现在是 `http://192.168.x.x:8787`，这一档一行代码都不通。

HTTPS 两条路，建议选第一条：

1. **Tailscale + `tailscale serve`**：拿到 `*.ts.net` 的真证书，顺带把「异地访问」一起解决。代价是 Mac 和手机都要装 Tailscale。
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
- ~~手机首版是 PWA，还是直接开发 SwiftUI iOS 客户端~~ → 已定 PWA 并在本机落地；加主屏后即为独立全屏 App，暂无换原生的理由。
- 异地访问是否接受用户安装 Tailscale，以及什么阶段引入澜台 Relay。倾向接受：Tailscale 同时解决 HTTPS（`*.ts.net` 真证书），是通往推送与图标角标的唯一低摩擦路径。
- Todo 是否要支持 Mac 离线时在手机修改；若需要，优先选 CloudKit 还是跨平台 Relay/CRDT。
- “已审阅”是账号级状态还是每设备状态，是否与现有“已查看/已处理”语义一起重新设计。
- ~~待办四象限放在哪（工作台内独立视图 / 另开窗口 / 只在手机做）~~ → 已定：就在现有待办栏里，四格缩略 + 点选放大。

## 本轮记下的经验（2026-08-14）

这些不是计划，是踩过之后不能再忘的东西。改 UI 的量化分析在 [UI_ARCHITECTURE.md](UI_ARCHITECTURE.md)，这里只记产品与工程上的教训。

- **找不到的入口等于不存在。** 配对入口原放菜单栏，图标一多就被系统折叠，用户反复说看不到。后来加到工作台标题栏才解决。以后凡是一次性、低频的动作，也必须在用户正在看的那个面上有入口。
- **单实例会把新功能藏起来。** 旧进程还在跑，新构建的按钮和菜单项全部看不见。表现为「你说加了但没有」。先退出再打开；启动时若已有实例，要明说而不是默默退出。
- **功能落了 UI 还能改，但尺寸会锁死。** 数据层加字段和界面长什么样是解耦的。真正会锁死的是硬编码尺寸（`CPCardWidth 520` 等）和钉像素的自测。所以新界面只钉行为。
- **皮肤不是换 UI。** 用皮肤机制承载交互变化，配置会长成万能开关。判断标准：切换后如果自测要换一套，它就不是皮肤。
- **现在不要拆那个 1712 行的类。** 在不知道未来界面长什么样的时候拆，是凭想象划边界。现在只加防线：新界面不往里塞。
- **密度 token 是唯一现在就值得花的钱。** 换色已经集中；换布局要等真改的那天。圆角/间距/字号现在每加一个界面就多几十个字面量，债线性增长。
- **指挥之前先把「正在发生」看清。** 事件流没通就发命令，等于闭着眼开车。2A 必须先于 2B。
- **iPhone Web App 分两档。** 全屏独立图标不需要 HTTPS；推送和角标硬性要求 HTTPS，iOS 连 localhost 都不豁免。不要把两档写成一件事。
- **浏览器 `EventSource` 不能设自定义头。** SSE 鉴权只能额外走 query token，且仅限那一个端点。
- **路径脱敏在输出层做。** 不要改 `CPTask` 本身，否则 Mac 端显示也被改掉。
- **SSE 写必须有超时。** 没 `SO_SNDTIMEO` 时手机断网能把整个 Bridge 卡住。
- **配对成功通知不许带凭据。** 通知会流到 UI 层，只许带设备名。
- **计划只放 `docs/`。** 同一件事写进两个文件，一定有一份先过期。推翻旧决定时划掉留在原处，不要直接删。
- **数字要能重跑。** 「约 160 个字面量」这类结论必须附命令，否则三个月后没人知道它还成不成立。
- **「一切皆插件」是检查题，不是实现。** DeepSeek Harness 需要插件内核，因为它的用户就是来换零件的。澜台的用户不是。过早做通用插槽，插槽会变成新的 god object。每加一块只问：以后换掉它，是改一处接缝，还是翻三个文件。

自动关闭配对卡只验到自测那一层（确认态显示对、失效的码撤掉了）。从手机真扫一次到卡片自己关上的完整链路，还要人工点一次才算数。

## 性能

- 分析两秒刷新、SQLite 查询、rollout 文件尾部读取、AppKit 重建视图及涟漪动画的开销。
- 优先采用增量刷新和缓存，减少无变化时的数据库、文件读取和视图重建。
- 增加空闲、任务运行中、HUD 展开时的 CPU/内存基准，优化后做前后对比。

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
