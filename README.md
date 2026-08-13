# 澜台 / Lantai

原生 macOS 本地 Agent 观察台。只读本机 Codex Desktop 和 Kimi App 的任务索引，用菜单栏、HUD、悬浮球和工作台显示状态，并跳回原应用。

**这是个人项目，非官方，与 OpenAI / Moonshot 无关。** 核心能力依赖对方未公开的本地文件格式。客户端一升级，解析就可能失效。本仓库不承诺兼容，也不提供产品级支持。欢迎补适配器，不要把失效当成「澜台坏了」。

只读本机索引，不读取、不写入、不上传登录令牌。

English summary is at the end.

## 当前能力

- 菜单栏常驻，不占 Dock
- 右侧 HUD 抽屉；可换成底部快捷栏
- 工作台：Agent、任务、详情、原应用跳转
- 约 3 秒刷新；单实例
- 内置「添加 Agent」：扫描本机适配器，不改 Agent 源码
- Codex Desktop 与 Kimi App 默认启用；Kimi Code CLI 可选、默认隐藏
- 本地待办栏（SQLite，独立于 Agent，不进入提醒聚合）
- 数据源不可用时明确显示，不静默变成「没有任务」

适配器边界见 [docs/AGENT_ADAPTERS.md](docs/AGENT_ADAPTERS.md)。命名见 [docs/NAMING.md](docs/NAMING.md)。视觉规格见 [docs/DESIGN.md](docs/DESIGN.md)。后续事项见 [BACKLOG.md](BACKLOG.md)。

## 要求

- macOS 14+
- 本机已安装 Codex Desktop 和 / 或 Kimi 电脑客户端（否则对应 Agent 显示数据源不可用）
- 构建：Xcode Command Line Tools（`clang`）。`scripts/build-app.sh` 是唯一验证过的构建路径。仓库里的 `Package.swift` 在部分机器上因 SDK 微版本对不上，`swift build` 会失败。

## 构建

```sh
zsh scripts/build-app.sh
"outputs/Lantai.app/Contents/MacOS/CodexPulse" --self-test
```

图形会话里还可跑 `"outputs/Lantai.app/Contents/MacOS/CodexPulse" --ui-self-test`。完成后打开 `outputs/Lantai.app`。这是本地 ad-hoc 签名的开发版，Gatekeeper 可能要右键打开。

中文系统显示名为「澜台」，英文系统为 Lantai。内部 bundle id 仍是 `com.codexpulse.menubar`，待办库仍在 `~/Library/Application Support/Codex Pulse/`，避免改名时丢数据。

## 隐私

- SQLite 只开只读连接
- 不读 cookie、API key、登录态
- 事件流只读有界尾部
- 没有网络上传

## 文档

| 文件 | 内容 |
| --- | --- |
| [docs/AGENT_ADAPTERS.md](docs/AGENT_ADAPTERS.md) | 如何加一个只读适配器 |
| [docs/NAMING.md](docs/NAMING.md) | 为什么叫澜台，哪些名字已经撞车 |
| [docs/DESIGN.md](docs/DESIGN.md) | 涟漪规格、菜单栏/Logo 还没做的部分 |
| [BACKLOG.md](BACKLOG.md) | 版本路线和未做事项 |

项目知识沉淀使用 [Project Cairn](https://github.com/iBlinkQ/project-cairn)：Skill 装在用户级 `~/.agents/skills/project-cairn`。个人绝对路径不要提交。

## License

[MIT](LICENSE)

---

# Lantai

A native macOS menu-bar workbench that **read-only** watches local GUI coding agents (Codex Desktop, Kimi App), shows status, and deep-links back into the original app.

This is an unofficial personal project. It parses private on-disk formats that can change without notice. No compatibility guarantee.

```sh
zsh scripts/build-app.sh
open outputs/Lantai.app
```

macOS 14+. Ad-hoc signed. See `docs/AGENT_ADAPTERS.md` to add a provider.
