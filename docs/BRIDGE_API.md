# 澜台 Bridge API

手机端与 Mac 端之间唯一的接缝。UI 与服务端可以并行开发，两边都只允许依赖这份文档。

范围包含**第一阶段（只读观察 + 待办读写）**、**第二阶段的控制通道**（`POST /api/commands` / `GET /api/commands/<id>`、能力标签、SSE `command` 事件、Codex 真实 driver）和**第三阶段的实时活动流**（SSE `activity` 事件、快照 `stream` 字段）。手机只能指挥澜台自己拉起的托管任务。

## 分层规矩（不得违反）

- Bridge 只依赖数据层（`CPTodoStore` / `CPAgentSources` / `CPStatusEngine` / `CPModels`）和驱动协议（`CPAgentControl`），**不得 import 任何 Controller**。
- UI 层**不得 import Bridge**。
- 手机端只认识本文档的协议，不认识任何一家 Agent 的私有协议。

## 传输与端口

- HTTP/1.1 + SSE，监听 `0.0.0.0:8787`（端口被占用时向上探测至 8797，实际端口写入 `NSUserDefaults` 键 `bridge.port.v1`）。
- 第一阶段仅明文 HTTP，仅限局域网与私有组网（Tailscale）。不做公网暴露，不自签 TLS。
- 所有响应 `Content-Type: application/json; charset=utf-8`，除静态资源与 SSE。
- 所有时间戳为 Unix 毫秒整数（`updatedAtMs`），不使用本地化字符串。

## 静态资源

- `GET /` 及 `GET /assets/*` 返回手机端 Web 应用，取自 App bundle 内 `Resources/mobile/`。
- 静态资源不需要鉴权（HTML/CSS/JS 本身不含用户数据）。

## 鉴权

除 `GET /api/health`、`POST /api/pair` 和静态资源外，所有请求必须带：

```
Authorization: Bearer <token>
```

token 无效或缺失返回 `401`，body 为 `{"error":"unauthorized"}`。

### 配对流程

1. Mac 端生成 6 位数字配对码，有效期 3 分钟，只在澜台界面/二维码里显示，**不写日志、不落盘明文**。
2. 二维码内容为 `http://<mac-lan-ip>:<port>/?code=<6位码>`。
3. 手机打开该地址，前端自动取 query 里的 `code` 调用配对接口。

```
POST /api/pair
{"code":"123456","deviceName":"iPhone"}

200 {"token":"<不透明随机串>","deviceId":"<uuid>","serverName":"澜台"}
403 {"error":"bad_code"}        配对码错误或已过期
429 {"error":"too_many_attempts"} 连续 5 次失败后锁定 10 分钟
```

- token 持久化在 Mac 端 Keychain，手机端存 `localStorage`。
- 已配对设备可在 Mac 上查看与撤销（撤销后该 token 立即 401）。
- 新配对设备默认 **不能** 下指令（`canControl = false`）。指挥权限必须由 Mac 端显式打开。

## 读接口

### GET /api/health

无需鉴权。用于手机端判断「电脑是否在线」。

```json
{"ok":true,"serverName":"澜台","appVersion":"0.4.0","protocol":1}
```

### GET /api/snapshot

一次性拿到手机首屏所需的全部数据。

