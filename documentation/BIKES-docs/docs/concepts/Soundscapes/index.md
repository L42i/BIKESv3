# Soundscapes

The soundscapes system is a networked, interactive audio installation running across a cluster of Raspberry Pi nodes (referred to as "bikes"). Each node runs a synchronized audio engine in SuperCollider, a touch-triggered pixel GUI in Python, and a peer-to-peer sound propagation layer (P2PSC). The whole stack is deployed and orchestrated via Ansible.

---

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│                  Each Node                  │
│                                             │
│  PixelGUI.py  ──OSC──▶  GUIListener.scd    │
│  (Pygame UI)             (SuperCollider)    │
│                               │             │
│                          P2PSC mesh         │
│                         (peer nodes)        │
└─────────────────────────────────────────────┘
```

- **PixelGUI.py** — fullscreen 5×3 grid UI. Detects touch/click on cells and sends OSC messages to SuperCollider.
- **GUIListener.scd** — SuperCollider script that boots the audio server, plays a looping base track, listens for OSC grid events, and triggers sound effects or propagates events across the P2PSC mesh.
- **soundscapes.yml** — Ansible playbook that deploys and starts the full stack on all nodes.

---

## Components

### PixelGUI.py

A fullscreen Pygame application that renders a 5-column × 3-row grid over a "pixelated" background image. When a cell is tapped or clicked:

1. The cell's grid coordinates `(x, y)` are sent as an OSC message to `127.0.0.1:57120` on the `/grid` address.
2. The tapped cell visually swaps to a second overlay image for 2 seconds, then reverts.

The soundscape theme (e.g. `marine`, `rainforest`) is passed as a command-line argument and used to load the matching background and overlay images from `media/soundscapes/images/`.

### GUIListener.scd

SuperCollider script that does the following on boot:

**Base track playback**

Loads `media/soundscapes/samples/<soundscape>/base/0.wav` into a buffer and plays it in a continuous loop, synchronized to an [Ableton Link](https://www.ableton.com/en/link/) clock at a fixed tempo (4.13 BPM). Mono and stereo buffers are handled automatically.

**OSC grid listener**

Listens on `/grid` for `[x, y]` messages from the GUI. Each cell maps to a sound behavior:

| Cell(s) | Behavior |
|---|---|
| `(0,0)`, `(2,0)`, `(4,1)` | `rSoundReverb` — plays a sample with delay, reverb, and soft-clipping distortion |
| `(1,1)`, `(2,2)`, `(4,2)` | `rSound` — plays a sample with no processing |
| `(1,0)`, `(3,0)` | `rSoundPitch` — plays a sample pitch-shifted up one octave |
| `(4,0)` | `rSoundBitcrush` — plays a sample with bitcrushing, pitch shift, LPF, and reverb |
| `(0,1)`, `(1,2)`, `(2,1)`, `(3,1)`, `(3,2)`, `(0,2)` | `pathTrigger` — propagates a sound event to peer nodes via P2PSC |

**Sample selection**

Each sound function randomly picks a file from either the `soundmark/` or `signal/` subfolder (80%/20% weighted), numbered 0–3.

**P2PSC mesh propagation**

The script determines the node's identity (`bikes1`–`bikes4`) by running `whoami`, then sets up a ring topology (1→2→3→4→1). When `pathTrigger` fires, it sends a sound file path and a routing pattern string to the next peer via P2PSC. Each node plays the received sample and forwards the message along the pattern until it's exhausted. The routing pattern is either the fixed sequence `"1234"` or a randomly generated non-repeating string of 3–6 peer IDs.

### soundscapes.yml

An Ansible playbook targeting the `bikes` host group. It:

1. Kills any existing instances of `sclang`, `scsynth`, `jacktrip`, `jackd`, `qjackctl`, `p2psc`, and `python3`.
2. Starts JACK audio (`jackd -d alsa -d hw:2,0`).
3. Starts the P2PSC daemon.
4. Launches `GUIListener.scd` via `sclang`, passing the soundscape name as an argument.
5. Waits for `scsynth` to appear before continuing.
6. Launches `PixelGUI.py` via `python3`, also passing the soundscape name.

The `soundscape` variable (default: `rainforest`) can be overridden at run time.

---

## File & Media Layout

```
concepts/soundscapes/
├── GUIListener.scd
├── PixelGUI.py
└── soundscapes.yml

media/soundscapes/
├── images/
│   ├── <soundscape>Pixel.jpg   # pixelated background for GUI
│   └── <soundscape>.jpg        # overlay revealed on tap
└── samples/
    └── <soundscape>/
        ├── base/
        │   └── 0.wav           # looping base track
        ├── soundmark/
        │   ├── 0.wav … 3.wav
        └── signal/
            ├── 0.wav … 3.wav
```

---

## Running

The recommended way to start the system is via Ansible:

```bash
ansible-playbook -k -i ./utility/config/bikes.ini concepts/soundscapes/soundscapes.yml -e soundscape="marine"
```

To run a single node manually:

```bash
# Terminal 1 — SuperCollider
sclang GUIListener.scd marine

# Terminal 2 — GUI (after scsynth is up)
python3 PixelGUI.py marine
```

---

## Dependencies

| Component | Dependency |
|---|---|
| Audio engine | SuperCollider (`sclang`, `scsynth`) |
| Audio routing | JACK (`jackd`) |
| Network audio | JackTrip, P2PSC |
| GUI | Python 3, Pygame, python-osc |
| Deployment | Ansible |
