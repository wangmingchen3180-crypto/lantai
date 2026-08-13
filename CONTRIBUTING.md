# 贡献

澜台是个人 Alpha 项目。最有用的贡献是补一个只读 Agent 适配器，或在对方客户端升级后修好解析。

请先读 [docs/AGENT_ADAPTERS.md](docs/AGENT_ADAPTERS.md)。约束：

- 只读对方本地索引，不要写他们的 SQLite / JSONL
- 不要读取或提交 token、cookie、路径里的真实用户名
- 用 `/tmp` fixture 补 `--self-test`，不要依赖你自己的会话库
- 构建用 `zsh scripts/build-app.sh`，不要假设 `swift build` 能过

Issue 里请写清：哪个 Agent、哪个客户端版本、本机文件大概长什么样（打码路径）。「升级后空了」几乎都是对方换了私有格式，不是菜单栏坏了。

## 截图

README 里的图不要手工截。改了 UI 之后重跑一遍：

```sh
zsh scripts/build-app.sh
"outputs/Lantai.app/Contents/MacOS/CodexPulse" --shot "$PWD/docs/images"
```

`--shot` 隐含 `--demo`，数据全是 `CPDemoSource` 里写死的虚构任务，所以不会把你本机的真实项目名传上来。它走 `-cacheDisplayInRect:`，由应用重绘自己的视图树，不需要「屏幕录制」权限，也不会拍到桌面上别的窗口。

只想看看界面、不生成文件的话用 `--demo`：

```sh
open -n outputs/Lantai.app --args --demo
```