```json
{
  "serverTimeMs": 1786634552751,
  "agents": [
    {
      "agentID": "codex",
      "name": "Codex",
      "health": "ok",
      "status": "working",
      "displayStatus": "working",
      "capabilities": ["observe"],
      "controlRoute": "none",
      "models": [
        {"modelID":"gpt-5.6-sol","name":"GPT-5.6-Sol","description":"Latest frontier agentic coding model.","isDefault":true}
      ],
      "tasks": [
        {
          "taskID": "019ffbb1-909f-74e0-820f-c1f526998c84",
          "title": "重构待办栏滚动逻辑",
          "projectName": "Codex Pulse",
          "sourceKind": "codex",
          "status": "working",
          "activity": "正在读取 CPWorkbenchController.m",
          "tokensUsed": 48213,
          "createdAtMs": 1786630000000,
          "updatedAtMs": 1786634500000,
          "reviewed": false,
          "managed": false,
          "stream": null
        }
      ]
    }
  ],
  "todos": [
    {"todoID":12,"title":"验证 app-server proxy 双写","completed":false,
     "agentID":null,"threadID":null,
     "createdAtMs":1786600000000,"updatedAtMs":1786600000000}
  ],
  "workdirs": [
    {"workdirID":"8f2c1a0e-3b7d-4c11-9a55-0d2e6b8c1f40","name":"澜台"}
  ]
}
```

字段约束：

- `status`：`working` / `waiting` / `attention` / `completed` / `failed` / `idle`，与 `CPStatus` 一一对应。
- `displayStatus`：`idle` / `working` / `completedPendingReview` / `waiting` / `failed`，与 `CPDisplayStatus` 对应，手机端据此决定涟漪周期。
- `health`：`ok` / `missing`。**`missing` 必须原样透出**，手机端显示「数据源不可用」，绝不允许退化成空任务列表。
- `capabilities`：至少含 `"observe"`。有健康 driver 时追加它自报的控制能力（`"control"` / `"interrupt"` / `"approve"` 等），顺序稳定、不重复。无 driver 或 driver 不健康时只有 `["observe"]`。手机端必须按能力标签渲染按钮，不得假设所有 Agent 都能指挥。
- `controlRoute`：指挥走哪条路。取值见下一节。
- `managed`：该任务是否为澜台托管、因而可被指挥。`false` 的任务在手机上只读。
- `stream`：实时活动流的当前尾部，只有 `managed == true` 时才是对象，否则为 `null` 或缺失。形状见「实时活动流」。
- `projectPath`、`rolloutPath` 等本地绝对路径**不得出现在任何响应中**，只给 `projectName`。
- `workdirs`：Mac 端项目白名单的对外投影，每项只有 `workdirID` 和 `name`，**绝不带 `path`**。手机用它渲染「在哪个项目里干活」的选择器，不能自己指定路径。列表为空表示用户还没在 Mac 上配置，此时 `start` 会失败。
- `models`（agent）：该 Agent 当前可见的模型目录，每项为 `modelID` / `name` / `description` / `isDefault`。来自官方 `model/list`，已去掉 `hidden == true` 的项。driver 不可用、不健康或目录拉不到时给 `[]`，此时手机不渲染模型选择器。`modelID` 不是路径也不是凭据，可以出现在给手机的 JSON 里。
- `tasks` 顺序即展示顺序，由 Mac 端排好（复用现有 `CPStatusTiePriority` 逻辑），手机端不重排。

### GET /api/events（SSE）

`Content-Type: text/event-stream`。心跳每 20 秒一次注释行 `:ping`。

浏览器 `EventSource` 不能设置自定义请求头，所以这条路径是鉴权例外：token 放在 query，而不是 `Authorization` 头。

```
GET /api/events?token=<token>
```

仍接受 `Authorization: Bearer <token>`（curl、原生客户端）。两种都没有或都无效则 `401 {"error":"unauthorized"}`。query token **只**对 `/api/events` 有效，其他接口继续只认 Authorization 头——这不是漏洞，是 EventSource 的限制。

事件类型：

```
event: snapshot
data: {与 /api/snapshot 完全同构}

event: todos
data: {"todos":[...]}

event: command
data: {"command":{与 GET /api/commands/<id> 同构}}

event: activity
data: {"agentID":"codex","taskID":"...","seq":130,"live":true,"entries":[...]}
```

第一阶段允许简单实现：数据签名变化时整包重推 `snapshot`，不做增量 diff。签名不变时不推。`command` 在指令状态每次变化时推一次。`activity` 见「实时活动流」。

## 待办写接口

