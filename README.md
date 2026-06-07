# Magenta Jam AUv3

AUv3 instrument plugin wrapping the [Magenta RealTime Jam](https://github.com/magenta/magenta-realtime/tree/main/examples/jam) experience for use inside DAWs.

Built with the same CMake + Magenta framework patterns as [mrt2-au3](https://github.com/audiohacking/mrt2-au3).

## Prerequisites

- macOS 14+
- Full Xcode (Metal compiler required)
- Node.js 20+
- Python 3.12 + [uv](https://github.com/astral-sh/uv)

## Quick start

```bash
git clone --recurse-submodules https://github.com/audiohacking/jam-au3.git
cd jam-au3
uv venv --python 3.12 && source .venv/bin/activate
uv pip install "cmake<3.28"
cmake . -B build
cmake --build build --target deploy_jam_au -j10
```

Open `~/Applications/Magenta Jam (AU).app` once to register the extension, then insert **AudioHacking: Magenta Jam** as an Instrument in your DAW.

Models and shared resources live under `~/Documents/Magenta/magenta-rt-v2/` (same as MRT2/Jam standalone).

See [INSTALL.md](INSTALL.md) for DAW setup and [AGENT.md](AGENT.md) for development continuation guide.

## Dev UI (HMR)

```bash
npm install
npm run dev --workspace=jam-ui   # Vite on port 62421
```

Rebuild/redeploy the AU extension; when the dev server is running, the plugin UI loads from localhost with hot reload.

## License

Apache 2.0 (Magenta components). See upstream [magenta-realtime](https://github.com/magenta/magenta-realtime).
