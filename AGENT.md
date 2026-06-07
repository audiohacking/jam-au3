# AGENT.md — Magenta Jam AUv3 Development Guide

This document is the continuation guide for AI agents or developers picking up work on **jam-au3** in a new session. It describes architecture, build patterns, conventions, and known gaps relative to the reference **mrt2-au3** fork and upstream **magenta-realtime** Jam example.

---

## 1. Project purpose

**jam-au3** is an AUv3 **Instrument** (`aumu`) plugin that brings the Magenta RealTime **Jam** UI and behavior into DAW hosts. It is intentionally parallel to [audiohacking/mrt2-au3](https://github.com/audiohacking/mrt2-au3) but targets the simplified Jam experience (single prompt, presets, solo/accompany modes) instead of the full MRT2 multi-prompt surface.

| Reference | Role |
|-----------|------|
| `mrt2-au3` | AUv3 build/deploy/CI patterns (do not modify that repo when working here) |
| `magenta-realtime/examples/jam` | Standalone Jam app + React UI source of truth |
| `magenta-realtime/examples/mrt2/auv3` | Upstream AU processor baseline |
| `mrt2-au3` (fork) | FX mode, sidechain, extended state — **not** ported to Jam AU |

---

## 2. Repository layout

```
jam-au3/
├── CMakeLists.txt              # Root build (mirrors mrt2-au3 targets, renamed)
├── package.json                # npm workspaces: jam-ui + @magenta-rt/common
├── .gitmodules                 # magenta-realtime submodule
│
├── Jam_AudioUnit.h             # JamAudioUnit processor + JamViewController decl
├── Jam_AudioUnit.mm            # AUAudioUnit processor (engine, render, state)
├── Jam_ViewController.mm       # AUViewController factory + WKWebView UI bridge
├── Jam_SharedState.h           # MIDI note + audio level shared state
├── Jam_AUHostApp.mm            # Minimal host app for pluginkit registration
│
├── Info.plist.in               # AU extension (.appex) — subtype JAM3, mfg AHck
├── HostInfo.plist.in           # Host app plist
├── Entitlements.plist          # Sandbox entitlements for .appex
│
├── assets/AppIcon.icns           # Copied from magenta-realtime common assets
├── scripts/                    # pkg-postinstall, ci-reclaim-disk (from mrt2-au3)
├── .github/                    # CI workflow + setup-build action
│
├── README.md / INSTALL.md      # User docs
└── AGENT.md                    # This file
```

**Submodule (required):**

```
magenta-realtime/
├── core/                       # magentart::core — RealtimeRunner, MLX inference
├── examples/common/            # magenta_paths, MagentaModelManager, MagentaSettings
└── examples/jam/ui/            # Jam React UI (built into .appex Resources/jam_ui/)
```

---

## 3. Two-bundle AUv3 pattern (same as mrt2-au3)

```
Magenta Jam (AU).app/                    # Host app — open once to register
└── Contents/PlugIns/
    └── Jam_AU.appex/                    # Actual AUv3 extension
        └── Contents/
            ├── MacOS/Jam_AU             # Entry: -e _NSExtensionMain
            ├── MacOS/mlx.metallib       # MLX Metal kernels (codesigned separately)
            └── Resources/jam_ui/        # Single-file Vite bundle (index.html)
```

**CMake target chain:**

| Target | Purpose |
|--------|---------|
| `npm_install_root` | `npm install` at repo root |
| `build_jam_ui` | `npm run build --workspace=jam-ui` |
| `jam_au` | Extension executable → `Jam_AU.appex` |
| `jam_au_app` | Host app → `Magenta Jam (AU).app` |
| `finalize_jam_au` | Embed appex + UI + metallib; codesign |
| `deploy_jam_au` | Copy to `~/Applications`, `pluginkit -a` |
| `package_jam_au` | Stage `build/dist/` for release |

---

## 4. Audio component registration

From `Info.plist.in`:

| Field | Value |
|-------|-------|
| type | `aumu` (Music Device / Instrument) |
| subtype | `JAM3` |
| manufacturer | `AHck` (AudioHacking) |
| name | `AudioHacking: Magenta Jam` |
| factoryFunction | `JamViewController` |
| bundle ID | `com.audiohacking.jam.au` |

Fallback init in `Jam_AudioUnit.mm` must match plist subtype/manufacturer (`JAM3` / `AHck`).

---

## 5. Class responsibilities

### `JamAudioUnit` (`Jam_AudioUnit.mm`)

- Subclasses `AUAudioUnit`
- Owns `RealtimeRunner _engine`
- **Instrument only** — stereo output @ 48 kHz, no audio input buses
- AU parameter tree addresses 0–48 (same engine params as MRT2/Jam standalone)
- **Jam-specific render logic** (ported from `JamApp.mm`):
  - `_soloMode`, `_gateLevel`, `_gateDecaySeconds`
  - `_cfgNotesSliderValue`, `_cfgNotesCurrentLevel`
  - Solo-mode volume gate + cfg-notes ramp in `internalRenderBlock`
- MIDI from host via `AURenderEventMIDI` → `_sharedState.midiNotes`
- DAW transport via cached `transportStateBlock` (same pattern as mrt2 auv3)
- State keys prefixed `JAM_*` (not `MGRT_*`):
  - `JAM_Prompt`, `JAM_ModelName`, `JAM_ModelBookmark`, `JAM_SoloMode`
- Method `applyPromptTextToEngine:` applies SOLO prefix when in solo mode

### `JamViewController` (`Jam_ViewController.mm`)

- Subclasses `AUViewController`, implements `AUAudioUnitFactory`
- `createAudioUnitWithComponentDescription:` → `JamAudioUnit`
- Hosts Jam React UI in `WKWebView`
- **Adapted from** `JamAppController.mm` with AU differences:
  - Engine access via `[self jamAU] engine]`
  - `togglePlay` sets `au.uiPlaying` + `engine->set_bypass()` (no NSApp menu)
  - `selectMidiSource` stubbed — DAW provides MIDI; UI computer keyboard via `kbdNote`
  - No CoreMIDI input port management
- Dev server: port **62421** (Jam UI vite config)
- Production UI: `Resources/jam_ui/index.html` in extension bundle

### UI ↔ Native bridge

Same contract as Jam standalone:

**Native → JS:** `window.updateState({...})` at ~25 Hz

**JS → Native:** `window.webkit.messageHandlers.auHost.postMessage({type, ...})`

Key message types: `param`, `textPrompts`, `setSoloMode`, `loadModel`, `selectModel`, `downloadModel`, `initResources`, `kbdNote`, `togglePlay`, `uiReady`, etc.

Injected at document start: `window.__HOST_MODE__ = 'auv3'`

---

## 6. Build commands

### First-time / clean build

```bash
git submodule update --init --recursive
uv venv --python 3.12 && source .venv/bin/activate
uv pip install "cmake<3.28"
npm install
cmake . -B build
cmake --build build --target deploy_jam_au -j$(sysctl -n hw.ncpu)
```

### UI development with HMR

Terminal 1:
```bash
npm run dev --workspace=jam-ui   # localhost:62421
```

Terminal 2: rebuild extension only (faster iteration):
```bash
cmake --build build --target finalize_jam_au -j10
# Re-insert plugin in DAW or restart host
```

### Release staging

```bash
cmake --build build --target package_jam_au
# Output: build/dist/Magenta Jam (AU).app
```

### Codesigning / notarization

Same env vars as mrt2-au3:
- `MAGENTART_DEVELOPER_ID` — Developer ID Application identity
- `notarize_jam_au` target (requires non-ad-hoc signing)

---

## 7. External runtime dependencies (not bundled)

| Resource | Default path |
|----------|--------------|
| Models | `~/Documents/Magenta/magenta-rt-v2/` |
| Shared resources (musiccoca, tokenizer) | `~/Documents/Magenta/magenta-rt-v2/resources/` |

Models are **not** shipped in the app bundle. UI onboarding (`initResources`) downloads via `MagentaModelDownloader`.

---

## 8. FetchContent dependencies (CMake)

Identical pins to mrt2-au3:

- **MLX** `v0.31.1`
- **sentencepiece** `v0.2.0`
- **tensorflow-lite** `v2.21.0`

Includes MLX `make_compiled_preamble.sh` patch for CMake compatibility.

---

## 9. CI

`.github/workflows/build.yml` runs on `macos-14`:
1. Checkout + submodules
2. `setup-build` action (Node, ccache, uv, cmake, npm, UI build)
3. `cmake --build build --target finalize_jam_au`

Cache key paths: `Jam_AudioUnit.mm`, `Jam_ViewController.mm`, `magenta-realtime/core/**`

---

## 10. Known gaps / TODO for future sessions

Priority items if continuing development:

### High priority

1. **Verify full compile on clean machine** — first build fetches MLX/TF Lite (~long). Confirm no missing imports in `Jam_ViewController.mm` (e.g. `AudioToolbox` for `ExtAudioFile` in audio prompt loader).

2. **AU parameter ↔ UI sync** — `applyParamToEngine` writes to `AUParameterTree`; confirm DAW automation round-trips for all Jam-exposed params (addresses 0,1,3,4,5,6,7,8,9,32,39,46,48).

3. **DAW transport vs Jam `togglePlay`** — Currently merges host transport + `uiPlaying`. Jam standalone uses explicit play/stop with bypass. Test Logic/Ableton: ensure audio plays when DAW transport runs even if UI play button is off.

4. **`textPrompts` → `JAM_Prompt` state** — Confirm DAW project save/restore persists prompt via `fullState`.

### Medium priority

5. **Settings panel in AU** — Standalone Jam has `JamSettingsController` (Cmd+,). AU sends `openSettings: @YES` to React only; verify SettingsPanel works in `@magenta-rt/common` without native settings window.

6. **Release workflow** — `.github/workflows/release.yml` + `scripts/build-installer-pkg.sh` produce `Jam-AU3-*-macOS-{Installer.pkg,dmg}`. Trigger via GitHub Release publish or **Actions → Release → Run workflow**.

7. **PLUGIN.md** — Optional user-facing doc for Jam-specific preset/state semantics (like mrt2-au3 PLUGIN.md).

### Low priority / nice-to-have

8. **FX mode** — Not applicable to Jam; do not port from mrt2-au3 fork unless product direction changes.

9. **Debug logging** — Build with `-DMAGENTART_DEBUG_LOG=ON` (mirror mrt2-au3 overlay).

10. **Component validation** — Run `auvaltool -v aumu JAM3 AHck` after deploy.

---

## 11. Naming conventions (do not mix)

| Item | Jam AU | MRT2 AU (reference) |
|------|--------|---------------------|
| State prefix | `JAM_*` | `MGRT_*` |
| NSUserDefaults params | `Jam_Param_*`, `Jam_Prompt` | `MagentaRT_AU_*` |
| Dev server port | 62421 | 62420 |
| UI resource dir | `jam_ui/` | `ui/` |
| CMake prefix | `jam_au` | `mrt2_au` |
| Host app name | `Magenta Jam (AU).app` | `MRT2 (AU).app` |

---

## 12. Submodule updates

```bash
cd magenta-realtime
git fetch origin && git checkout main && git pull
cd ..
git add magenta-realtime
# commit submodule pointer when ready
cmake --build build --target deploy_jam_au -j10
```

If upstream changes `JamAppController.mm` IPC protocol, merge into `Jam_ViewController.mm` manually — files are related but not identical.

---

## 13. Testing checklist

- [ ] Host app opens and registers extension (`pluginkit -m -v -i com.audiohacking.jam.au`)
- [ ] Plugin appears as Instrument in Logic Pro
- [ ] Onboarding downloads resources
- [ ] Model load + generation at 48 kHz
- [ ] MIDI from DAW piano roll triggers notes
- [ ] Computer keyboard MIDI in UI (when web view focused)
- [ ] Solo mode gate/decay behaves like standalone Jam
- [ ] Preset rocker + user presets persist across sessions
- [ ] Project save/reload in DAW restores plugin state

---

## 14. Important files quick reference

| Purpose | Path |
|---------|------|
| Processor | `Jam_AudioUnit.mm` |
| UI bridge | `Jam_ViewController.mm` |
| Upstream Jam UI | `magenta-realtime/examples/jam/ui/src/App.tsx` |
| Upstream Jam controller | `magenta-realtime/examples/jam/JamAppController.mm` |
| Upstream AU baseline | `magenta-realtime/examples/mrt2/auv3/MagentaRT_AudioUnit.mm` |
| mrt2-au3 reference | `../mrt2-au3/` (read-only) |
| Build root | `CMakeLists.txt` |
| Extension plist | `Info.plist.in` |

---

## 15. Session handoff notes (initial scaffold)

**Created:** 2026-06-07

**Status at handoff:**
- Repo cloned to `/Volumes/Fanxi/git/jam-au3`
- `magenta-realtime` submodule initialized
- CMake/npm/CI scaffold complete
- Processor + ViewController ported from upstream AU + Jam standalone
- **Full MLX build not verified in this session** — run `deploy_jam_au` locally to confirm

**Do not modify** `/Volumes/Fanxi/git/mrt2-au3` when continuing Jam AU work.

**Suggested first command in new session:**
```bash
cd /Volumes/Fanxi/git/jam-au3 && source .venv/bin/activate 2>/dev/null || (uv venv --python 3.12 && source .venv/bin/activate && uv pip install "cmake<3.28") && cmake --build build --target deploy_jam_au -j10 2>&1 | tee build.log
```

Review `build.log` for compile errors in `Jam_ViewController.mm` / `Jam_AudioUnit.mm` first.