写操作必须幂等：请求体带 `opID`（UUID），Mac 端记住最近 200 个 `opID`，重复请求返回首次结果而不重复执行。

```
POST /api/todos
{"opID":"<uuid>","title":"出门前把 Bridge 端口写进文档"}
200 {"todo":{...}}
400 {"error":"empty_title"}   标题去空白后为空

PATCH /api/todos/<id>
{"opID":"<uuid>","completed":true}
{"opID":"<uuid>","title":"新标题"}
200 {"todo":{...}}
404 {"error":"not_found"}

DELETE /api/todos/<id>
{"opID":"<uuid>"}
200 {"ok":true}
404 {"error":"not_found"}
```

约束：

- 手机与 Mac 工作台写的是**同一个** `CPTodoStore`，不允许第二份 SQLite。
- 写成功后必须向所有 SSE 连接推 `todos` 事件，Mac 端 UI 同步刷新。
- 本阶段不支持手机端设置 `agentID` / `threadID`，服务端收到则忽略。

## Agent 控制（第二阶段）

控制通道：手机按下按钮 → Mac 端校验、排队，再交给已注册的 `CPAgentControlDriver`。Codex 走澜台自己拉起的 `app-server`，不接桌面端已有会话。

**只有澜台托管任务可被指挥。** Codex Desktop 里已经打开的会话永远只读。澜台接不上桌面端已在跑的 app-server（见 `BACKLOG.md` 2026-08-15 实测结论），所以不能把桌面会话当成可写对象。

**手机开的任务在哪跑。** `start` 必须带 `workdirID`，且该 ID 必须落在 Mac 白名单 `control.workdirs.v1` 里。白名单由 Mac 菜单栏「手机指挥设置…」增删；手机只能从快照 `workdirs` 里挑，不能提交路径。解析后的绝对路径只存在于服务端的 `CPAgentCommand.workdir`，**任何给手机的 JSON（快照、POST 响应、GET 命令、SSE）都不含 `workdir` 或绝对路径**。

**审批当前是自动拒绝。** app-server 的 Exec / ApplyPatch / Permissions / ToolRequestUserInput 反向请求，澜台会立刻拒绝并附带「澜台暂不支持远程审批」（协议支持原因时）。手机端审批是第 5 步之后的事；现在不回复会把 turn 挂死。

**澜台退出会终止其托管任务。** 退出时杀掉自己拉起的 `app-server` 子进程。那些线程不再活着，托管集合也不持久化。桌面端已有会话不受影响。

手机端据此判断：

- `capabilities` 不含 `"control"`：不渲染指挥按钮。
- 任务 `managed != true`：该任务只读，即使 Agent 整体可指挥。
- `controlRoute` 区分指挥路径，不能把 `"native"` 和 `"relayed"` 画成同一种可靠性。

### 快照里的三个新字段

`capabilities`（agent）

- 无 driver，或 driver `isHealthy == NO`：`["observe"]`。
- 健康 driver：`["observe"]` 加上它自报的 `controlCapabilities`（例如 `control`、`interrupt`），去重且保持 driver 自报顺序。

`controlRoute`（agent）

- `native`：该 Agent 有健康的澜台 driver，指令由澜台直接执行。
- `relayed`：预留。通过 Codex 转达另一家（Kimi / Claude）。本阶段不会出现。
- `none`：没有健康 driver，只能观察。

`managed`（task）

- 该 agent 的 driver 对 `taskID` 调用 `isManagedTaskID:` 的结果。
- 无 driver 一律 `false`。
- `true` 才允许 `steer` / `interrupt`；`start` 不带 `taskID`，成功后由 driver 回填新的托管任务 id。

旧手机端不认识这些字段时会忽略，不影响第一阶段只读/待办。

### POST /api/commands

鉴权与待办写接口一致：只认 `Authorization: Bearer <token>`，不接受 query token。该设备还必须被授予指挥权限，否则 `403`。

