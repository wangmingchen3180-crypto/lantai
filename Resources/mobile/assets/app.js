"use strict";

// 手机端只认识 docs/BRIDGE_API.md 的协议，不认识任何一家 Agent 的私有协议。
// 按钮渲染一律依据 capabilities 标签，不得假设某个 Agent 能被指挥。

const STATUS_LABEL = {
  working: "工作中", waiting: "等待中", attention: "需关注",
  completed: "已就绪", failed: "失败", idle: "空闲",
};

// 周期表对齐 CPRippleDurationForStatus，状态只改周期，不改层数与曲线。
const RIPPLE_PERIOD = {
  failed: 8, waiting: 9.6, completedPendingReview: 10.8, working: 12, idle: 14,
};

const RIPPLE_LAYERS = 8;

// 活动流：契约只定义七种 kind，其余一律按未知处理，不猜、不归并到 note。
const STREAM_KINDS = {
  say: { label: "", mono: false, detailMono: false },
  think: { label: "思考", mono: false, detailMono: false },
  run: { label: "运行", mono: true, detailMono: true },
  edit: { label: "改动", mono: true, detailMono: true },
  plan: { label: "计划", mono: false, detailMono: false },
  usage: { label: "用量", mono: false, detailMono: false },
  note: { label: "提示", mono: false, detailMono: false },
};

const STREAM_ICON = {
  say: "M4.5 5.5h15v9.5h-9.8L5.5 19v-3.5H4.5z",
  think: "M12 20a8 8 0 1 0 0-16 8 8 0 0 0 0 16M8.4 12h.01M12 12h.01M15.6 12h.01",
  run: "M5 7.5 9.5 12 5 16.5M12.5 16.5H19",
  edit: "M4 20l4.2-1L19 8.2a1.7 1.7 0 0 0 0-2.4l-.9-.9a1.7 1.7 0 0 0-2.4 0L5 15.8z",
  plan: "M4 7h1.4M4 12h1.4M4 17h1.4M9 7h11M9 12h11M9 17h7",
  usage: "M12 4a8 8 0 1 0 8 8h-8z",
  note: "M12 4.4 20.8 19.6H3.2zM12 10.2v4.1M12 16.9h.01",
  other: "M6 12h.01M12 12h.01M18 12h.01",
};

// 客户端保留上限。服务端每任务只留最近 40 条，这里放宽一点是为了让用户
// 往上翻时还看得到刚滚过去的内容，多出来的部分只可能来自 SSE 增量，不是拼接。
const STREAM_MAX_ENTRIES = 120;
const STREAM_STICK_SLACK = 28;

const store = {
  token: localStorage.getItem("lantai.token") || "",
  agents: [],
  todos: [],
  workdirs: [],
  commands: {},
  streams: {},
  openAgents: new Set(JSON.parse(localStorage.getItem("lantai.open") || "[]")),
  collapsedStreams: new Set(JSON.parse(localStorage.getItem("lantai.stream.collapsed") || "[]")),
  view: "tasks",
  link: "connecting",
  lastSyncMs: 0,
  demo: new URLSearchParams(location.search).get("demo") === "1",
  pendingOps: new Set(),
};

// taskKey -> 当前挂在 DOM 上的活动流视图，用于增量追加而不是整页重绘。
const streamViews = new Map();
// taskKey -> {stick, top}：用户往上翻历史时不把他拽回底部。
const streamScroll = new Map();

const sheet = {
  mode: null,
  agentID: "",
  taskID: "",
  workdirID: "",
  modelID: "",
  commandID: "",
  sending: false,
  lastFocus: null,
};

const confirmState = {
  agent: null,
  task: null,
  sending: false,
};

const commandWatchers = new Map();

const $ = (sel) => document.querySelector(sel);
const el = (tag, cls) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  return n;
};

const uuid = () =>
  crypto.randomUUID ? crypto.randomUUID()
    : "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
        const r = (Math.random() * 16) | 0;
        return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
      });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function relTime(ms) {
  if (!ms) return "";
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 45) return "刚刚";
  if (s < 3600) return `${Math.round(s / 60)} 分钟前`;
  if (s < 86400) return `${Math.round(s / 3600)} 小时前`;
  return `${Math.round(s / 86400)} 天前`;
}

function toast(text, ms) {
  const t = $("#toast");
  t.textContent = text;
  t.classList.add("show");
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => t.classList.remove("show"), ms || 2400);
}

function agentCaps(agent) {
  return Array.isArray(agent && agent.capabilities) ? agent.capabilities : [];
}

function agentCanControl(agent) {
  return agentCaps(agent).includes("control");
}

function agentCanInterrupt(agent) {
  const caps = agentCaps(agent);
  return caps.includes("interrupt") || caps.includes("control");
}

function controllableAgents() {
  return store.agents.filter(agentCanControl);
}

function findAgent(agentID) {
  return store.agents.find((a) => a.agentID === agentID);
}

function agentModels(agent) {
  const rows = agent && Array.isArray(agent.models) ? agent.models : [];
  return rows.filter((m) => m && typeof m.modelID === "string" && m.modelID.trim());
}

function defaultModelID(agent) {
  const found = agentModels(agent).find((m) => m.isDefault);
  return found ? found.modelID : "";
}

function commandErrorText(code) {
  switch (code) {
    case "control_not_permitted":
      return "这台手机还没有指挥权限，请在 Mac 上的『手机指挥设置』里打开";
    case "missing_workdir":
      return "请先选择要在哪个项目里干活";
    case "unknown_workdir":
      return "这个项目已不在允许列表里，请回 Mac 检查『手机指挥设置』";
    case "unknown_model":
      return "这个模型现在不可用，请另选一个或沿用默认";
    case "agent_not_found":
      return "找不到这个 Agent，可能已经关掉了";
    case "driver_unavailable":
      return "这个 Agent 现在接不上，暂时不能指挥";
    case "missing_task":
      return "这条任务已经不在了";
    case "empty_text":
      return "请先写一句指令";
    case "not_managed":
      return "这条任务不是澜台开的，只能看";
    case "busy":
      return "上一条指令还在执行，稍候再发";
    case "bad_action":
      return "这个操作现在做不了";
    case "unauthorized":
      return "凭据失效，请重新配对";
    default:
      return "指令没发出去，电脑可能离线";
  }
}

function commandActionLabel(action) {
  return action === "start" ? "新建任务"
    : action === "steer" ? "补充指令"
      : action === "interrupt" ? "打断" : "指令";
}

function commandStateLabel(state) {
  return state === "accepted" ? "已发送"
    : state === "running" ? "正在交给 Codex"
      : state === "succeeded" ? "已送达 Codex"
        : state === "failed" ? "没能送达" : "";
}

function isRetryable(err) {
  if (!err) return false;
  if (err.message === "unauthorized") return false;
  if (err.data && err.data.error) return false;
  return true;
}

