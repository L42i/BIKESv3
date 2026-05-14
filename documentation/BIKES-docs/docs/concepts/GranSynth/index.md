# Granular Synth

GranSynth is a networked granular synthesizer spread across four nodes. One node acts as the **host**, controlling chord selection via a fullscreen GUI. The chord state is broadcast over P2PSC to the three **receiver** nodes, each of which plays its own timbre from a different audio sample. Receiver nodes also have their own GUI — a four-button voice pad — that lets the rider select individual chord tones to play locally. All nodes use the same granular SynthDef, pitched in real time by computing the MIDI ratio for each scale degree.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                     HOST (bikes1)                       │
│                                                         │
│  PythonHost.py  ──/chord──▶  GranSynthHostFinal.scd    │
│  (chord grid UI)              (granular synth + P2PSC)  │
│                                    │                    │
│                         P2PSC /remoteChord              │
│                    ┌────────┬──────┴──────┐             │
└────────────────────┼────────┼─────────────┼─────────────┘
                     ▼        ▼             ▼
              bikes2        bikes3        bikes4
         ┌──────────────────────────────────────┐
         │  GranSynthReceiverForBike.scd         │
         │   ├─ updates chord state             │
         │   ├─ forwards /remoteChord to        │
         │   │  PythonReceiver.py (port 57121)  │
         │   └─ plays note on /localChord       │
         │                                      │
         │  PythonReceiver.py                   │
         │   ├─ shows voice pad UI              │
         │   └─ sends /localChord on tap        │
         └──────────────────────────────────────┘
