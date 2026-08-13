# 命名决策记录

定名日期：2026-08-13。原名 Codex Pulse，定名**澜台 / Lantai**。

保留这份记录是为了避免以后重新提出已经排除过的名字。所有「已占用」结论都来自当时的公开检索，注明了具体项目和体量。

## 为什么改名

- 原名把产品绑在 Codex 一家上，但项目已经接入 Kimi，后续还要接 Claude Desktop、Cursor 等 GUI Agent，名字会越来越不准。
- 涟漪要抬成产品的设计语言，名字最好能给这套视觉一个理由，否则涟漪永远只是角落里的一个动效。
- 产品是本地 Agent 的只读观察台，名字里最好有「观察」这层。

## 最终选择

**澜台 / Lantai**。澜取涟漪，台取观察台，两个字覆盖了「用涟漪表达状态」和「Agent 观察台」两层意思，拼音无歧义，软件圈无同名。附带一层资源：同音的「兰台」是汉代皇家档案库，中文里至今指档案机构，与「存放和查看记录的地方」相合。

## 已占用，不要再提

| 候选 | 占用方 | 备注 |
| --- | --- | --- |
| Buoy | [buoy-gg/buoy](https://github.com/buoy-gg/buoy) + Buoy Desktop，874★ | 最接近的一次撞车：同为 macOS 桌面 app、同有悬浮菜单、同接 Agent |
| Pond | [tenequm/pond](http://github.com/tenequm/pond) | 读取 Claude Code / Codex CLI 本地会话，与本项目同赛道；另有 DevvGwardo/pond、trypond.ai |
| Sonar | SonarQube / SonarSource | 开发者工具圈头部品牌 |
| Ripple | Ripple / XRP | 另有音频软件的 ripple editing，词义太泛 |
| Lagoon | [uselagoon/lagoon](https://github.com/uselagoon/lagoon/)，593★ | Kubernetes 应用交付平台，占用 lagoon.sh |
| Crest | GitHub 上三个 macOS 菜单栏 app 同名 | 日历（saiftheboss7）、行情（zekevh）、[OneWave-AI/Crest](https://github.com/OneWave-AI/Crest) Claude Code 桌面端；另有 337★ 化学软件 CREST |
| Tarn | [NazarKalytiuk/tarn](https://github.com/NazarKalytiuk/tarn) | 面向 AI Agent 的 API 测试工具 |
| 观澜 / Guanlan | [shenyangs/Guanlan](https://github.com/shenyangs/Guanlan) | 面向 AI Agent 的中文互联网研究工具，含 PyPI 包；另有 [619dev/guanlan](https://github.com/619dev/guanlan) RSS 阅读器 |

值得记住的规律：2026 年 AI 开发工具的命名池里，常见英文单词（尤其是水相关的）基本被扫干净了。八个候选里有四个直接撞在 AI Agent 工具这一小块上。再起名优先考虑合成词、不常用组合或中文词，不要再一个一个试常用单词。

## 查过无同名，但落选

- **听澜 / Tinglan**：「听涟漪」很贴 HUD 的实际用法——不是盯着看，是余光里留意着。落选是因为网文中用得过滥，搜索结果全是言情小说。
- **静池 / Jingchi**：意境好，但既没有「观察」也没直说涟漪，只是氛围。同音的景驰科技已改名 WeRide。
- **枕流 / Zhenliu**：词义相反。枕流漱石是归隐山林、不问世事，与「盯着 Agent 干活」正好拧着。
- **漪台 / Yitai**：漪字比澜更精确，就是涟漪那个字。落选是因为 Yitai 在技术圈会被读成「以太」（以太网、以太坊），对开发者工具是实打实的干扰。

## 讨论过但未正式检索

Stillpond、Wavedeck。属于「英文合成词」方向，在确定以中文名为主之后就没有继续。若将来需要纯英文名，从这条线继续，合成词撞名概率显著低于单词。

## 落地范围

改名只覆盖显示层，不做数据迁移。具体改了什么、刻意没改什么，见 [BACKLOG.md](../BACKLOG.md) 的「命名（已落地）」一节。视觉与涟漪规格见 [DESIGN.md](DESIGN.md)。