function prefersReducedMotion() {
  return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

function clockTime(ms) {
  if (!ms) return "";
  const d = new Date(ms);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/* ---------------- 活动流状态 ----------------
   契约 docs/BRIDGE_API.md「实时活动流」：seq 单调递增，期望
   上次见到的 seq + entries.length == 本次 seq。不相等就说明中间断过，
   此时不许自己拼，必须重新拉 /api/snapshot 整包对齐。 */

function streamKey(agentID, taskID) {
  return `${agentID || ""}\u0000${taskID || ""}`;
}

function lastSeqOf(entries) {
  return entries.length ? entries[entries.length - 1].seq : 0;
}

function trimStream(stream) {
  if (stream.entries.length <= STREAM_MAX_ENTRIES) return stream;
  stream.entries = stream.entries.slice(-STREAM_MAX_ENTRIES);
  const floor = stream.entries[0].seq;
  for (const seq of Object.keys(stream.gaps)) {
    if (Number(seq) < floor) delete stream.gaps[seq];
  }
  return stream;
}

// 快照里的 stream 与本地已有条目合并：快照只带最近 40 条，直接替换会把
// 用户正在翻的历史砍掉。比快照更早的本地条目留着，缺口如实标出来。
function mergeStream(prev, raw) {
  const incoming = (Array.isArray(raw.entries) ? raw.entries : []).slice();
  const live = raw.live !== false;
  if (!prev || !prev.entries.length) {
    const fresh = { seq: raw.seq ?? lastSeqOf(incoming), live, entries: incoming, gaps: {}, realigning: false };
    return trimStream(fresh);
  }
  const firstIncoming = incoming.length ? incoming[0].seq : null;
  const kept = firstIncoming == null
    ? prev.entries.slice()
    : prev.entries.filter((e) => e.seq < firstIncoming);
  const gaps = Object.assign({}, prev.gaps);
  if (kept.length && firstIncoming != null) {
    const missing = firstIncoming - kept[kept.length - 1].seq - 1;
    if (missing > 0) gaps[firstIncoming] = missing;
  }
  const merged = {
    seq: Math.max(prev.seq || 0, raw.seq ?? lastSeqOf(incoming)),
    live,
    entries: kept.concat(incoming),
    gaps,
    realigning: false,
  };
  return trimStream(merged);
}

function syncStreamsFromSnapshot() {
  const seen = new Set();
  for (const agent of store.agents) {
    for (const task of agent.tasks || []) {
      const key = streamKey(agent.agentID, task.taskID);
      // 只有 managed == true 才可能有流；非托管任务照旧显示 activity 字段。
      if (task.managed !== true) {
        delete store.streams[key];
        continue;
      }
      const raw = task.stream;
      if (!raw || typeof raw !== "object") {
        // 托管但快照里没有流：可能是 Bridge 只跟踪最近 10 个任务、这条被淘汰了。
        // 已经收到的条目不清掉，改成断开状态，比突然变空白诚实。
        const held = store.streams[key];
        if (!held || !held.entries.length) {
          delete store.streams[key];
          continue;
        }
        held.live = false;
        held.realigning = false;
        seen.add(key);
        continue;
      }
      seen.add(key);
      store.streams[key] = mergeStream(store.streams[key], raw);
    }
  }
  for (const key of Object.keys(store.streams)) {
    if (!seen.has(key)) delete store.streams[key];
  }
}

let realignTimer = null;
let realignAtMs = 0;

// 漏批后的重新对齐。合批 + 限速，弱网下连着漏几次也只拉一次快照。
function requestRealign(key) {
  const stream = store.streams[key];
  if (stream) {
    stream.realigning = true;
    const view = streamViews.get(key);
    if (view) paintStreamChrome(view, stream);
  }
  if (realignTimer) return;
  const wait = Math.max(0, 1500 - (Date.now() - realignAtMs));
  realignTimer = setTimeout(() => {
    realignTimer = null;
    realignAtMs = Date.now();
    refresh();
  }, wait);
}

function applyActivity(data) {
  if (!data || !data.taskID) return;
  const key = streamKey(data.agentID, data.taskID);
  const entries = Array.isArray(data.entries) ? data.entries : [];
  const prev = store.streams[key];
  const expected = (prev ? prev.seq : 0) + entries.length;
  const seq = typeof data.seq === "number" ? data.seq : expected;

  store.lastSyncMs = Date.now();

  // 期望不成立 = 中间漏了。不拼，重新拉整包。
  if (seq !== expected) {
    requestRealign(key);
    return;
  }

  const live = data.live !== false;
  const wasEmpty = !prev || prev.entries.length === 0;
  // live 一翻转，整行的构成就变了（降级时要把落盘的 activity 一并摆出来），
  // 这种事少见，直接整页重画最省心。
  const liveFlipped = !!prev && (prev.live !== false) !== live;
  if (!prev) {
    store.streams[key] = trimStream({ seq, live, entries: entries.slice(), gaps: {}, realigning: false });
  } else {
    prev.seq = seq;
    prev.live = live;
    prev.realigning = false;
    if (entries.length) prev.entries = prev.entries.concat(entries);
    trimStream(prev);
  }

  const view = streamViews.get(key);
  if (view && !liveFlipped) updateStreamView(key);
  // 面板还没挂上来（Agent 卡片收着、或这条流刚有第一条）才值得整页重画；
  // 否则收着的卡片会让每一批活动都触发一次全量重绘。
  else if ((view || wasEmpty || liveFlipped) && store.view === "tasks") renderAgents();
}

/* ---------------- 网络层 ---------------- */

async function api(path, options = {}) {
  if (store.demo) return mockApi(path, options);
  const headers = Object.assign({}, options.headers);
  if (store.token) headers.Authorization = `Bearer ${store.token}`;
  if (options.body) headers["Content-Type"] = "application/json";
  const res = await fetch(path, Object.assign({}, options, { headers }));
  if (res.status === 401) {
    forgetToken();
    throw new Error("unauthorized");
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(data.error || `http_${res.status}`), { data });
  return data;
}

function forgetToken() {
  store.token = "";
  localStorage.removeItem("lantai.token");
  closeSheet();
  closeConfirm();
  showPairScreen("设备已被撤销或凭据失效，请重新配对。");
}

function setLink(state) {
  store.link = state;
  const box = $("#link-state");
  box.dataset.link = state;
  // Mac 离线时只说明「最后同步时间」，不伪造成功。
  $("#link-text").textContent =
    state === "online" ? "已连接"
      : state === "offline" ? (store.lastSyncMs ? `离线 · 同步于 ${relTime(store.lastSyncMs)}` : "电脑离线")
        : "连接中";
}

function applySnapshot(data) {
  if (Array.isArray(data.agents)) store.agents = data.agents;
  if (Array.isArray(data.todos)) store.todos = data.todos;
  if (Array.isArray(data.workdirs)) store.workdirs = data.workdirs;
  syncStreamsFromSnapshot();
  store.lastSyncMs = data.serverTimeMs || Date.now();
  setLink("online");
  render();
}

function applyCommand(command) {
  if (!command || !command.commandID) return;
  store.commands[command.commandID] = command;
  if (sheet.commandID === command.commandID) paintSheetStatus(command);
  renderCommandChrome();
  if (store.view === "tasks") renderAgents();
  if (command.state === "succeeded" || command.state === "failed") {
    commandWatchers.delete(command.commandID);
  }
}

function announceCommand(command, instant) {
  const line = `${commandActionLabel(command.action)} · ${commandStateLabel(command.state)}`;
  if (instant) {
    toast(line);
    return;
  }
  if (command.state === "succeeded") toast("已送达 Codex");
  else if (command.state === "failed") {
    toast(command.errorMessage || commandErrorText(command.error), 3600);
  }
}

let eventSource = null;

function connectEvents() {
  if (store.demo || !store.token) return;
  if (eventSource) eventSource.close();
  // EventSource 不支持自定义头，token 以 query 传递；Bridge 仅监听局域网，不做公网暴露。
  eventSource = new EventSource(`/api/events?token=${encodeURIComponent(store.token)}`);
  eventSource.addEventListener("snapshot", (e) => applySnapshot(JSON.parse(e.data)));
  eventSource.addEventListener("todos", (e) => {
    store.todos = JSON.parse(e.data).todos || [];
    store.lastSyncMs = Date.now();
    renderTodos();
  });
  eventSource.addEventListener("activity", (e) => {
    let data = null;
    // 活动流一秒可能来好几条，单条坏包不该把整条连接的处理逻辑带崩。
    try { data = JSON.parse(e.data); } catch (_) { return; }
    applyActivity(data);
  });
  eventSource.addEventListener("command", (e) => {
    const command = JSON.parse(e.data).command;
    if (!command) return;
    const prev = store.commands[command.commandID];
    applyCommand(command);
    if (!prev || prev.state !== command.state) announceCommand(command);
  });
  eventSource.onopen = () => setLink("online");
  eventSource.onerror = () => setLink("offline");
}

function watchCommand(commandID) {
  if (!commandID || store.demo) return;
  if (commandWatchers.has(commandID)) return;
  const started = Date.now();
  const tick = async () => {
    const cmd = store.commands[commandID];
    if (!cmd || cmd.state === "succeeded" || cmd.state === "failed") {
      commandWatchers.delete(commandID);
      return;
    }
    if (Date.now() - started > 45000) {
      commandWatchers.delete(commandID);
      return;
    }
    try {
      const data = await api(`/api/commands/${commandID}`);
      if (data.command) {
        const prev = store.commands[commandID];
        applyCommand(data.command);
        if (!prev || prev.state !== data.command.state) announceCommand(data.command);
      }
    } catch (_) { /* 离线时等 SSE 或下次回到前台 */ }
    if (commandWatchers.has(commandID)) {
      commandWatchers.set(commandID, setTimeout(tick, 1200));
    }
  };
  commandWatchers.set(commandID, setTimeout(tick, 800));
}

async function refresh() {
  try {
    applySnapshot(await api("/api/snapshot"));
  } catch (err) {
    if (err.message !== "unauthorized") setLink("offline");
  }
}

/* ---------------- 配对 ---------------- */

function showPairScreen(message) {
  $("#app").classList.add("hidden");
  $("#pair").classList.remove("hidden");
  $("#pair-error").textContent = message || "";
}

async function submitPair() {
  const code = $("#pair-code").value.replace(/\D/g, "");
  if (code.length !== 6) return;
  const btn = $("#pair-submit");
  btn.disabled = true;
  btn.textContent = "连接中…";
  try {
    const data = await api("/api/pair", {
      method: "POST",
      body: JSON.stringify({ code, deviceName: navigator.userAgent.includes("iPad") ? "iPad" : "手机" }),
    });
    store.token = data.token;
    localStorage.setItem("lantai.token", data.token);
    history.replaceState(null, "", location.pathname);
    enterApp();
  } catch (err) {
    $("#pair-error").textContent =
      err.message === "bad_code" ? "配对码不对或已过期，请在 Mac 上重新生成。"
        : err.message === "too_many_attempts" ? "尝试次数过多，请十分钟后再试。"
          : "连不上澜台，确认 Mac 开着机、和手机在同一网络。";
  } finally {
    btn.disabled = false;
    btn.textContent = "连接";
  }
}

/* ---------------- 渲染 ---------------- */

// 涟漪只表示「有东西在活着」：仅展开中且非空闲的 Agent 起涟漪，
// 对应 Mac 端「选谁听谁」。任务行、待办行、按钮一律不铺涟漪。
function rippleNode(status, displayStatus, animate) {
  const wrap = el("div", "ripple");
  wrap.style.setProperty("--dot", `var(--${status})`);
  if (animate) {
    const period = RIPPLE_PERIOD[displayStatus] ?? RIPPLE_PERIOD.idle;
    for (let i = 0; i < RIPPLE_LAYERS; i++) {
      const delay = `${(-period * i) / RIPPLE_LAYERS}s`;
      const trough = el("div", "wave trough");
      trough.style.cssText = `--period:${period}s;--peak:.18;animation-delay:${delay}`;
      const crest = el("div", "wave");
      crest.style.cssText = `--period:${period}s;--peak:.22;animation-delay:${delay}`;
      wrap.append(trough, crest);
    }
  }
  wrap.append(el("div", "core"));
  return wrap;
}

function stillWater() {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", "still-water");
  svg.setAttribute("viewBox", "0 0 46 46");
  svg.innerHTML =
    '<circle cx="23" cy="23" r="5" stroke-width="1.4"/>' +
    '<circle cx="23" cy="23" r="12" stroke-width="1.1" opacity=".6"/>' +
    '<circle cx="23" cy="23" r="18.5" stroke-width=".9" opacity=".3"/>';
  return svg;
}

function statusPill(status) {
  const pill = el("span", "status-pill");
  pill.style.setProperty("--dot", `var(--${status})`);
  pill.append(el("span", "swatch"), document.createTextNode(STATUS_LABEL[status] || status));
  return pill;
}

function latestCommand() {
  const list = Object.values(store.commands);
  if (!list.length) return null;
  return list.reduce((best, cur) =>
    (cur.updatedAtMs || 0) >= (best.updatedAtMs || 0) ? cur : best);
}

function commandForTask(taskID) {
  if (!taskID) return null;
  let best = null;
  for (const cmd of Object.values(store.commands)) {
    if (cmd.taskID !== taskID) continue;
    if (!best || (cmd.updatedAtMs || 0) >= (best.updatedAtMs || 0)) best = cmd;
  }
  return best;
}

function renderCommandChrome() {
  const can = controllableAgents().length > 0;
  const hint = $("#control-hint");
  const showHint = !can && store.agents.length > 0 && store.link !== "offline";
  hint.textContent = showHint ? "当前没有可指挥的 Agent" : "";
  hint.classList.toggle("hidden", !showHint);

  const showFab = store.view === "tasks" && can && !sheet.mode && !confirmState.agent;
  $("#fab-start").classList.toggle("hidden", !showFab);
  $("#view-tasks").classList.toggle("has-fab", showFab);

  const banner = $("#cmd-banner");
  const cmd = latestCommand();
  const fresh = cmd && ((cmd.state === "accepted" || cmd.state === "running")
    || Date.now() - (cmd.updatedAtMs || 0) < 8000);
  if (!cmd || !fresh) {
    banner.classList.add("hidden");
    banner.textContent = "";
    return;
  }
  banner.classList.remove("hidden");
  banner.dataset.state = cmd.state || "";
  banner.textContent = "";
  const title = el("div");
  title.textContent = `${commandActionLabel(cmd.action)} · ${commandStateLabel(cmd.state)}`;
  banner.append(title);
  if (cmd.state === "failed" && cmd.errorMessage) {
    const sub = el("div", "cmd-banner-sub");
    sub.textContent = cmd.errorMessage;
    banner.append(sub);
  }
}

function renderAgents() {
  const list = $("#agent-list");
  list.textContent = "";
  streamViews.clear();
  $("#agent-count").textContent = store.agents.length ? `${store.agents.length} 个` : "";
  renderCommandChrome();

  if (!store.agents.length) {
    const box = el("div", "agent-card");
    const empty = el("div", "empty-water");
    const text = el("div", "empty-text");
    text.textContent = store.link === "offline" ? "电脑离线，暂时看不到 Agent" : "还没有启用任何 Agent";
    empty.append(stillWater(), text);
    box.append(empty);
    list.append(box);
    return;
  }

  for (const agent of store.agents) {
    const open = store.openAgents.has(agent.agentID);
    const card = el("div", "agent-card");
    card.dataset.open = String(open);

    const head = el("button", "agent-head");
    head.append(rippleNode(agent.status, agent.displayStatus, open && agent.status !== "idle"));

    const body = el("div");
    const name = el("div", "agent-name");
    name.textContent = agent.name;
    const meta = el("div", "agent-meta");
    let metaText = STATUS_LABEL[agent.status] || agent.status;
    if (agent.controlRoute === "relayed") metaText += " · 经转达指挥";
    meta.textContent = metaText;
    body.append(name, meta);
    head.append(body);

    const right = el("div", "agent-right");
    if (agent.health === "ok") {
      const count = el("span", "task-count");
      count.textContent = agent.tasks?.length ? `${agent.tasks.length} 个任务` : "无任务";
      right.append(count);
    }
    right.append(el("div", "chevron"));
    head.append(right);
    head.onclick = () => {
      open ? store.openAgents.delete(agent.agentID) : store.openAgents.add(agent.agentID);
      localStorage.setItem("lantai.open", JSON.stringify([...store.openAgents]));
      renderAgents();
    };
    card.append(head);

    // health=missing 必须原样透出，不允许退化成「没有任务」。
    if (agent.health === "missing") {
      const down = el("div", "source-down");
      down.textContent = "数据源不可用：读不到这个 Agent 的本地任务索引，状态未知。";
      card.append(down);
    } else if (open) {
      const wrap = el("div", "task-list");
      if (!agent.tasks?.length) {
        const empty = el("div", "empty-water");
        const text = el("div", "empty-text");
        text.textContent = "当前没有任务";
        empty.append(stillWater(), text);
        wrap.append(empty);
      } else {
        for (const task of agent.tasks) wrap.append(taskRow(task, agent));
      }
      card.append(wrap);
    }
    list.append(card);
  }

  // 入 DOM 之后才量得到高度：恢复滚动位置、判断 detail 有没有被夹住。
  for (const key of streamViews.keys()) settleStreamView(key);
}

function taskRow(task, agent) {
  const row = el("div", "task-row");
  row.append(statusDot(task.status));

  const body = el("div", "task-body");
  const title = el("div", "task-title");
  title.textContent = task.title || "未命名任务";
  body.append(title);

  const sub = el("div", "task-sub");
  // 只显示 projectName；Bridge 契约禁止下发本地绝对路径。
  if (task.projectName) sub.append(document.createTextNode(task.projectName));
  sub.append(statusPill(task.status));
  if (task.managed !== true) {
    const mark = el("span", "readonly-mark");
    mark.textContent = "只读观察";
    sub.append(mark);
  }
  if (task.updatedAtMs) sub.append(document.createTextNode(relTime(task.updatedAtMs)));
  body.append(sub);

  // 有实时流时不再重复显示落盘的 activity；流断了（live:false）则两样都要，
  // 那一行落盘结果正是降级说明里所指的「下面是落盘后的结果」。
  const stream = store.streams[streamKey(agent.agentID, task.taskID)] || null;
  const showStream = !!stream &&
    (stream.entries.length > 0 || stream.live === false || task.status === "working");
  if (task.activity && (!showStream || stream.live === false)) {
    const act = el("div", "task-activity");
    act.textContent = task.activity;
    body.append(act);
  }
  if (showStream) body.append(streamPanel(agent, task, stream));

  const cmd = commandForTask(task.taskID);
  if (cmd) {
    const line = el("div", "task-cmd");
    line.dataset.state = cmd.state || "";
    line.textContent = cmd.state === "failed" && cmd.errorMessage
      ? `${commandActionLabel(cmd.action)} · ${cmd.errorMessage}`
      : `${commandActionLabel(cmd.action)} · ${commandStateLabel(cmd.state)}`;
    body.append(line);
  }

  if (task.managed === true) {
    const actions = el("div", "task-actions");
    if (agentCanControl(agent)) {
      const steer = el("button", "task-action");
      steer.type = "button";
      steer.setAttribute("aria-label", `给「${task.title || "未命名任务"}」补充一句`);
      steer.textContent = "补充一句";
      steer.onclick = () => openSteerSheet(agent, task);
      actions.append(steer);
    }
    if (agentCanInterrupt(agent)) {
      const stop = el("button", "task-action");
      stop.type = "button";
      stop.setAttribute("aria-label", `打断「${task.title || "未命名任务"}」`);
      stop.textContent = "打断";
      stop.onclick = () => openConfirm(agent, task);
      actions.append(stop);
    }
    if (actions.childNodes.length) body.append(actions);
  }
  row.append(body);

  if (task.reviewed === false && task.status === "completed") row.append(el("div", "unreviewed"));
  return row;
}

function statusDot(status) {
  const dot = el("div", "ripple");
  dot.style.cssText = `--dot:var(--${status});width:16px;height:16px`;
  const core = el("div", "core");
  core.style.cssText = "width:8px;height:8px";
  dot.append(core);
  return dot;
}

/* ---------------- 活动流渲染 ---------------- */

function streamIcon(kind) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "1.7");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", STREAM_ICON[kind] || STREAM_ICON.other);
  svg.append(path);
  return svg;
}