```

---

## Roles

### Host node (bikes1)

Runs `PythonHost.py` + `GranSynthHostFinal.scd`. The host is the only node that can change the root note, scale, and chord degree. Its choices are pushed to all other nodes.

### Receiver nodes (bikes2–4)

Run `PythonReceiver.py` + `GranSynthReceiverForBike.scd`. Each receiver has a fixed timbre (different sample file) and the same granular engine. Riders choose which chord voice to play from a local four-button pad; the chord context (root, scale, degree) arrives passively from the host.

---

## Components

### PythonHost.py

A fullscreen Pygame GUI with three sections:

**Root note buttons (left column)** — 12 buttons, one per chromatic pitch (C through B). Tapping one sets the root of the current chord.

**Scale buttons (right column)** — four buttons: Major, Minor, Dorian, Mixolydian.

**Chord pads (centre grid)** — a 3×2 grid of six pads, one per diatonic scale degree (I–VI). Each pad displays:

- Roman numeral (I–VI) in the top-left corner
- The actual note name in large type at the centre
- The chord quality (maj / min / dim) at the bottom
- A keyboard shortcut number (1–6) in the top-right corner

Tapping a pad sends `/chord [root, scale, degree]` to SuperCollider on port 57120. Tapping an already-active pad sends degree `0` (stop). The scale and root context updates live as the rider changes them, without re-triggering the pad.

### GranSynthHostFinal.scd

SuperCollider script for the host. On boot it:

1. Loads `media/GranSynth/AtmosphericC2.wav` (left channel only) into a buffer.
2. Registers the `\gs` granular SynthDef (see [Granular SynthDef](#granular-synthdef) below).
3. Connects to P2PSC as node `"1"`.

**`/chord` OSC handler**

When a `/chord [root, scale, degree]` message arrives from the local Python GUI:

- If `degree > 0`: computes the pitch ratio for that scale degree relative to MIDI note 36 (C2), then starts or updates `~activeSynth` with the new `\rate`.
- If `degree == 0`: gates off `~activeSynth`.
- Broadcasts `/remoteChord [root, scale, degree]` to nodes `"2"`, `"3"`, and `"4"` via P2PSC.

### PythonReceiver.py

A fullscreen Pygame GUI with two sections:

**Status bar (top)** — shows the current root, scale name, and degree received from the host, with a live indicator dot.

**Voice pad (2×2 grid)** — four buttons labelled ROOT, 3RD, 5TH, 7TH. Each displays the actual note name for that chord voice, computed from the current chord context. Tapping a pad:

- Sends `/localChord [buttonIdx, 1]` to SuperCollider on port 57120.
- If another pad was already active, sends `/localChord [prevIdx, 0]` first (only one voice at a time).

The receiver listens on port 57121 for incoming `/remoteChord` messages from SuperCollider and updates the displayed notes accordingly without triggering any sound itself.

### GranSynthReceiverForBike.scd

SuperCollider script for receiver nodes. On boot it:

1. Detects the node's hostname via `whoami` and assigns identity, sample file, and root MIDI note:

| Hostname | Node | Sample file | Root MIDI |
|---|---|---|---|
| bikes2 | 2 | `BassSoundC1.wav` | 26 (C1) |
| bikes3 | 3 | `StringSound1.wav` | 60 (C4) |
| bikes4 | 4 | `PadSoundC4.wav` | 60 (C4) |

2. Loads the node's sample (left channel only) into a buffer.
3. Sets `~pygameAddr` to the local machine's IP on port 57121 (10.10.10.12–14 for nodes 2–4).
4. Registers the `\gs` granular SynthDef.
5. Connects to P2PSC under the node's identity.

**`/remoteChord` P2PSC handler**

On receipt, the script:
- Updates `~currentRoot`, `~currentScale`, and `~currentDegree` in local state — no sound is triggered here.
- Forwards `/remoteChord [root, scale, degree]` to the local `PythonReceiver.py` via direct UDP so the voice pad display updates.

**`/localChord` OSC handler**

When `PythonReceiver.py` sends `/localChord [buttonIdx, isOn]`:
- If `isOn == 1`: computes the pitch ratio for the button's chord voice (using a `[0, 2, 4, 6]` voicing offset from `~currentDegree`), starts or replaces `~localSynth`.
- If `isOn == 0`: gates off `~localSynth`.

---

## Granular SynthDef (`\gs`)

Shared between host and receiver scripts. Key parameters:

| Parameter | Default | Description |
|---|---|---|
| `dens` | 60 | Grain density (grains/sec). Trigger mode: Dust (async) or Impulse (sync), selected by `sync` |
| `dur` | 0.4 | Grain duration (seconds), modulated by `LFNoise1` within `durRand` range |
| `pos` | 0.1 | Playback start position (0–1) within buffer |
| `posSpeed` | 0.1 | Speed of `Phasor` scanning through the buffer |
| `posRand` | 0.05 | Random scatter added to grain position |
| `rate` | 1.0 | Playback rate (pitch ratio); set per note |
| `pan` / `panRand` | 0 / 0 | Stereo pan centre and random spread |
| `atk` / `rel` | 0.5 / 2 | ASR envelope attack and release |
| `amp` | 0.3 | Output amplitude |
| `grainEnv` | -1 | Grain envelope shape (-1 = Hann window) |

All instances are started with density 200, grain duration 0.07 s, and position 0.1.

---

## File & Media Layout

```
concepts/GranSynth/
├── GranSynthHostFinal.scd
├── GranSynthReceiverForBike.scd
├── PythonHost.py
├── PythonReceiver.py
└── runGranSynth.yml

media/GranSynth/
├── AtmosphericC2.wav     # host timbre
├── BassSoundC1.wav       # bikes2 timbre
├── StringSound1.wav      # bikes3 timbre
└── PadSoundC4.wav        # bikes4 timbre
```

---

## Network Addresses

| Node | Hostname | Python receiver port |
|---|---|---|
| bikes2 | 10.10.10.12 | 57121 |
| bikes3 | 10.10.10.13 | 57121 |
| bikes4 | 10.10.10.14 | 57121 |

SuperCollider on all nodes listens on port 57120. Python receivers listen on 57121.

---

## Running

Deploy to all nodes via Ansible:

```bash
ansible-playbook -k -i ./utility/config/bikes.ini concepts/GranSynth/runGranSynth.yml
```

The playbook automatically runs `PythonHost.py` + `GranSynthHostFinal.scd` on the first bike in the `bikes` group, and `PythonReceiver.py` + `GranSynthReceiverForBike.scd` on all others.

To run manually on a single node:

```bash
# Host
sclang GranSynthHostFinal.scd &
python3 PythonHost.py

# Receiver
sclang GranSynthReceiverForBike.scd &
python3 PythonReceiver.py
```

---

## Dependencies

| Component | Dependency |
|---|---|
| Audio engine | SuperCollider (`sclang`, `scsynth`) |
| Audio routing | JACK (`jackd`) |
| Network messaging | P2PSC |
| GUI | Python 3, Pygame, python-osc |
| Deployment | Ansible |