```
POST /api/commands
{
  "opID": "<uuid>",
  "action": "start" | "steer" | "interrupt",
  "agentID": "codex",
  "taskID": "<thread id>",
  "workdirID": "<白名单 id>",
  "modelID": "<可选，仅 start>",
  "text": "..."
}
```

- `start`：省略 `taskID`；`text` 去空白后必填；`workdirID` 必填，且必须落在当前白名单。`modelID` 可选：缺失或去空白后为空则合法，不传给 Agent，继承 Mac 端 `~/.codex/config.toml`；非空则必须落在该 agent 快照的 `models` 里。
- `steer`：`taskID` 与 `text` 都必填；`workdirID` 与 `modelID` 忽略。
- `interrupt`：`taskID` 必填；`text`、`workdirID` 与 `modelID` 忽略。

成功立刻返回 202，状态为 `accepted`，不阻塞到 driver 跑完：

```
202 {"command":{"commandID":"...","state":"accepted","action":"start","agentID":"codex","taskID":null,"acceptedAtMs":0,"updatedAtMs":0}}
```

`commandID` 由服务端生成。`acceptedAtMs` / `updatedAtMs` 为 Unix 毫秒。`taskID` 在 `start` 刚接受时为 `null`，driver 成功后可回填。`errorMessage` **仅**在 `state == failed` 时出现。

错误码（按校验顺序，先命中先返回）：

```
401 {"error":"unauthorized"}             token 无效或缺失
403 {"error":"control_not_permitted"}    该设备未获授权指挥
400 {"error":"bad_action"}               action 不是三者之一
404 {"error":"agent_not_found"}          agentID 不在当前快照的 agents 里
503 {"error":"driver_unavailable"}       该 agent 无 driver，或 driver 不健康
400 {"error":"missing_task"}             steer / interrupt 缺 taskID
400 {"error":"empty_text"}               start / steer 的 text 去空白后为空
400 {"error":"missing_workdir"}          start 没带 workdirID
400 {"error":"unknown_workdir"}          workdirID 不在白名单里（含白名单为空）
400 {"error":"unknown_model"}            start 带了 modelID，但不在该 agent 的可见目录里
409 {"error":"not_managed"}              taskID 不是该 driver 的托管任务
409 {"error":"busy"}                     该 agent 已有一条命令在执行中（`interrupt` 不受此限，见下）
```

### GET /api/commands/\<commandID\>

```
200 {"command":{...}}
404 {"error":"not_found"}
```

需要有效 Bearer token。不要求 `canControl`（只读查询）。不接受 query token。

### 幂等、串行、状态机

- **幂等**：复用待办那套 `opID` 缓存（最近 200 条）。同一 `opID` 重发返回首次结果，不重复执行。`403` 发生在读 `opID` 之前，未获权时重试不会误拿到别人的成功结果；授权之后同一 `opID` 可以真正提交。
- **状态机**：`accepted` → `running` → `succeeded` 或 `failed`。POST 返回的是 `accepted` 快照；之后每次变化都能被 GET 读到，并向所有 SSE 连接推 `command`。
- **`succeeded` 的含义是「指令已被 Agent 接受」，不是「Agent 干完了活」。** driver 实现必须在 turn 被受理时就回调 completion，不能等到整个 turn 跑完——否则命令状态会和任务状态混为一谈，`busy` 也会把整段工作时间都锁住。任务本身跑到哪了，看 `tasks` 里的 `status`，不看命令状态。
- **串行**：同一个 `agentID` 同时只允许一条命令处于 `accepted` 或 `running`，第二条返回 `409 busy`。不同 agent 互不阻塞。
- **`interrupt` 是急停，不受串行闸门约束**，也不占用该 agent 的在飞槽位。理由：被 `busy` 挡住的恰好是最需要打断的情况（一条 `start` 正跑着）。允许多条 `interrupt` 同时在飞，重复打断无害。
- **记录**：保留最近 100 条命令供 GET 查询，按接受时间淘汰最旧的已结束记录。