function streamEntryNode(entry, prevEntry, fresh) {
  const known = !!STREAM_KINDS[entry.kind];
  const kind = known ? entry.kind : "other";
  const spec = known ? STREAM_KINDS[entry.kind] : { label: "输出", mono: false, detailMono: true };

  const row = el("div", "stream-entry");
  row.dataset.kind = kind;
  if (fresh && !prefersReducedMotion()) row.classList.add("stream-in");

  const icon = el("span", "stream-icon");
  icon.append(streamIcon(kind));
  row.append(icon);

  const main = el("div", "stream-main");
  const line = el("div", "stream-line");
  if (spec.label) {
    const tag = el("span", "stream-kind");
    tag.textContent = spec.label;
    line.append(tag);
  }
  const text = el("span", "stream-text" + (spec.mono ? " mono" : ""));
  text.textContent = entry.text || "";
  line.append(text);

  const stamp = clockTime(entry.atMs);
  if (stamp && stamp !== clockTime(prevEntry && prevEntry.atMs)) {
    const time = el("span", "stream-time");
    time.textContent = stamp;
    line.append(time);
  }
  main.append(line);

  if (entry.detail) {
    // run 的 detail 是命令输出，edit 是补丁摘要，等宽读起来才对齐。
    const detail = el("div", "stream-detail" + (spec.detailMono ? " mono" : ""));
    detail.textContent = entry.detail;
    detail.onclick = () => {
      if (detail.dataset.more !== "1") return;
      detail.classList.toggle("open");
    };
    main.append(detail);
  }

  row.append(main);
  return row;
}

