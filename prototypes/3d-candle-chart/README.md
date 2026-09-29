# 3D Candle Chart Prototype

Interactive **Time × Price × Volume** candlestick chart.

Traditional OHLC candles gain a Z-axis depth driven by volume. From the front it reads like a normal TradingView chart; rotate the scene and volume thickness appears.

## Run

Needs a static HTTP server (ES modules + import map):

```bash
cd prototypes/3d-candle-chart
python3 -m http.server 5173
```

Open `http://localhost:5173`.

Or from the repo root:

```bash
python3 -m http.server 5173 --directory prototypes/3d-candle-chart
```

## Controls

| Input | Action |
| --- | --- |
| Left drag / one-finger drag | Rotate |
| Scroll / pinch | Zoom |
| Right drag / two-finger pan | Pan |
| Hover | Highlight + OHLC / Vol / RVOL tooltip |
| Click | Keep selection |

Toolbar: **Front** · **Side** · **3D** · **Ortho / Persp** · **Volume Scale** · **Reset**

## Project layout

```
prototypes/3d-candle-chart/
├── index.html          # Shell + toolbar
├── css/styles.css      # Dark trading UI
├── js/
│   ├── main.js         # Boot, render loop, UI wiring
│   ├── data.js         # Mock OHLCV + normalizeOHLCV()
│   ├── volume.js       # Linear / Log / Relative depth
│   ├── candles.js      # 3D body + wick meshes
│   ├── scene.js        # Lights, axes, grid
│   ├── camera.js       # Ortho/Persp + view presets
│   └── interaction.js  # Raycasting hover / click
└── README.md
```

## Coordinate model

| Axis | Meaning | Geometry |
| --- | --- | --- |
| X | Time | Candle index × gap |
| Y | Price | Open/High/Low/Close scaled |
| Z | Volume | Depth into −Z (behind the front plane) |

Each candle = `BoxGeometry` body (O–C) + thinner wick (H–L), sharing volume depth.

## Volume depth modes

- **Relative** (default): `volume / SMA(volume, 20)` → RVOL
- **Linear**: `volume / mean(volume)`
- **Log**: `log1p(volume) / log1p(mean)`

Factors are soft-clamped so extreme prints stay readable.

## Plug in real OHLCV

Data shape:

```js
[
  { time: 1717407000000, open: 102, high: 108, low: 99, close: 106, volume: 1500000 },
  // ...
]
```

`time` may be epoch ms or an ISO string.

In `js/main.js`, replace `loadSeries()`:

```js
import { normalizeOHLCV } from "./data.js";

async function loadSeries() {
  const res = await fetch("https://your-api/ohlcv?symbol=BTCUSDT&interval=15m");
  return normalizeOHLCV(await res.json());
}
```

Or drop a static JSON next to the app and `fetch("./btc-15m.json")`.

`normalizeOHLCV()` validates numbers and fixes high/low vs open/close.

## Stack

- HTML / CSS / vanilla JS
- [Three.js](https://threejs.org/) r170 (CDN import map)
- `OrbitControls` for desktop + touch

No React / build step for this MVP.
