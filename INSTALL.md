# Installing Magenta Jam AUv3

## 1. Build and deploy

Follow [README.md](README.md). The `deploy_jam_au` target copies the host app to:

```
~/Applications/Magenta Jam (AU).app
```

## 2. Register the extension

Open the host app **once**. It shows a confirmation dialog and exits. This registers the embedded `Jam_AU.appex` with macOS.

Alternatively:

```bash
pluginkit -a ~/Applications/Magenta\ Jam\ \(AU\).app/Contents/PlugIns/Jam_AU.appex
killall -9 AudioComponentRegistrar 2>/dev/null || true
```

## 3. Use in your DAW

| DAW | Steps |
|-----|-------|
| **Logic Pro** | Software Instrument track → Plug-in slot → **AU Instruments → AudioHacking: Magenta Jam** |
| **Ableton Live** | MIDI track → Plug-ins → **AudioHacking: Magenta Jam** |
| **GarageBand** | Software Instrument → Smart Controls → Plug-ins |

## 4. Models and resources

On first launch the UI guides you through downloading shared Magenta assets. Models are stored in:

```
~/Documents/Magenta/magenta-rt-v2/
```

You can reuse models downloaded for MRT2 or the Jam standalone app.

## 5. Requirements

- **macOS 14+**
- **Apple Silicon** recommended (MLX/Metal inference)
- Host project sample rate **48 kHz** (non-48 kHz hosts are resampled on output)
- MIDI from the DAW routes to the instrument; the plugin UI also supports computer-keyboard MIDI when focused

## Troubleshooting

- Plugin not visible: re-run the host app or `pluginkit -m -v -i com.audiohacking.jam.au`.
- Sandbox file access: grant folder access when prompted for custom model directories.
- Rebuild after submodule updates: `git submodule update --remote magenta-realtime && cmake --build build --target deploy_jam_au`.
