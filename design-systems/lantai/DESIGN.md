---
name: 澜台 / Lantai
kind: design-system
mode: dark-only
summary: 深石墨底的本地 Agent 观察台。安静、克制、信息密度高；唯一的动效语言是涟漪。
---

# 澜台设计系统

这份文件是**唯一的 token 真相**。手机端 CSS 变量、Mac 端 AppKit 常量、以及任何工具（Open Design 等）渲染澜台界面时，都必须从这里取值。

数值不是设计师拍的，是从已经上线的代码里抽出来的，可复核。抽取命令见文末「怎么复核」。

- 视觉语言与涟漪规格（层数、周期、曲线）见 [`docs/DESIGN.md`](../../docs/DESIGN.md)。**本文件不重复涟漪规格。**
- 改 UI 的成本、皮肤边界、新界面必须守的三条规矩见 [`docs/UI_ARCHITECTURE.md`](../../docs/UI_ARCHITECTURE.md)。

## 硬约束（渲染前先读，违反即返工）

1. **只有深色。** 窗口强制深色，不做浅色皮肤。下面 `light` 槽装的也是深色值——它是 macOS 浅色外观下的基调，不是白底主题。
2. **状态色是语义，不许换。** 绿=已就绪、橙=需关注/等待、红=失败、蓝=运行中。换一套皮肤就要重新教用户认颜色，所以状态色不参与换肤。
3. **涟漪只表示「有东西在活着」。** 不铺到任务卡、待办行、按钮、返回入口。全都在动等于都不动。
4. **不要发明新的间距和字号。** 只用下面梯度里的值。要用梯度外的值，先改这份文件并说明理由。
5. **不许出现绝对路径。** 界面上的项目路径一律脱敏成 `~`。
6. **空状态要分两种。** 「暂无任务」是平静（画静止水面）；「数据源不可用」必须是明确的故障文案，不能画成空水面。

## 颜色

`light` / `dark` 两槽按 macOS `effectiveAppearance` 切换；高对比模式下亮通道再提亮、暗通道再压暗。手机端只用 `dark` 槽。

```yaml
color:
  accent:  { light: "#5280FF", dark: "#668FFF" }   # 强调、选中、主按钮
  bg:      { light: "#181A22", dark: "#13151C" }   # 窗口底
  surface: { light: "#252832", dark: "#20222C" }   # 卡片、行、输入框底
  border:  { light: "#4C5060", dark: "#555969" }   # 控件描边
  fg:      { light: "#EDEDF1", dark: "#F2F2F5" }   # 主文字
  fg2:     { light: "#BDBEC6", dark: "#C7C7CF" }   # 次要文字
  muted:   { light: "#94959E", dark: "#9E9FA8" }   # 提示、计数、时间戳
  hairline: "rgba(255,255,255,0.08)"               # 嵌入式描边,比 border 柔和一档(浅色外观 0.10)
status:
  working:   { light: "#6B96FF", dark: "#7AA3FF" }  # 运行中
  attention: { light: "#FF9E3D", dark: "#FFA84C" }  # 需关注 / 等待
  failed:    { light: "#FF6B6E", dark: "#FF787A" }  # 失败
  ready:     { light: "#54DB73", dark: "#61E380" }  # 已就绪
  idle:      "muted"                                # 空闲复用 muted
shadow:
  card: "rgba(20,20,22,0.12)"   # 工作台
  hud:  "rgba(20,20,22,0.18)"   # HUD / 悬浮球
```

阴影色目前在代码里是直写的字面量（7 处绕过调色板），已记为待收拢项。新界面请用上面的 `shadow` token，不要再直写。

## 圆角

代码里的实际分布（出现次数）：`10`×6、`8`×5、`16`×2、`7`×2、`6`×2、`2`×2、`4`/`12`/`14`/`18` 各 1。收敛成四档，括号里是它现在的用处：

```yaml
radius:
  card: 10    # 工作台卡片、待办卡片
  row: 8      # 待办行、任务行、输入框、胶囊
  chip: 6     # 小标签
  orb: 16     # 悬浮球、HUD 圆角容器
  hairline: 2 # HUD 手柄这类极小构件
```

`12` / `14` / `18` 是历史遗留，新界面不要再用。

## 字号

实际分布：`11`×5、`12`×5、`12.5`×3、`9`×2、`10`/`13`/`14`/`22` 各 1。

