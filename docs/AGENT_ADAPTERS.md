# Agent 适配器

Codex Pulse 把“应用内启用 Agent”和“实现一种 Agent 数据源”分开。普通用户只需在工作台点击“添加 Agent”；适配器作者负责把提供方的本地数据归一成 `CPAgent` 和 `CPTask`。

## 用户流程

1. 打开工作台，点击“添加 Agent”。
2. 应用显示尚未启用的内置提供方，并标记“已检测/未检测”。
3. 用户确认后，提供方 ID 写入 `agents.enabledProviders.v1` 用户偏好。
4. 数据读取器立即重建，新 Agent 无需重启就出现在工作台。
5. 未安装或暂无任务的提供方保持真实空态，不注入演示数据。

## 内置数据源

| Provider ID | 界面名称 | 主数据源 | 默认 |
| --- | --- | --- | --- |
| `codex` | Codex | `~/.codex/state_5.sqlite` 与 `logs_2.sqlite` | 启用 |
| `kimi` | Kimi | Kimi App `hosted-logical/conversations.sqlite`、`conversation-statuses.json` 和对应 `wire.jsonl` | 启用 |
| `kimi-cli` | Kimi CLI | `~/.kimi-code/sessions/*/state.json` 和 `agents/main/wire.jsonl` | 不启用 |

Kimi App 和 Kimi CLI 是两个独立来源，不得把 CLI 会话混入 Kimi 客户端 Agent。

## 新增适配器

1. 实现 `CPAgentSource` 的 `readAgent`，仅输出归一化模型。
2. 在 `CPAgentProviderCatalog` 注册稳定的 provider ID、名称和说明。
3. 在 `CPAgentProviderIsDetected` 中做只读安装检测。
4. 在 `CPStateReader` 中把 provider ID 映射到 source 实例。
5. 如果提供方有稳定深链，在 `CPDeepLinkForAgentTask` 中实现精确返回；否则明确降级为唤起原应用。
6. 使用 `/tmp` fixture 补充 `--self-test`，不依赖、不修改用户真实会话。

## 安全与性能约束

- 默认只读；不修改 Agent 的 SQLite、JSONL 或会话目录。
- 不读取或输出 token、cookie、API key 等凭证。
- 优先读索引和状态字段；事件流只读有界尾部，并按文件的 mtime/size 缓存。
- SQLite 使用 read-only 连接和短 busy timeout。
- 后台读取，主线程只合入可见变化；数据签名不变时不重建 UI。
