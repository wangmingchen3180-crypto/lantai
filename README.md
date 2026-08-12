# Codex Pulse

Codex Pulse 是一个原生 macOS 本地 Agent 工作台。它以只读方式观察本机 Codex Desktop 和 Kimi App 的任务索引，统一展示最近任务、工作状态、最近活动和原应用入口。

## 当前能力

- 菜单栏常驻，不占用 Dock
- 右侧桌面边缘抽屉：点击把手展开/收起，触控板左右滑动控制
- 可切换到底部快捷栏：“工作台”负责打开总览，Agent 入口同时显示名称与当前状态
- 工作台默认在主显示器居中打开，可拖动顶部标题栏移动
- 单实例运行；再次打开会回到已经运行的 Codex Pulse，避免新旧构建同时出现
- 识别工作、等待处理、完成、错误和空闲状态
- 展示当前任务、项目、持续时间、Token 数和近期任务
- 约 3 秒自动刷新
- 一键打开 Codex 或在 Finder 中显示项目
- 内置“添加 Agent”流程：扫描本机适配器、显示检测状态、持久化启用选择并立即刷新，不需要让 Agent 修改源码
- Kimi 默认读取电脑 Kimi App 的 `conversations.sqlite` 及运行状态；Kimi Code CLI 是独立、默认隐藏的可选 Agent
- 点击 Kimi 客户端任务使用 `kimi-work://chat/<conversation-id>` 返回原会话（客户端未注册深链时降级为唤起应用）
- 工作台底部常驻待办栏：可收起/展开，支持新增、完成/恢复、行内编辑、删除与滚动，本地 SQLite 持久化（`~/Library/Application Support/Codex Pulse/todos.sqlite`），独立于 Agent，计数不进入任何提醒聚合
- Agent 与任务的完成态统一显示为「已就绪」（底层仍保留完成事件语义）
- 只读访问 Codex 与 Kimi 的本地索引，不读取、写入或上传登录令牌

状态是根据 Codex 本地事件推断的。由于官方 Codex Desktop 尚未提供稳定的外部活动线程附着接口，应用不会尝试中断或控制现有任务。

Agent 适配器的边界、内置注册流程和新提供方接入规则见 [docs/AGENT_ADAPTERS.md](docs/AGENT_ADAPTERS.md)。

项目知识沉淀使用 [Project Cairn](https://github.com/iBlinkQ/project-cairn)：Skill 安装在用户级 `~/.agents/skills/project-cairn`，本地项目可在 `.agents/skills/project-cairn` 建立软链；个人绝对路径不提交到开源仓库。

## 构建

```sh
zsh scripts/build-app.sh
"outputs/Codex Pulse.app/Contents/MacOS/CodexPulse" --self-test
```

完成后可运行 `outputs/Codex Pulse.app`。这是本地 ad-hoc 签名的开发版本。当前 MVP 使用原生 AppKit 和系统 SQLite，不依赖第三方库。