function streamGapNode(missing) {
  const gap = el("div", "stream-gap");
  gap.textContent = `中间漏了 ${missing} 条，已重新对齐`;
  return gap;
}

// 夹住的 detail 要让人看得出还有下文，否则命令输出会被悄悄吃掉一半。
function measureDetail(node) {
  const detail = node.querySelector && node.querySelector(".stream-detail");
  if (!detail || detail.classList.contains("open")) return;
  const clipped = detail.scrollHeight > detail.clientHeight + 2;
  detail.dataset.more = clipped ? "1" : "0";
  if (clipped) detail.setAttribute("title", "点按展开");
  else detail.removeAttribute("title");
}

function paintStreamChrome(view, stream) {
  const live = stream.live !== false;
  view.box.dataset.live = String(live);
  view.title.textContent = stream.realigning
    ? "实时活动 · 正在重新对齐"
    : live ? "实时活动" : "实时活动 · 已断开";
  view.count.textContent = stream.entries.length ? `${stream.entries.length} 条` : "";
  view.notice.classList.toggle("hidden", live);
  view.wait.classList.toggle("hidden", stream.entries.length > 0 || !live);
}

function streamPanel(agent, task, stream) {
  const key = streamKey(agent.agentID, task.taskID);
  const collapsed = store.collapsedStreams.has(key);

  const box = el("div", "stream");
  const head = el("button", "stream-head");
  head.type = "button";
  head.setAttribute("aria-expanded", String(!collapsed));
  const title = el("span", "stream-title");
  const count = el("span", "stream-count");
  head.append(el("span", "stream-dot"), title, count, el("span", "chevron stream-chevron"));
  head.onclick = () => {
    if (collapsed) store.collapsedStreams.delete(key);
    else store.collapsedStreams.add(key);
    localStorage.setItem("lantai.stream.collapsed", JSON.stringify([...store.collapsedStreams]));
    renderAgents();
  };
  box.append(head);

  const bodyBox = el("div", "stream-body");
  bodyBox.classList.toggle("hidden", collapsed);

  // live:false 必须显式降级，不能画成空白：空白会让人以为 Agent 什么都没干。
  const notice = el("div", "stream-degraded");
  notice.textContent = "实时输出已断开，下面是落盘后的结果";

  const wait = el("div", "stream-wait");
  wait.textContent = "等着 Codex 的第一句输出…";

  const log = el("div", "stream-log");
  log.setAttribute("role", "log");

  let prevEntry = null;
  for (const entry of stream.entries) {
    const missing = stream.gaps[entry.seq];
    if (missing) log.append(streamGapNode(missing));
    log.append(streamEntryNode(entry, prevEntry, false));
    prevEntry = entry;
  }

  const jump = el("button", "stream-jump hidden");
  jump.type = "button";
  jump.textContent = "新内容 ↓";

  bodyBox.append(notice, wait, log, jump);
  box.append(bodyBox);

  const view = {
    key, box, title, count, notice, wait, log, jump,
    renderedSeq: prevEntry ? prevEntry.seq : 0,
    lastEntry: prevEntry,
  };
  streamViews.set(key, view);

  log.onscroll = () => {
    const stick = log.scrollHeight - log.scrollTop - log.clientHeight < STREAM_STICK_SLACK;
    streamScroll.set(key, { stick, top: log.scrollTop });
    if (stick) jump.classList.add("hidden");
  };
  jump.onclick = () => {
    streamScroll.set(key, { stick: true, top: log.scrollHeight });
    jump.classList.add("hidden");
    scrollStreamToBottom(view, true);
  };

  paintStreamChrome(view, stream);
  return box;
}

function scrollStreamToBottom(view, smooth) {
  const behavior = smooth && !prefersReducedMotion() ? "smooth" : "auto";
  if (typeof view.log.scrollTo === "function") {
    view.log.scrollTo({ top: view.log.scrollHeight, behavior });
  } else {
    view.log.scrollTop = view.log.scrollHeight;
  }
}

function updateStreamView(key) {
  const view = streamViews.get(key);
  const stream = store.streams[key];
  if (!view || !stream) return;
  paintStreamChrome(view, stream);

  let added = 0;
  for (const entry of stream.entries) {
    if (entry.seq <= view.renderedSeq) continue;
    const missing = stream.gaps[entry.seq];
    if (missing) view.log.append(streamGapNode(missing));
    const node = streamEntryNode(entry, view.lastEntry, true);
    view.log.append(node);
    measureDetail(node);
    view.lastEntry = entry;
    view.renderedSeq = entry.seq;
    added += 1;
  }
  if (!added) return;

  // 用户正往上翻历史时不打断他：只亮一个「新内容」的角标，不抢滚动。
  const stick = (streamScroll.get(key) || { stick: true }).stick;
  if (!stick) {
    view.jump.classList.remove("hidden");
    return;
  }
  while (view.log.childElementCount > STREAM_MAX_ENTRIES) {
    view.log.removeChild(view.log.firstElementChild);
  }
  scrollStreamToBottom(view, true);
}

function settleStreamView(key) {
  const view = streamViews.get(key);
  if (!view) return;
  for (const node of Array.from(view.log.children)) measureDetail(node);
  const state = streamScroll.get(key) || { stick: true, top: 0 };
  view.log.scrollTop = state.stick ? view.log.scrollHeight : state.top;
}

