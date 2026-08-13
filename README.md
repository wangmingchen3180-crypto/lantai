# 澜台 / Lantai

菜单栏上的一盏灯，告诉你本机的 AI Agent 跑完没有、哪一个在等你。

[![build](https://github.com/wangmingchen3180-crypto/lantai/actions/workflows/build.yml/badge.svg)](https://github.com/wangmingchen3180-crypto/lantai/actions/workflows/build.yml)

[English](README.en.md) · [下载](https://github.com/wangmingchen3180-crypto/lantai/releases) · [MIT](LICENSE) · macOS 14+

![澜台工作台](docs/images/workbench.png)

## 它解决什么

你同时开着 Codex Desktop 和 Kimi，派出去几个任务，转头去干别的。过十分钟开始犯嘀咕：跑完了吗？有没有哪个卡在等我确认？

于是你挨个切窗口去看。Agent 越多，这个动作越频繁，而它本身不产出任何东西。

澜台把这件事收进菜单栏。一盏灯汇总所有 Agent 的状态；需要你的时候，展开能看到具体是哪个 Agent 的哪个任务；点一下直接跳回那条会话。

## 它不做什么

澜台**只读**。不启动 Agent、不代理你的输入、不替你点同意、不改对方的任何数据。

这是设计，不是没做完。同类工具的常见做法是把 Agent 装进自己的终端里托管起来，那样能看得更深，代价是你必须住在它里面。澜台反过来：你照常用 Codex 和 Kimi 的原生 App，它只在旁边看着。它挂了，你的 Agent 照跑。

## 四个界面

按打扰程度从低到高：

| | 用来 |
| --- | --- |
| **菜单栏图标** | 一盏灯，汇总所有 Agent 的最紧急状态 |
| **悬浮球** | 贴在桌面边缘，一圈圈涟漪表示有东西在跑，快慢对应状态 |
| **HUD 抽屉** | 从右侧拉出，按 Agent 分栏，扫一眼各自在忙什么 |
| **工作台** | 完整任务列表、详情、跳回原应用，底部一栏本地待办 |

HUD 抽屉按 Agent 分栏，左边一列是 Agent，右边是它当前的任务：

![HUD 抽屉](docs/images/hud.png)

点进任务是详情，不是直接跳走。确认这条确实是你要找的，再点「在 Codex 中打开」——一级点击只看，二级点击才跳，避免手滑把你从当前上下文里踢出去：

![任务详情](docs/images/workbench-detail.png)

涟漪不是装饰。它只表示「有东西在活着」，扩散周期绑定状态：失败最快 8 秒，待机最慢 14 秒。开了系统的「减少动态效果」就全部静止，只留一圈状态环。

## 支持的 Agent

| Agent | 读什么 | 点任务会 | 默认 |
| --- | --- | --- | --- |
| Codex Desktop | `~/.codex/` 下的 `state_*.sqlite`、`logs_*.sqlite` | 精确跳回那条线程 | 启用 |
| Kimi 电脑客户端 | Kimi App 的 `conversations.sqlite` 和运行状态 | 精确跳回那个会话 | 启用 |
| Kimi Code CLI | `~/.kimi-code/sessions/` | 只能唤起应用，回不到原终端 | 隐藏，需手动添加 |

只接**有图形界面**的 Agent。纯命令行工具（Claude Code CLI、Codex CLI）的运行状态只存在于终端进程里，除非把它们托管进来才看得见，而那就变成宿主了。想加新 Agent 见 [docs/AGENT_ADAPTERS.md](docs/AGENT_ADAPTERS.md)。

数据源读不到时，界面会明说「数据源不可用」，不会静默显示成「没有任务」——那会让你分不清是 Agent 闲着还是监控瞎了。

## 安装

### 下载

去 [Releases](https://github.com/wangmingchen3180-crypto/lantai/releases) 拿 `Lantai-*-macos.zip`，解压后拖进「应用程序」。

包是 ad-hoc 签名的，没做 Apple 公证，所以从网上下载后会被 Gatekeeper 拦住。放行一次：

```sh
xattr -dr com.apple.quarantine /Applications/Lantai.app
```

介意这一步的话，下面自己构建，本地构建的包不带隔离标记。

### 自己构建

需要 Xcode Command Line Tools。

```sh
git clone https://github.com/wangmingchen3180-crypto/lantai.git
cd lantai
zsh scripts/build-app.sh
open outputs/Lantai.app
```

App 常驻菜单栏，不占 Dock。中文系统显示「澜台」，英文系统显示「Lantai」。

### 先看看界面

没装 Codex 或 Kimi 也能看：

```sh
open -n outputs/Lantai.app --args --demo
```

`--demo` 用一组写死的虚构任务替换全部数据源，覆盖运行中、等待确认、完成待查验、失败、待机五种状态。它不读本机任何 Agent 文件，也不受单实例限制，可以和正常运行的澜台并存。README 里的截图就是这么来的。

验证构建：

```sh
"outputs/Lantai.app/Contents/MacOS/CodexPulse" --self-test     # 纯逻辑
"outputs/Lantai.app/Contents/MacOS/CodexPulse" --ui-self-test  # 需要图形会话
```

`scripts/build-app.sh` 是唯一验证过的构建路径。仓库里有 `Package.swift`，但在部分机器上因 SDK 微版本对不上，`swift build` 会失败。

## 隐私

- SQLite 一律只读连接
- 不读 cookie、API key、登录态
- 事件流只读有界尾部，不整个加载
- 没有任何网络请求，不上传

本地待办存在 `~/Library/Application Support/Codex Pulse/todos.sqlite`。目录名沿用改名前的旧名，是为了不让老用户丢数据。

## 名字

澜是涟漪，台是观察台。界面用涟漪表达状态，名字里就得有水；它又确实是个观察台，不是控制台。

定名前查过 Buoy、Pond、Sonar、Ripple、Crest、Tarn、Lagoon、观澜八个候选，全部已被占用，其中四个直接撞在 AI Agent 工具这一小块上——`tenequm/pond` 干的就是读取 Claude Code 和 Codex CLI 的本地会话。完整排查记录在 [docs/NAMING.md](docs/NAMING.md)。

同音的「兰台」是汉代的皇家档案库，中文里至今指档案机构，跟「存放和查看记录的地方」正好合上。

## 已知限制

- **依赖未公开的本地格式。** Codex 和 Kimi 没有承诺过它们的数据库长什么样。客户端一升级，解析就可能失效，界面会变成读不到数据。这是非官方观察工具的常态，不是本项目坏了。遇到了欢迎提 issue 或补适配器。
- 目前只有中文界面。
- 没有公证签名，Gatekeeper 会拦一次。
- 只在 Apple Silicon + macOS 14/15 上跑过。

这是个人项目，非官方，与 OpenAI、Moonshot 无关。当前是 Alpha，内部 bundle id 和数据目录以后会做一次迁移。

## 文档

全部文档在 [docs/](docs/README.md)，索引在那里。常用的几篇：

| | |
| --- | --- |
| [docs/AGENT_ADAPTERS.md](docs/AGENT_ADAPTERS.md) | 怎么加一个只读适配器 |
| [docs/DESIGN.md](docs/DESIGN.md) | 涟漪规格，以及还没做完的图标和 Logo |
| [docs/UI_ARCHITECTURE.md](docs/UI_ARCHITECTURE.md) | 改 UI 的实际成本与皮肤边界 |
| [docs/NAMING.md](docs/NAMING.md) | 命名决策与撞名记录 |
| [docs/BACKLOG.md](docs/BACKLOG.md) | 版本路线和未做事项 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 贡献约束 |

## License

[MIT](LICENSE)