```yaml
font:
  display: { size: 22, weight: semibold }  # 悬浮球/大数字
  title:   { size: 14, weight: semibold }  # 卡片标题
  body:    { size: 12, weight: regular }   # 正文、待办标题
  label:   { size: 11, weight: medium }    # 行内标签、按钮
  meta:    { size: 10, weight: regular }   # 时间戳、计数
  micro:   { size: 9,  weight: regular }   # HUD 极限密度处,慎用
family: system   # SF。等宽数字用 monospacedDigit,避免倒计时左右跳动
```

**`12.5` 是异味**，三处在用。半磅字号没有设计理由，新界面归到 `12` 或 `13`，不要复制。

## 间距

实际高频值：`8`×13、`12`×19、`20`×7、`16`×6、`24`×4、`36`×4。

```yaml
space: [2, 4, 6, 8, 12, 16, 20, 24, 36]
usage:
  row-gap: 8         # 列表行之间
  card-padding: 12   # 卡片内边距
  card-margin: 12    # 待办卡片距工作台卡片
  section-gap: 20    # 区块之间
  window-inset: 20   # 窗口留白(容纳阴影)
```

## 几何（Mac 端固定尺寸，不是建议值）

新界面必须在这些框里放得下。**改这些常量会连带返工自测，不要随手改。**

```yaml
workbench:
  card: { w: 520, h: 360 }     # 内容区(头部 + 三列)
  inset: 20                    # 窗口比卡片多出的留白
todo:
  strip: 34                    # 收起态横条
  expanded-extra: 210          # 展开时卡片向下加高
  list-area: { w: 520, h: 158 }  # 展开后真正能放列表的地方(5 行 × 30)
  row: 30
hud:
  content: { w: 400, h: 244 }
  collapsed: { w: 6, h: 72 }
orb: { size: 48, margin: 18 }
```

## 待办四象限：这一版要渲染的东西

空间是硬的：展开后只有 **520×158**。硬摊 2×2 每格约 250×70，加上象限标题就只剩两行，装不下。所以交互定为**四格缩略 + 点选放大**：

- **常态**：四格平分，每格只显示象限名、条数、最多一两条标题（截断，不换行）。
- **选中一格**：该格放大到可读可录入的完整列表（含新增输入框），其余三格收成窄条让位，仍显示名字和条数。
- **切换**：点另一格即换选中，不需要先返回。
- **四象限来源**：`urgent` / `important` 两个布尔的组合，不是一个枚举字段。拖到另一格 = 改一个布尔。

四个象限的固定顺序与叫法（不要自创）：

| 位置 | urgent | important | 名称 |
| --- | --- | --- | --- |
| 左上 | 是 | 是 | 马上做 |
| 右上 | 否 | 是 | 安排做 |
| 左下 | 是 | 否 | 顺手做 |
| 右下 | 否 | 否 | 有空再说 |

同格内还要支持：截止时间（到期高亮用 `status.attention`，已过期用 `status.failed`）、拖拽排序、个人/Agent 分区标记（Agent 待办带来源标记与回跳入口）、已完成折叠归档。

手机端用同一套交互：窄屏摊不开 2×2，但「四格概览 → 点开一格」正是手机的标准手势，不要为手机另设计一套。

## 怎么复核这些数字

```bash
cd "$(git rev-parse --show-toplevel)"
# 颜色源头（CPDyn 的 12 个调色板函数）
rg -n "^NSColor \*CP" Sources/CodexPulse/CPStatusEngine.m
# 圆角、字号、间距的实际分布
rg -o "cornerRadius = [0-9.]+" Sources/CodexPulse/*.m | sort | uniq -c | sort -rn
rg -o "FontOfSize:[0-9.]+" Sources/CodexPulse/*.m | sed 's/.*://' | sort -n | uniq -c
rg -o "constraintEqualToConstant:[0-9.]+|constant:-?[0-9.]+" Sources/CodexPulse/*.m | sed 's/.*://' | sort -n | uniq -c | sort -rn
# 固定几何常量
rg -n "^const CGFloat CP" Sources/CodexPulse/*.m
```

浮点 → 十六进制的换算是 `round(v * 255)`，与手机端现有 CSS 变量完全一致（`accent #668FFF`、`bg #13151C`、`surface #20222C` 三处已交叉验证）。