function renderTodos() {
  const list = $("#todo-list");
  list.textContent = "";
  const pending = store.todos.filter((t) => !t.completed).length;
  $("#todo-count").textContent = store.todos.length ? `${pending} 项未完成` : "";

  const badge = $("#todo-badge");
  badge.textContent = pending || "";
  badge.classList.toggle("hidden", !pending);

  if (!store.todos.length) {
    const empty = el("div", "empty-water");
    const text = el("div", "empty-text");
    text.textContent = "还没有待办";
    empty.append(stillWater(), text);
    list.append(empty);
    return;
  }

  for (const todo of store.todos) {
    const row = el("div", "todo-row" + (todo.completed ? " done" : "") +
      (store.pendingOps.has(todo.todoID) ? " pending-sync" : ""));

    const check = el("button", "todo-check");
    check.setAttribute("aria-label", todo.completed ? "标记未完成" : "标记完成");
    check.innerHTML =
      '<svg viewBox="0 0 12 12" fill="none" stroke="#13151c" stroke-width="2.1" ' +
      'stroke-linecap="round" stroke-linejoin="round"><path d="M2 6.4 4.7 9 10 3.2"/></svg>';
    check.onclick = () => patchTodo(todo, { completed: !todo.completed });

    const title = el("div", "todo-title");
    title.textContent = todo.title;

    const del = el("button", "todo-del");
    del.setAttribute("aria-label", "删除");
    del.innerHTML =
      '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
      'stroke-width="1.8" stroke-linecap="round"><path d="M5 7h14M10 11v6M14 11v6M6 7l1 12h10l1-12M9 7V4h6v3"/></svg>';
    del.onclick = () => deleteTodo(todo);

    row.append(check, title, del);
    list.append(row);
  }
}

function render() {
  renderAgents();
  renderTodos();
}

/* ---------------- 指挥 ---------------- */

function paintChipList(box, items, selectedID, onPick) {
  box.textContent = "";
  for (const item of items) {
    const chip = el("button", "chip");
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(item.id === selectedID));
    chip.textContent = item.name;
    if (item.description) chip.title = item.description;
    chip.onclick = () => onPick(item.id);
    box.append(chip);
  }
}

function paintSheetFields() {
  const agents = controllableAgents();
  const agentBox = $("#sheet-agents");
  const dirBox = $("#sheet-workdirs");
  const modelBox = $("#sheet-models");
  const empty = $("#sheet-empty");
  const context = $("#sheet-context");
  const text = $("#sheet-text");

  if (sheet.mode === "start") {
    $("#sheet-title").textContent = "新建任务";
    text.placeholder = "写给 Agent 的指令";
    text.classList.remove("hidden");
    const agent = findAgent(sheet.agentID);
    context.classList.toggle("hidden", !(agent && agent.controlRoute === "relayed"));
    context.textContent = agent && agent.controlRoute === "relayed"
      ? "这条指令会经转达发出，可能不如直连稳。" : "";

    if (agents.length > 1) {
      agentBox.classList.remove("hidden");
      paintChipList(agentBox, agents.map((a) => ({ id: a.agentID, name: a.name })),
        sheet.agentID, (id) => {
          sheet.agentID = id;
          sheet.modelID = defaultModelID(findAgent(id));
          paintSheetFields();
        });
    } else {
      agentBox.classList.add("hidden");
      agentBox.textContent = "";
    }

    if (!store.workdirs.length) {
      dirBox.classList.add("hidden");
      dirBox.textContent = "";
      empty.classList.remove("hidden");
      empty.classList.add("warn");
      empty.textContent = "Mac 上还没有允许指挥的项目，请在澜台的『手机指挥设置』里添加";
    } else {
      dirBox.classList.remove("hidden");
      paintChipList(dirBox, store.workdirs.map((w) => ({ id: w.workdirID, name: w.name })),
        sheet.workdirID, (id) => { sheet.workdirID = id; paintSheetFields(); });
      // 多个项目时不预选，不替人决定 Agent 往哪个目录里写。但发送按钮这时是灰的，
      // 必须当场说明为什么：submitSheet 里那句 missing_workdir 提示要按下去才出得来，
      // 而按钮恰恰按不动，等于永远看不到。
      const needPick = !sheet.workdirID;
      empty.classList.toggle("hidden", !needPick);
      empty.classList.remove("warn");
      empty.textContent = needPick ? "先选一个项目，Agent 就在这个项目里干活" : "";
    }

    if (modelBox) {
      const models = agentModels(findAgent(sheet.agentID));
      if (!models.length) {
        modelBox.classList.add("hidden");
        modelBox.textContent = "";
      } else {
        modelBox.classList.remove("hidden");
        paintChipList(modelBox, models.map((m) => ({
          id: m.modelID, name: m.name || m.modelID, description: m.description || "",
        })), sheet.modelID, (id) => { sheet.modelID = id; paintSheetFields(); });
      }
    }
  } else {
    $("#sheet-title").textContent = "补充一句";
    text.placeholder = "接着告诉 Agent 的话";
    text.classList.remove("hidden");
    agentBox.classList.add("hidden");
    dirBox.classList.add("hidden");
    if (modelBox) {
      modelBox.classList.add("hidden");
      modelBox.textContent = "";
    }
    empty.classList.add("hidden");
    context.classList.remove("hidden");
    const taskTitle = (findAgent(sheet.agentID)?.tasks || [])
      .find((t) => t.taskID === sheet.taskID)?.title || "这条任务";
    context.textContent = `给「${taskTitle}」补充一句`;
  }
  syncSheetSend();
}

function syncSheetSend() {
  const send = $("#sheet-send");
  const text = $("#sheet-text").value.trim();
  let ok = !sheet.sending && !!text;
  if (sheet.mode === "start") {
    ok = ok && !!sheet.agentID && !!sheet.workdirID && store.workdirs.length > 0;
  }
  send.disabled = !ok;
  send.textContent = sheet.sending ? "发送中…" : "发送";
  send.setAttribute("aria-busy", String(sheet.sending));
}

function paintSheetStatus(command) {
  const box = $("#sheet-status");
  if (!command) {
    box.textContent = "";
    box.removeAttribute("data-state");
    return;
  }
  box.dataset.state = command.state || "";
  box.textContent = command.state === "failed" || command.state === "note"
    ? (command.errorMessage || commandErrorText(command.error))
    : commandStateLabel(command.state);
  if (command.state === "succeeded" && sheet.mode) {
    setTimeout(() => { if (sheet.commandID === command.commandID) closeSheet(); }, 1100);
  }
}

function openStartSheet() {
  const agents = controllableAgents();
  if (!agents.length) return;
  sheet.lastFocus = document.activeElement;
  sheet.mode = "start";
  sheet.agentID = agents[0].agentID;
  sheet.taskID = "";
  sheet.workdirID = store.workdirs.length === 1 ? store.workdirs[0].workdirID : "";
  sheet.modelID = defaultModelID(agents[0]);
  sheet.commandID = "";
  sheet.sending = false;
  $("#sheet-text").value = "";
  paintSheetStatus(null);
  paintSheetFields();
  $("#command-sheet").classList.remove("hidden");
  renderCommandChrome();
  document.body.style.overflow = "hidden";
  setTimeout(() => $("#sheet-text").focus(), 50);
}

function openSteerSheet(agent, task) {
  sheet.lastFocus = document.activeElement;
  sheet.mode = "steer";
  sheet.agentID = agent.agentID;
  sheet.taskID = task.taskID;
  sheet.workdirID = "";
  sheet.modelID = "";
  sheet.commandID = "";
  sheet.sending = false;
  $("#sheet-text").value = "";
  paintSheetStatus(null);
  paintSheetFields();
  $("#command-sheet").classList.remove("hidden");
  renderCommandChrome();
  document.body.style.overflow = "hidden";
  setTimeout(() => $("#sheet-text").focus(), 50);
}

function closeSheet() {
  if (!sheet.mode) return;
  sheet.mode = null;
  sheet.sending = false;
  $("#command-sheet").classList.add("hidden");
  document.body.style.overflow = "";
  renderCommandChrome();
  const back = sheet.lastFocus;
  sheet.lastFocus = null;
  if (back && typeof back.focus === "function") back.focus();
}

function openConfirm(agent, task) {
  confirmState.agent = agent;
  confirmState.task = task;
  confirmState.sending = false;
  $("#confirm-ok").disabled = false;
  $("#confirm-ok").textContent = "打断";
  $("#confirm-sheet").classList.remove("hidden");
  renderCommandChrome();
  document.body.style.overflow = "hidden";
  $("#confirm-ok").focus();
}

function closeConfirm() {
  if (!confirmState.agent && $("#confirm-sheet").classList.contains("hidden")) return;
  confirmState.agent = null;
  confirmState.task = null;
  confirmState.sending = false;
  $("#confirm-sheet").classList.add("hidden");
  if (!sheet.mode) document.body.style.overflow = "";
  renderCommandChrome();
}