### 设备指挥权限

`CPBridgeDevice.canControl` 默认 `false`。新配对不能下指令。开关随设备信息一起持久化；旧记录缺该字段视为 `false`。token 仍只存在 Keychain，不写进普通文件。

Mac 端入口在菜单栏「手机指挥设置…」：按设备打开「允许指挥」，并增删项目白名单（`control.workdirs.v1`）。新配对默认仍是 `canControl = false`，白名单为空时 `start` 返回 `unknown_workdir`。变更后 Bridge 会主动重推快照，手机端能立刻看到 `workdirs`。

真实 Codex driver 已接入。没有注册健康 driver 时，快照里 `capabilities` 仍是 `["observe"]`，`controlRoute` 为 `none`，POST 返回 `503 driver_unavailable`。

## 实时活动流（第三阶段）

没有这一步之前，手机要等 `~/.codex/sessions` 落盘才看到结果，有秒级滞后且看不到过程。这一步把 `codex app-server` 的实时通知接进来。

`codex app-server` 一共发 70 种通知，**不允许原样转发给手机**。手机可能在蜂窝网上，逐字通知一秒能来几十条。driver 负责把它们折叠成下面七种，Bridge 负责限流、截断和补抓。

### 七种 kind

| kind | 来源通知 | 手机上显示成 |
| --- | --- | --- |
| `say` | `item/agentMessage/delta` | Codex 说的话 |
| `think` | `item/reasoning/summaryTextDelta`、`item/reasoning/textDelta` | 它在想什么 |
| `run` | `item/commandExecution/outputDelta` | 跑了哪条命令、输出尾部 |
| `edit` | `item/fileChange/patchUpdated`、`turn/diff/updated` | 动了哪些文件 |
| `plan` | `turn/plan/updated`、`item/plan/delta` | 它列的步骤 |
| `usage` | `thread/tokenUsage/updated` | token 用量 |
| `note` | `error`、`warning`、`guardianWarning` 等 | 警告与错误 |

其余通知（账号、MCP、realtime 语音、fuzzy search、Windows 相关等）一律安静丢弃，不占 `seq`。

`item/started` 也不产生条目、不占 `seq`，只用来记住命令行，好让后续 `run` 的 `text` 是「跑了哪条命令」。

两处已知空缺，先记下来不遮掩：

- `command/exec/outputDelta` 曾被列为 `run` 的来源，实际不可用：它的 params 只有 `capReached` / `deltaBase64` / `processId` / `stream`，没有 `threadId`，归不到任务上；而 `processId` 是客户端发 `command/exec` 时自带的连接级 id，澜台从不发这个请求。已从表里移除。
- **没有输出的命令不留痕迹。** `run` 只由 outputDelta 触发，所以 `rm x` 这种静默命令跑完了，手机上一条 `run` 都看不到。要补就得允许 `item/started` 产生条目，那会改 `seq` 语义，属于改契约，留到下一阶段再议。

### 条目形状

```json
{"seq":128,"kind":"run","text":"rg -n workdirID","detail":"12 matches","atMs":1786634552751}
```

- `seq`：该任务内单调递增，从 1 开始，不复用、不回退。
- `text`：一行标题，已脱敏，**上限 400 字符**。超长保留**头部**，尾巴加 `…`——标题的价值在开头。
- `detail`：可选正文（命令输出尾部、补丁摘要），**上限 2000 字符**。超长保留**尾部**，前面用 `…` 标记——命令输出的价值在末尾。
- `edit` 的 `detail` 是文件清单（`~ 澜台/Sources/x.m (+12 -3)`），不是原始补丁。几千行 diff 砍成尾部 2000 字给手机看没有意义。
- `atMs`：Unix 毫秒。

### 服务端的限流义务（不是建议）

