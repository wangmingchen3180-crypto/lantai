# Codex Pulse

Codex Pulse 是一个为 Codex Desktop 设计的原生 macOS 菜单栏小窗。它以只读方式观察本机 Codex 状态库，展示最近任务、工作状态、最近活动和项目入口。

## 当前能力

- 菜单栏常驻，不占用 Dock
- 右侧桌面边缘抽屉：点击把手展开/收起，触控板左右滑动控制
- 可切换到底部快捷栏：“工作台”负责打开总览，Agent 入口同时显示名称与当前状态
- 工作台默认在当前屏幕居中打开，可拖动顶部标题栏移动
- 单实例运行；再次打开会回到已经运行的 Codex Pulse，避免新旧构建同时出现
- 识别工作、等待处理、完成、错误和空闲状态
- 展示当前任务、项目、持续时间、Token 数和近期任务
- 两秒自动刷新
- 一键打开 Codex 或在 Finder 中显示项目
- 工作台底部常驻待办栏：可收起/展开，支持新增、完成/恢复、行内编辑、删除与滚动，本地 SQLite 持久化（`~/Library/Application Support/Codex Pulse/todos.sqlite`），独立于 Agent，计数不进入任何提醒聚合
- Agent 与任务的完成态统一显示为「已就绪」（底层仍保留完成事件语义）
- 只读访问 `~/.codex/state_5.sqlite` 与 `~/.codex/logs_2.sqlite`

状态是根据 Codex 本地事件推断的。由于官方 Codex Desktop 尚未提供稳定的外部活动线程附着接口，应用不会尝试中断或控制现有任务。

## 构建

```sh
zsh scripts/build-app.sh
"outputs/Codex Pulse.app/Contents/MacOS/CodexPulse" --self-test
```

完成后可运行 `outputs/Codex Pulse.app`。这是本地 ad-hoc 签名的开发版本。当前 MVP 使用原生 AppKit 和系统 SQLite，不依赖第三方库。
