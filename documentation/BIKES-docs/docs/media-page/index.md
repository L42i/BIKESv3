# Media

All audio and image assets live in the `media/` folder at the root of the BIKES project. Each concept has its own named subfolder — nothing is shared between concepts. When `sync_folder.yml` runs, the entire `media/` tree is pushed to `~/Desktop/BIKES/media/` on every bike.

---

## Structure

The tree below shows the current concepts as an example — the pattern is what matters: one subfolder per concept, named to match. New concepts follow the same convention by adding a new named folder here.

```
media/
├── GranSynth/
│   ├── AtmosphericC2.wav       # host (bikes1) timbre
│   ├── BassSoundC1.wav         # bikes2 timbre
│   ├── StringSound1.wav        # bikes3 timbre
│   └── PadSoundC4.wav          # bikes4 timbre
│
├── Latency_delay/
│   └── bell.wav                # relayed bell sample
│
├── soundscapes/
│   ├── images/
│   │   ├── <theme>Pixel.jpg    # pixelated background for GUI
│   │   └── <theme>.jpg         # overlay image revealed on tap
│   └── samples/
│       └── <theme>/
│           ├── base/
│           │   └── 0.wav       # looping base track
│           ├── soundmark/
│           │   └── 0–3.wav
│           └── signal/
│               └── 0–3.wav
│
├── timesync/
│   └── 1.wav                   # stem played simultaneously on all nodes
│
└── uwb/
    ├── words/
    │   └── 1–4.wav             # one word sample per node
    ├── birds/
    │   └── 1–4.wav             # one bird sample per node
    └── alphabet/
        └── A–Z.wav             # one file per letter
```

---

## Specific Notes

**Soundscapes themes** — the `soundscapes/` subfolder is theme-driven. The theme name (e.g. `marine`, `rainforest`) is passed as a command-line argument at runtime and used to resolve both image and sample paths. Adding a new theme means adding a matching folder under `samples/` and two images under `images/`.

**Node-specific files** — in `GranSynth/` and `uwb/words/` and `uwb/birds/`, files are numbered 1–4 to match the bike slot. Each node loads only its own file; all files still need to be present on all nodes since `sync_folder.yml` mirrors the full tree everywhere.