- **同 kind 的连续 delta 必须合并成一条**，追加到 `text` 或 `detail`，不允许一个 token 发一条。
- 每个任务**最多每 250ms 推一次**。kind 变化或 item 结束时立即**冲刷**——冲刷指把手里那条合并中的条目定稿、分配 `seq`，让顺序如实；发帧仍受 250ms 闸门管，不是立刻发。唯一例外是 `live` 翻转，那是状态变化不是吞吐，立刻推。
- 快照式通知（`turn/plan/updated`、`turn/diff/updated`、`thread/tokenUsage/updated`、`item/fileChange/patchUpdated`）每次都是全量，**后者覆盖前者**，不能追加，否则会得到「计划A计划B」。`error` / `warning` 一律各自成条，不合并，免得两条不同告警被拼成一句。
- 每任务只留**最近 40 条**，只跟踪**最近 10 个托管任务**，超出淘汰最旧。
- 只有 `managed == true` 的任务有流。桌面端会话不是澜台拉起的，没有流，手机继续看落盘的 `activity` 字段。

### 路径脱敏（硬规矩）

命令行和文件名天然带绝对路径（`rg -n foo /Users/alice/Documents/…`），而本文档禁止绝对路径出给手机。折叠时必须：

1. 把该任务 workdir 的路径前缀换成项目名（`/Users/alice/Developer/lantai/Sources/x.m` → `澜台/Sources/x.m`）。
2. 剩下的 `/Users/<用户名>` 一律换成 `~`。

driver 折叠时做一遍，Bridge 推送前再兜一遍。两层都做是故意的：这条一旦漏，泄的是用户的真实目录结构。

### SSE 增量与补抓

```
event: activity
data: {"agentID":"codex","taskID":"...","seq":130,"live":true,"entries":[{…},{…}]}
```

`seq` 是本批**最后一条**的 seq。手机据此判断有没有漏：

- 期望 `上次见到的 seq + entries.length == 本次 seq`。
- 不相等说明中间断过（息屏、切后台、弱网）。此时**不要自己拼**，重新拉 `/api/snapshot` 整包对齐。
- 手机还没有任何基线时，`上次见到的 seq` 取 0。于是中途加入必然对不上，走一次快照对齐——这是设计如此，不是 bug。
- 同理，SSE 重连后服务端若重放了最后一批，按上式必定判成漏批并拉一次快照。正确后果，别指望重放是免费的。

**空批次是合法的，且必须不占 `seq`。** 只翻转 `live` 标志时没有新内容，服务端发 `entries: []` 并沿用当前尾部的 `seq`，这样上式自动成立（`上次 seq + 0 == 本次 seq`）。要是给降级通知配一个 +1 的 seq，手机每次断开都会误判漏批、白拉一次整包快照。

快照里每个托管任务多一个 `stream`，用于首屏和补抓：

```json
"stream": {"seq":130,"live":true,"entries":[ …最近 40 条… ]}
```

非托管任务没有 `stream` 字段。

托管任务也可能**没有** `stream` 字段：还没产生任何输出，或者被「只跟踪最近 10 个」挤了出去。这种情况下字段是**缺失**，不是空对象——空对象会让手机以为「实时流是空的」，缺失才让它退回落盘的 `activity`。手机遇到「`managed == true` 但没有 `stream`」时**不要清屏**，改标断开即可；只有 `managed != true` 才真的丢掉本地流。

### live 的含义

`live: false` 表示澜台的 app-server 不在了（进程挂了、协议对不上、driver 不健康）。此时手机**必须明确显示降级**，例如「实时输出已断开，下面是落盘后的结果」，**不允许显示成空白**——空白会让人以为 Agent 什么都没干。已经收到的条目要留在屏幕上，不要清掉。

## 明确不在本阶段

- 审批回调（app-server 的 Exec / ApplyPatch / Permissions / ToolRequestUserInput）。
- Mac 离线时手机排队写入。手机必须显示「最后同步时间」，不伪造成功。
- 中心服务器 / Relay / 端到端加密。