async function sendCommand(fields) {
  const opID = fields.opID;
  const body = { opID, action: fields.action, agentID: fields.agentID };
  if (fields.taskID) body.taskID = fields.taskID;
  if (fields.workdirID) body.workdirID = fields.workdirID;
  if (fields.modelID) body.modelID = fields.modelID;
  if (fields.text != null) body.text = fields.text;

  let lastErr;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const data = await api("/api/commands", {
        method: "POST",
        body: JSON.stringify(body),
      });
      if (data.command) {
        applyCommand(data.command);
        watchCommand(data.command.commandID);
      }
      return data;
    } catch (err) {
      lastErr = err;
      if (!isRetryable(err) || attempt === 1) throw err;
      await sleep(500);
    }
  }
  throw lastErr;
}

async function submitSheet() {
  if (sheet.sending) return;
  const text = $("#sheet-text").value.trim();
  if (!text) {
    paintSheetStatus({ state: "failed", errorMessage: commandErrorText("empty_text") });
    return;
  }
  if (sheet.mode === "start" && (!sheet.workdirID || !store.workdirs.length)) {
    paintSheetStatus({ state: "failed", errorMessage: commandErrorText("missing_workdir") });
    return;
  }

  const opID = uuid();
  sheet.sending = true;
  syncSheetSend();
  paintSheetStatus({ state: "accepted" });

  try {
    const payload = sheet.mode === "start"
      ? { opID, action: "start", agentID: sheet.agentID, workdirID: sheet.workdirID, text,
          ...(sheet.modelID ? { modelID: sheet.modelID } : {}) }
      : { opID, action: "steer", agentID: sheet.agentID, taskID: sheet.taskID, text };
    const data = await sendCommand(payload);
    if (data.command) {
      sheet.commandID = data.command.commandID;
      announceCommand(data.command, true);
      paintSheetStatus(data.command);
    } else {
      toast("已发送");
    }
  } catch (err) {
    // demoNote 只可能来自 ?demo=1 的演示开关，真实模式下永远是 undefined。
    if (err.demoNote) {
      paintSheetStatus({ state: "note", errorMessage: err.demoNote });
      toast(err.demoNote, 3200);
      setTimeout(closeSheet, 900);
    } else {
      const message = commandErrorText(err.message);
      paintSheetStatus({ state: "failed", errorMessage: message });
      toast(message, 3600);
    }
  } finally {
    sheet.sending = false;
    syncSheetSend();
  }
}

async function submitInterrupt() {
  const agent = confirmState.agent;
  const task = confirmState.task;
  if (!agent || !task || confirmState.sending) return;
  confirmState.sending = true;
  $("#confirm-ok").disabled = true;
  $("#confirm-ok").textContent = "发送中…";
  const opID = uuid();
  try {
    const data = await sendCommand({
      opID, action: "interrupt", agentID: agent.agentID, taskID: task.taskID,
    });
    closeConfirm();
    if (data.command) announceCommand(data.command, true);
    else toast("已发送");
  } catch (err) {
    closeConfirm();
    toast(commandErrorText(err.message), 3600);
  }
}

/* ---------------- 待办写操作 ---------------- */
// 乐观更新但标记 pending-sync；失败一律回滚并提示，绝不把失败显示成成功。

async function addTodo() {
  const input = $("#todo-input");
  const title = input.value.trim();
  if (!title) return;
  input.value = "";
  $("#todo-add").disabled = true;
  try {
    const { todo } = await api("/api/todos", {
      method: "POST",
      body: JSON.stringify({ opID: uuid(), title }),
    });
    // SSE 的 todos 事件可能已经先把这条推进来了，按 ID 去重，避免同一条显示两遍。
    if (!store.todos.some((t) => t.todoID === todo.todoID)) store.todos.push(todo);
    renderTodos();
  } catch (err) {
    input.value = title;
    toast(err.message === "unauthorized" ? "凭据失效" : "添加失败，电脑可能离线");
  } finally {
    $("#todo-add").disabled = !input.value.trim();
  }
}

async function patchTodo(todo, patch) {
  const before = Object.assign({}, todo);
  Object.assign(todo, patch);
  store.pendingOps.add(todo.todoID);
  renderTodos();
  try {
    const { todo: fresh } = await api(`/api/todos/${todo.todoID}`, {
      method: "PATCH",
      body: JSON.stringify(Object.assign({ opID: uuid() }, patch)),
    });
    Object.assign(todo, fresh);
  } catch (err) {
    Object.assign(todo, before);
    toast(err.message === "not_found" ? "这条待办已不存在" : "改不动，电脑可能离线");
  } finally {
    store.pendingOps.delete(todo.todoID);
    renderTodos();
  }
}

async function deleteTodo(todo) {
  const index = store.todos.indexOf(todo);
  store.todos.splice(index, 1);
  renderTodos();
  try {
    await api(`/api/todos/${todo.todoID}`, {
      method: "DELETE",
      body: JSON.stringify({ opID: uuid() }),
    });
  } catch (err) {
    if (err.message === "not_found") return;
    store.todos.splice(index, 0, todo);
    renderTodos();
    toast("删不掉，电脑可能离线");
  }
}

/* ---------------- 启动 ---------------- */

function switchView(view) {
  store.view = view;
  $("#view-tasks").classList.toggle("hidden", view !== "tasks");
  $("#view-todos").classList.toggle("hidden", view !== "todos");
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.setAttribute("aria-selected", String(tab.dataset.view === view));
  });
  if (view === "tasks") renderAgents();
  else renderCommandChrome();
}

function syncKeyboardInset() {
  const vv = window.visualViewport;
  const kb = vv ? Math.max(0, window.innerHeight - vv.height - vv.offsetTop) : 0;
  document.documentElement.style.setProperty("--kb", `${Math.round(kb)}px`);
}

function enterApp() {
  $("#pair").classList.add("hidden");
  $("#app").classList.remove("hidden");
  refresh();
  connectEvents();
}

function bindEvents() {
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.onclick = () => switchView(tab.dataset.view);
  });

  const code = $("#pair-code");
  code.oninput = () => {
    code.value = code.value.replace(/\D/g, "").slice(0, 6);
    $("#pair-submit").disabled = code.value.length !== 6;
  };
  $("#pair-submit").onclick = submitPair;

  const input = $("#todo-input");
  input.oninput = () => { $("#todo-add").disabled = !input.value.trim(); };
  input.onkeydown = (e) => { if (e.key === "Enter") addTodo(); };
  $("#todo-add").onclick = addTodo;

  $("#fab-start").onclick = openStartSheet;
  $("#sheet-close").onclick = closeSheet;
  $("#sheet-backdrop").onclick = closeSheet;
  $("#sheet-send").onclick = submitSheet;
  $("#sheet-text").oninput = syncSheetSend;
  $("#sheet-text").onkeydown = (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      submitSheet();
    }
  };
  $("#sheet-text").addEventListener("focus", () => {
    setTimeout(() => {
      $("#sheet-send").scrollIntoView({
        block: "end",
        behavior: prefersReducedMotion() ? "auto" : "smooth",
      });
    }, 280);
  });

  $("#confirm-cancel").onclick = closeConfirm;
  $("#confirm-backdrop").onclick = closeConfirm;
  $("#confirm-ok").onclick = submitInterrupt;

  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (!$("#confirm-sheet").classList.contains("hidden")) closeConfirm();
    else if (sheet.mode) closeSheet();
  });

  const vv = window.visualViewport;
  if (vv) {
    vv.addEventListener("resize", syncKeyboardInset);
    vv.addEventListener("scroll", syncKeyboardInset);
  }
  window.addEventListener("resize", syncKeyboardInset);
  syncKeyboardInset();

  // 回到前台时补一次快照，避免长时间息屏后显示陈旧状态。
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && (store.token || store.demo)) refresh();
  });
}

function start() {
  bindEvents();
  const codeFromQR = new URLSearchParams(location.search).get("code");

  if (store.demo) {
    store.openAgents.add("codex");
    // 演示开关也可以从地址栏来：?demo=1&stream=offline 验降级，&stream=gap 验重对齐。
    const streamMode = new URLSearchParams(location.search).get("stream");
    if (streamMode === "offline") applyDemoStreamSwitch("offline");
    enterApp();
    demoStreamBoot();
    if (streamMode === "gap") setTimeout(() => applyDemoStreamSwitch("gap"), 3000);
    return;
  }
  if (store.token) {
    enterApp();
    return;
  }
  showPairScreen();
  if (codeFromQR) {
    $("#pair-code").value = codeFromQR.replace(/\D/g, "").slice(0, 6);
    $("#pair-submit").disabled = $("#pair-code").value.length !== 6;
    if (!$("#pair-submit").disabled) submitPair();
  }
}

/* ---------------- 演示数据 ----------------
   仅在 ?demo=1 显式开启，用于无 Bridge 时预览界面。
   绝不做静默兜底：真实模式连不上就显示离线，不拿假数据糊过去。 */

function mockError(code) {
  return Promise.reject(Object.assign(new Error(code), { data: { error: code } }));
}

function cloneAgent(agent) {
  return Object.assign({}, agent, {
    capabilities: (agent.capabilities || []).slice(),
    tasks: (agent.tasks || []).map((t) => {
      const copy = Object.assign({}, t);
      if (t.stream) {
        copy.stream = {
          seq: t.stream.seq,
          live: t.stream.live,
          entries: t.stream.entries.map((e) => Object.assign({}, e)),
        };
      }
      return copy;
    }),
  });
}

function mockAdvanceCommand(cmd, extra) {
  setTimeout(() => {
    if (cmd.state === "failed") return;
    cmd.state = "running";
    cmd.updatedAtMs = Date.now();
    applyCommand(cmd);
    setTimeout(() => {
      if (extra && extra.fail) {
        cmd.state = "failed";
        cmd.errorMessage = extra.errorMessage || "Codex 没有接住这条指令";
      } else {
        cmd.state = "succeeded";
        if (extra && extra.onSuccess) extra.onSuccess(cmd);
      }
      cmd.updatedAtMs = Date.now();
      applyCommand(cmd);
      if (extra && extra.onSuccess && mockApi.state) {
        applySnapshot({
          serverTimeMs: Date.now(),
          agents: mockApi.state.agents.map(cloneAgent),
          todos: mockApi.state.todos.map((t) => Object.assign({}, t)),
          workdirs: mockApi.state.workdirs.map((w) => Object.assign({}, w)),
        });
      }
      announceCommand(cmd);
    }, 700);
  }, 400);
}

/* 演示用的实时流。文本里的路径已经写成「项目名/相对路径」和 `~`，
   跟契约「路径脱敏」那一节要求的效果一致，不给手机看真实绝对路径。 */

const DEMO_STREAM_SEED = [
  { kind: "think", text: "先看清楚 app-server 那 70 种通知里哪些值得推到手机上" },
  { kind: "plan", text: "第 2 步 / 共 5 步：把通知折叠成七种 kind",
    detail: "✓ 读 app-server 通知清单\n▶ 折叠成七种 kind\n· 250ms 限流与截断\n· 路径脱敏两层兜底\n· 手机端渲染" },
  { kind: "run", text: "rg -n \"outputDelta\" 澜台/Sources/CodexPulseAgents",
    detail: "CPCodexDriver.m:412:  if ([method isEqualToString:@\"item/commandExecution/outputDelta\"]) {\nCPCodexDriver.m:418:  if ([method isEqualToString:@\"command/exec/outputDelta\"]) {\n2 matches" },
  { kind: "say", text: "两条 outputDelta 都得接：桌面端旧版本发的是后面那条，只接一条会漏输出。" },
  { kind: "edit", text: "改了 2 个文件",
    detail: "澜台/Sources/CodexPulseAgents/CPCodexDriver.m   +86 −4\n澜台/Sources/CodexPulseBridge/CPBridgeServer.m   +31 −2" },
  { kind: "usage", text: "本轮 6,204 tokens，累计 48,213" },
  { kind: "note", text: "警告：一条 detail 超过 2000 字符，已截掉开头保留末段" },
];

const DEMO_STREAM_SCRIPT = [
  { kind: "think", text: "先确认限流之后顺序还对不对得上" },
  { kind: "run", text: "swift build --package-path 澜台 2>&1 | tail -n 20",
    detail: "…\n[142/167] Compiling CodexPulseBridge CPBridgeServer.m\n[151/167] Compiling CodexPulseAgents CPCodexDriver.m\n[160/167] Linking CodexPulse\nBuild complete! (28.41s)" },
  { kind: "say", text: "构建过了。接下来我把 250ms 的合批窗口做进去，" },
  { kind: "say", text: "同一种 kind 的连续 delta 会追加到同一条上，不会一个 token 发一条。" },
  { kind: "edit", text: "改了 澜台/Sources/CodexPulseBridge/CPBridgeServer.m",
    detail: "@@ 活动流合批\n+ 250ms 冲刷定时器\n+ kind 变化时立即冲刷\n+ 每任务保留最近 40 条" },
  { kind: "run", text: "xcrun simctl list devices booted",
    detail: "-- iOS 26.0 --\n    iPhone 17 Pro (0A1B2C3D-4E5F-6789-ABCD-EF0123456789) (Booted)" },
  { kind: "plan", text: "第 3 步 / 共 5 步：限流与截断",
    detail: "✓ 读 app-server 通知清单\n✓ 折叠成七种 kind\n▶ 250ms 限流与截断\n· 路径脱敏两层兜底\n· 手机端渲染" },
  { kind: "usage", text: "本轮 3,918 tokens，累计 52,131" },
  { kind: "note", text: "提醒：~/.codex/log 里还留着上一轮的 socket 句柄，退出时要收干净" },
  { kind: "think", text: "脱敏得在 driver 和 Bridge 各做一遍，漏一层泄的就是真实目录" },
  { kind: "run", text: "rg -n \"/Users/\" 澜台/Sources/CodexPulseBridge",
    detail: "(no matches)" },
  { kind: "say", text: "Bridge 出口这层已经干净了，driver 那边我再兜一次。" },
];

const DEMO_STREAM_SWITCHES = new Set(["offline", "live", "gap"]);

function demoStreamTask() {
  const state = mockState();
  const agent = state.agents.find((a) => a.agentID === "codex");
  const task = agent && (agent.tasks || []).find((t) => t.taskID === "t1");
  if (!task || !task.stream) return null;
  return { agent, task, stream: task.stream };
}

function demoStreamEmit() {
  const found = demoStreamTask();
  if (!found) return;
  const { agent, task, stream } = found;
  // live:false 的含义是 app-server 不在了，那就不该再冒出新条目。
  if (stream.live === false) return;

  const state = mockState();
  const shape = DEMO_STREAM_SCRIPT[state.streamCursor % DEMO_STREAM_SCRIPT.length];
  state.streamCursor += 1;
  const entry = Object.assign({}, shape, { seq: stream.seq + 1, atMs: Date.now() });
  stream.seq = entry.seq;
  stream.entries.push(entry);
  if (stream.entries.length > 40) stream.entries.shift();
  task.updatedAtMs = Date.now();

  if (state.streamHold > 0) {
    // 演示漏批：这几条只进「服务端」状态，不推给手机，制造 seq 断裂。
    state.streamHold -= 1;
    return;
  }
  applyActivity({
    agentID: agent.agentID, taskID: task.taskID,
    seq: stream.seq, live: true, entries: [entry],
  });
}

function demoStreamBoot() {
  const state = mockState();
  if (state.streamTimer) return;
  state.streamTimer = setInterval(demoStreamEmit, 1500);
}

function applyDemoStreamSwitch(kind) {
  const found = demoStreamTask();
  if (!found) return "演示流还没准备好";
  const { agent, task, stream } = found;
  const known = !!store.streams[streamKey(agent.agentID, task.taskID)];
  const push = (live) => {
    if (!known) return;
    applyActivity({
      agentID: agent.agentID, taskID: task.taskID,
      seq: stream.seq, live, entries: [],
    });
  };

  if (kind === "offline") {
    stream.live = false;
    task.activity = "落盘记录：改完 2 个文件，最后一步在跑测试";
    task.updatedAtMs = Date.now();
    push(false);
    // 真实场景里 Mac 掉了 app-server 也会顺手重推一次快照，这里照做，
    // 好让「下面是落盘后的结果」那一行确实是落盘后的内容。
    if (known) refresh();
    return "演示：app-server 断了，已收到的条目留在屏幕上，另加一句降级说明";
  }
  if (kind === "live") {
    stream.live = true;
    push(true);
    return "演示：实时流已恢复";
  }
  mockState().streamHold = 4;
  return "演示：接下来 4 条会被吞掉，手机应当发现 seq 对不上并重新拉快照";
}

function mockState() {
  if (mockApi.state) return mockApi.state;
  const now = Date.now();
  const seeded = DEMO_STREAM_SEED.map((shape, i) =>
    Object.assign({}, shape, { seq: i + 1, atMs: now - (DEMO_STREAM_SEED.length - i) * 9000 }));

  mockApi.state = {
    streamCursor: 0,
    streamHold: 0,
    streamTimer: null,
    todos: [
      { todoID: 1, title: "验证 app-server proxy 双写会不会打架", completed: false,
        agentID: null, threadID: null, createdAtMs: now - 7.2e6, updatedAtMs: now - 7.2e6 },
      { todoID: 2, title: "出门前确认 Tailscale 在手机上还登着", completed: false,
        agentID: null, threadID: null, createdAtMs: now - 3.6e6, updatedAtMs: now - 3.6e6 },
      { todoID: 3, title: "把 Bridge 端口写进文档", completed: true,
        agentID: null, threadID: null, createdAtMs: now - 8.6e7, updatedAtMs: now - 6e6 },
    ],
    nextID: 4,
    workdirs: [
      { workdirID: "8f2c1a0e-3b7d-4c11-9a55-0d2e6b8c1f40", name: "澜台" },
      { workdirID: "c3d4e5f6-a1b2-4091-8c7d-2e3f4a5b6c7d", name: "写作" },
    ],
    agents: [
      {
        agentID: "codex", name: "Codex", health: "ok", status: "working",
        displayStatus: "working", capabilities: ["observe", "control", "interrupt"],
        controlRoute: "native",
        models: [
          { modelID: "gpt-5.6-sol", name: "GPT-5.6-Sol",
            description: "Latest frontier agentic coding model.", isDefault: true },
          { modelID: "gpt-5.6-luna", name: "GPT-5.6-Luna",
            description: "Fast and affordable agentic coding model.", isDefault: false },
        ],
        tasks: [
          { taskID: "t1", title: "给澜台加手机 Bridge，先跑通只读快照", projectName: "澜台",
            sourceKind: "codex", status: "working", activity: "正在读取 CPRefreshPipeline.m",
            tokensUsed: 48213, createdAtMs: now - 5.4e6, updatedAtMs: now - 42e3,
            reviewed: false, managed: true,
            stream: { seq: seeded.length, live: true, entries: seeded } },
          // 托管但没有流：契约允许 stream 缺失，此时手机继续显示 activity。
          { taskID: "t2", title: "整理涟漪身份件的导出尺寸", projectName: "澜台",
            sourceKind: "codex", status: "completed", activity: "已生成 4 个尺寸",
            tokensUsed: 12902, createdAtMs: now - 9e7, updatedAtMs: now - 4.2e6,
            reviewed: false, managed: true, stream: null },
          { taskID: "t3", title: "修 SPM 构建在本机 SDK 下失败的问题", projectName: "scratch",
            sourceKind: "codex", status: "failed", activity: "clang: error: SDK 版本不匹配",
            tokensUsed: 3311, createdAtMs: now - 1.7e8, updatedAtMs: now - 8.6e6,
            reviewed: true, managed: false },
        ],
      },
      {
        agentID: "kimi", name: "Kimi", health: "ok", status: "waiting",
        displayStatus: "waiting", capabilities: ["observe"], controlRoute: "none",
        tasks: [
          { taskID: "k1", title: "把长文按小标题重排一遍", projectName: "写作",
            sourceKind: "kimi-client", status: "waiting", activity: "等待确认是否保留第三节",
            tokensUsed: 8120, createdAtMs: now - 2.6e6, updatedAtMs: now - 62e3,
            reviewed: false, managed: false },
        ],
      },
      {
        agentID: "kimi-cli", name: "Kimi CLI", health: "missing", status: "idle",
        displayStatus: "idle", capabilities: ["observe"], controlRoute: "none", tasks: [],
      },
    ],
    commands: [],
    opCache: {},
  };
  return mockApi.state;
}

function mockApi(path, options) {
  const now = Date.now();
  const state = mockState();
  const body = options.body ? JSON.parse(options.body) : {};
  const idMatch = path.match(/\/api\/todos\/(\d+)/);
  const cmdMatch = path.match(/^\/api\/commands\/([^/]+)$/);

  if (path === "/api/snapshot") {
    return Promise.resolve({
      serverTimeMs: now,
      agents: state.agents.map(cloneAgent),
      // 返回副本：让演示态和真实 HTTP 一样，前端拿到的永远不是服务端持有的那个数组。
      todos: state.todos.map((t) => Object.assign({}, t)),
      workdirs: state.workdirs.map((w) => Object.assign({}, w)),
    });
  }
  if (path === "/api/todos" && options.method === "POST") {
    const todo = { todoID: state.nextID++, title: body.title, completed: false,
      agentID: null, threadID: null, createdAtMs: now, updatedAtMs: now };
    state.todos.push(todo);
    return Promise.resolve({ todo: Object.assign({}, todo) });
  }
  if (idMatch && options.method === "PATCH") {
    const todo = state.todos.find((t) => t.todoID === Number(idMatch[1]));
    if (!todo) return Promise.reject(new Error("not_found"));
    if ("completed" in body) todo.completed = body.completed;
    if ("title" in body) todo.title = body.title;
    todo.updatedAtMs = now;
    return Promise.resolve({ todo: Object.assign({}, todo) });
  }
  if (idMatch && options.method === "DELETE") {
    state.todos = state.todos.filter((t) => t.todoID !== Number(idMatch[1]));
    return Promise.resolve({ ok: true });
  }
  if (path === "/api/commands" && options.method === "POST") {
    if (body.opID && state.opCache[body.opID]) {
      return Promise.resolve(state.opCache[body.opID]);
    }
    const demoKey = String(body.text || "").trim();
    const demoErr = /^demo:([a-z_]+)$/.exec(demoKey);
    // demo:offline / demo:live / demo:gap 是演示开关，不是错误码：拨一下实时流的状态。
    if (demoErr && DEMO_STREAM_SWITCHES.has(demoErr[1])) {
      const note = applyDemoStreamSwitch(demoErr[1]);
      return Promise.reject(Object.assign(new Error("demo_switch"), {
        data: { error: "demo_switch" }, demoNote: note,
      }));
    }
    if (demoErr && demoErr[1] !== "fail") return mockError(demoErr[1]);

    const action = body.action;
    if (action !== "start" && action !== "steer" && action !== "interrupt") {
      return mockError("bad_action");
    }
    const agent = state.agents.find((a) => a.agentID === body.agentID);
    if (!agent) return mockError("agent_not_found");
    if (!agentCanControl(agent) && action !== "interrupt") return mockError("driver_unavailable");
    if ((action === "steer" || action === "interrupt") && !body.taskID) return mockError("missing_task");
    if ((action === "start" || action === "steer") && !String(body.text || "").trim()) {
      return mockError("empty_text");
    }
    if (action === "start" && !body.workdirID) return mockError("missing_workdir");
    if (action === "start" && !state.workdirs.some((w) => w.workdirID === body.workdirID)) {
      return mockError("unknown_workdir");
    }
    if (action === "start" && body.modelID) {
      const models = Array.isArray(agent.models) ? agent.models : [];
      if (!models.some((m) => m.modelID === body.modelID)) return mockError("unknown_model");
    }
    if (action === "steer" || action === "interrupt") {
      const task = (agent.tasks || []).find((t) => t.taskID === body.taskID);
      if (!task || task.managed !== true) return mockError("not_managed");
    }
    if (action !== "interrupt") {
      const busy = state.commands.some((c) =>
        c.agentID === body.agentID && (c.state === "accepted" || c.state === "running"));
      if (busy) return mockError("busy");
    }

    const cmd = {
      commandID: uuid(),
      state: "accepted",
      action,
      agentID: body.agentID,
      taskID: action === "start" ? null : body.taskID,
      acceptedAtMs: now,
      updatedAtMs: now,
    };
    state.commands.push(cmd);
    const result = { command: Object.assign({}, cmd) };
    if (body.opID) state.opCache[body.opID] = result;

    const workdir = state.workdirs.find((w) => w.workdirID === body.workdirID);
    mockAdvanceCommand(cmd, {
      fail: demoErr && demoErr[1] === "fail",
      onSuccess: (live) => {
        if (action === "start") {
          const taskID = `demo-${uuid()}`;
          live.taskID = taskID;
          agent.tasks.unshift({
            taskID,
            title: String(body.text || "").trim().split("\n")[0].slice(0, 40) || "未命名任务",
            projectName: workdir ? workdir.name : "",
            sourceKind: "codex",
            status: "working",
            activity: "已接到新指令",
            tokensUsed: 0,
            createdAtMs: Date.now(),
            updatedAtMs: Date.now(),
            reviewed: false,
            managed: true,
          });
          agent.status = "working";
          agent.displayStatus = "working";
        } else if (action === "steer") {
          const task = (agent.tasks || []).find((t) => t.taskID === body.taskID);
          if (task) {
            task.activity = "已接到补充指令";
            task.updatedAtMs = Date.now();
          }
        } else if (action === "interrupt") {
          const task = (agent.tasks || []).find((t) => t.taskID === body.taskID);
          if (task) {
            task.activity = "已接到打断";
            task.updatedAtMs = Date.now();
          }
        }
      },
    });
    return Promise.resolve(result);
  }
  if (cmdMatch) {
    const cmd = state.commands.find((c) => c.commandID === cmdMatch[1]);
    if (!cmd) return Promise.reject(new Error("not_found"));
    return Promise.resolve({ command: Object.assign({}, cmd) });
  }
  return Promise.reject(new Error("mock_unsupported"));
}

start();
