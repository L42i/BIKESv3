# UWB Shape

UWB Shape is the most hardware-intensive concept in the set. Each bike carries an ESP32 microcontroller with a DW1000 Ultra-Wideband radio module. The ESP32s continuously measure real-world distances between every pair of bikes and report those distances over USB serial to the Raspberry Pi. SuperCollider reads the serial stream, builds a live distance matrix, reconstructs the physical shape of the formation in 2D space, and uses proximity between bikes to drive sound — either looping a sample when bikes are close, or delaying and colouring a ping-chain tone based on how far apart they are.

Two SuperCollider scripts are provided: `BIKES_SHAPE.scd` is the full networked version with P2PSC, mode switching, and five sound modes. `SOLO_VIEW.scd` is a standalone single-machine version for testing the UWB serial feed and visualisation without any network.

---

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│              Each Bike (ESP32)              │
│                                             │
│  DW1000 UWB radio                           │
│    ├─ TWR ranging with other nodes          │
│    └─ range reports via ESP-NOW broadcast   │
│                                             │
│  USB serial → Raspberry Pi (/dev/ttyUSB0)  │
└─────────────────────────────────────────────┘
           │ serial: "A -> B: dist"
           ▼
┌──────────────────────────────┐
│      BIKES_SHAPE.scd         │
│  ├─ distance matrix          │
│  ├─ 2D layout reconstruction │
│  ├─ proximity detection      │
│  ├─ sound playback / looping │
│  └─ P2PSC ping chain         │
└──────────────────────────────┘
```

---

## Theory

The core problem the ESP32 firmware solves is: how do four nodes share one radio medium and collectively measure all six pairwise distances, without any central coordinator?

The answer is a **round-robin scheduler implemented as a distributed state machine**.

**Round-robin scheduling**

The DW1000 can only perform Two-Way Ranging with one other node at a time. With four bikes there are six unique pairs. The firmware pre-computes a fixed pair schedule (0→1, 2→3, 1→2, 3→0, 0→2, 1→3) and steps through it sequentially, one pair per "slot". The ordering is chosen so the same node doesn't act as Tag for multiple consecutive measurements, spreading radio load evenly.

**Distributed state machine**

Rather than one node acting as a central scheduler telling everyone what to do, every node runs the same state machine independently. The state is just two numbers: `currentPairIndex` (which pair is active right now) and `epochCounter` (a generation counter that increments each full cycle). From these two numbers, any node can instantly compute its own role — Tag, Anchor, or Idle — without being told:

```
if (NODE_ID == currentPairA())  → ROLE_TAG
if (NODE_ID == currentPairB())  → ROLE_ANCHOR
otherwise                       → ROLE_IDLE
```

This means the system has no single point of failure. If any node drops off and comes back, it just needs to learn the current `(pairIndex, epoch)` to rejoin correctly.

**Staying in sync — ESP-NOW state broadcasts**

The state only needs to be communicated when it changes. But radio environments are lossy, so a single transition broadcast might be missed. Two mechanisms handle this:

- The active Tag **rebroadcasts the current state every 100 ms** (not just on transitions), so any node that was briefly out of range can resync passively without anyone needing to detect the dropout.
- State change packets are sent in a **burst of two** to reduce the chance of both being dropped simultaneously.

The `epochCounter` is critical here: it prevents a delayed or replayed old state broadcast from confusing a node that has already moved on. Any incoming state packet with a mismatched epoch is ignored.

**Timeout and restart**

If a pair measurement takes longer than 1500 ms — because the two nodes are too far apart, occluded, or one has crashed — every node independently detects this via a local timer and resets the whole algorithm back to pair 0, epoch 0. This is the watchdog. No coordination is needed for the reset; because every node runs the same timer against the same state, they all time out at approximately the same moment.

The last known distances are deliberately preserved across a reset (the `resetDistanceMatrix()` call is commented out in `restartWholeAlgorithm()`), so a momentary dropout doesn't blank the distance display or lose the layout.

---

## Components

### uwb_full_matrix.imo (ESP32 firmware)

Arduino sketch flashed to each ESP32. Each unit has a unique `NODE_ID` (0–3) and UWB hardware address compiled in. The firmware does three things concurrently: UWB ranging, ESP-NOW coordination, and serial reporting.

**UWB ranging — Two-Way Ranging (TWR)**

The DW1000 can only range one pair at a time. The firmware implements a cooperative round-robin scheduler across all six possible node pairs:

| Step | Pair |
|---|---|
| 0 | 1 → 2 |
| 1 | 3 → 4 |
| 2 | 2 → 3 |
| 3 | 4 → 1 |
| 4 | 1 → 3 |
| 5 | 2 → 4 |

For each pair, the designated Tag node initiates ranging; the designated Anchor node responds; all other nodes idle. The pair ordering is interleaved to avoid keeping any single node as Tag for back-to-back measurements.

**ESP-NOW coordination**

All nodes communicate via WiFi ESP-NOW broadcast (no access point needed). Two message types are used:

- `MSG_STATE_CHANGE` — announces which pair is active and the current epoch counter. The Tag for the current pair rebroadcasts this every 100 ms so any node that dropped out can resync.
- `MSG_RANGE_REPORT` — broadcasts the measured distance so all nodes receive and store every measurement, not just the active pair.

A 1500 ms watchdog timeout resets the entire algorithm back to pair 0 if any pair stalls (printed to serial as "bottleneck!").

**Serial output**

After each successful range measurement, the firmware prints all known distances to serial at 115200 baud in the format:

```
A -> B: dist
```

where A and B are 1-indexed node numbers and dist is in metres. SuperCollider parses this format directly.

**Hardware**

| Signal | ESP32 Pin |
|---|---|
| SPI SCK | 18 |
| SPI MISO | 19 |
| SPI MOSI | 23 |
| UWB RST | 27 |
| UWB IRQ | 34 |
| UWB SS (CS) | 21 |
| I2C SDA (OLED) | 4 |
| I2C SCL (OLED) | 5 |

A 128×64 SSD1306 OLED displays current role, pair, and distances and updates every 500 ms.

**Per-node configuration**

Before flashing, set `NODE_ID` and `MY_ADDR` for each unit. The four addresses are:

| Node | NODE_ID | MY_ADDR |
|---|---|---|
| 1 | 0 | `7D:00:22:EA:82:60:3B:90` |
| 2 | 1 | `7D:00:22:EA:82:60:3B:91` |
| 3 | 2 | `7D:00:22:EA:82:60:3B:92` |
| 4 | 3 | `7D:00:22:EA:82:60:3B:93` |

**Library modifications**

The DW1000 Arduino library requires three timing constants to be tuned for reliable ranging in this setup. The following lines in `DW1000Ranging.h` have been changed from their defaults:

```cpp
// Reset period (ms) — CHANGED from default
#define DEFAULT_RESET_PERIOD 150

// Reply delay (µs) — CHANGED from default
#define DEFAULT_REPLY_DELAY_TIME 1500

// Timer delay (ms) — CHANGED from default
#define DEFAULT_TIMER_DELAY 20
```

`DEFAULT_RESET_PERIOD` controls how long the library waits after a hardware reset before resuming communication. `DEFAULT_REPLY_DELAY_TIME` sets the turnaround delay between a Tag's poll and an Anchor's response — too short and the Anchor isn't ready; too long and the round-robin slows down. `DEFAULT_TIMER_DELAY` sets the polling interval of the ranging state machine loop; tightening it from the default reduces measurement latency at the cost of slightly higher CPU usage.

If you pull a fresh copy of the DW1000 library from upstream, re-apply these three changes before compiling.

**Bundled libraries**

All Arduino libraries required to compile the sketch are included locally in `concepts/uwb/libraries/` so the project builds without any internet access or Arduino Library Manager setup. This mirrors the offline-first approach used elsewhere in the BIKES stack (e.g. the Chrony `.deb` in the clock sync setup). The sketch's `#include` paths resolve against this local folder when compiled with the Arduino IDE or `arduino-cli` pointing at it as the libraries directory.

---

### BIKES_SHAPE.scd (networked)

SuperCollider script running on each Raspberry Pi. It shares the ring topology and identity detection of the other networked concepts (`whoami` → node name and next peer).

**Serial reader**

Opens `/dev/ttyUSB0` at 115200 baud with RTS/CTS flow control. Reads byte-by-byte into a line buffer; on newline, parses the `"A -> B: dist"` format and calls `~updateDistanceFromSerial.(from, to, distMeters)`, which symmetrically updates the 4×4 `~distMatrix`.

If the serial port fails to open, the script continues in standalone mode with no distance data.

**2D layout reconstruction**

`~layoutFromMatrix` solves the positions of all four nodes from pairwise distances using trilateration. Node 1 is fixed at the origin; node 2 is placed along the x-axis; node 3 and 4 positions are computed using the law of cosines, with an ambiguity-resolution step for node 4 to pick the correct half-plane. The result is scaled to fit within a normalised ±1 coordinate space and centred. The visual positions update in real time as new distances arrive.

**Distance-to-audio mappings**

Two core mappings drive the audio behaviour:

- `~distToDelay` — maps distance (3.4–90 m) linearly to a forwarding delay (0–10 s). Distances under 3.4 m give zero delay.
- `~distToFreq` — when both neighbours are far (> 5 m), maps the closer leg's distance (5–90 m) to a sine frequency (200–2000 Hz). When either neighbour is within 5 m, locks the frequency at 200 Hz.

**Proximity detection**

- `~isNearNeighbor` — true if the next peer in the ring is within `~proximityThresh` (5 m).
- `~isNearEither` — true if either the next or previous peer is within 5 m.

**Loop management (`~updateLoop`)**

When any neighbour is within 5 m, a continuous loop synth starts. When both neighbours move beyond 5 m, the loop stops. The loop sound depends on the current mode (see below). In Hertz mode, the loop synth's frequency is updated live as distances change.

**Sound modes**

Modes are broadcast to all nodes via P2PSC `/mode` and can be switched from any node. Five modes are available:

| Mode | Button label | Behaviour |
|---|---|---|
| `\words` | WORDS | Loops/plays `media/uwb/words/<nodeNum>.wav` |
| `\birds` | BIRDS | Loops/plays `media/uwb/birds/<nodeNum>.wav` |
| `\alphabetSoup` | ALPHABET SOUP | Plays a random letter from `media/uwb/alphabet/<A-Z>.wav` on each ping; only one letter at a time |
| `\hertz` | HERTZ | Plays/loops a sine tone at a frequency derived from distance |
| `\mute` | MUTE | Silences audio; ping chain continues silently |

**P2PSC ping chain**

The same ring-forwarding chain as other concepts: on receiving `/ping`, the node plays its current sound (or a distance-pitched `\bikePing` sine if no buffer is loaded), waits for the distance-derived delay, then forwards to the next peer. When near a neighbour, the ping passes through immediately without the delay.

bikes1 auto-starts the chain after 5 seconds, and runs a watchdog that restarts it if no ping has been seen for 14 seconds.

**SynthDefs**

| SynthDef | Description |
|---|---|
| `\bikePing` | Percussive sine tone, 0.99 s release |
| `\sampleOnce` | One-shot stereo buffer playback |
| `\sampleLoop` | Looping stereo buffer with ASR fade |
| `\sineLoop` | Continuous sine with `lag(0.5)` for smooth frequency transitions |

**GUI**

A fullscreen SuperCollider window shows:

- A canvas (left, full height) with the four bike nodes drawn as circles at their computed 2D positions. Edges between ring-adjacent nodes are colour-coded green→red by distance. Measured distances in metres are labelled at the midpoint of each edge. The active node (currently forwarding a ping) flashes yellow.
- Five mode buttons on the right: ALPHABET SOUP, BIRDS, WORDS, HERTZ, and MUTE at the bottom.

---

### SOLO_VIEW.scd (standalone)

A single-machine version for testing the UWB serial feed and visualisation without P2PSC or networked sound. Differences from `BIKES_SHAPE.scd`:

- No node identity, no P2PSC, no mode broadcasting.
- Three local sound modes: BIRDS, BEES, AFFIRMATIONS (local buttons only, not networked).
- Runs a local ping chain sequencing through slots 1→2→3→4→1, with inter-note wait time mapped from the normalised screen distance between nodes (`~minDelay` 0.15 s to `~maxDelay` 1.5 s).
- Each slot plays a fixed sine frequency: 220, 277.18, 329.63, 440 Hz (A3, C#4, E4, A4).
- Same 2D layout reconstruction and serial reader as `BIKES_SHAPE.scd`.

Useful for verifying that the ESP32s are ranging correctly before deploying the full network.

### uwb_shape.yml

Standard Ansible playbook: kills existing processes, starts JACK and P2PSC, launches `BIKES_SHAPE.scd` on all nodes, waits for `scsynth`. No Python GUI is involved — the SuperCollider script opens its own window.

---

## File & Media Layout

```
concepts/uwb/
├── BIKES_SHAPE.scd
├── SOLO_VIEW.scd
├── /uwb_full_matrix/uwb_full_matrix.ino
├── uwb_shape.yml
└── libraries/             # bundled Arduino libraries

media/uwb/
├── words/
│   ├── 1.wav … 4.wav      # node-specific voice/word samples
├── birds/
│   ├── 1.wav … 4.wav      # node-specific bird sounds
└── alphabet/
    ├── A.wav … Z.wav       # one file per letter
```

---

## Running

**Flash firmware first** — each ESP32 needs its `NODE_ID` and `MY_ADDR` set and the sketch compiled and uploaded before deployment. Connect each ESP32 to its Raspberry Pi via USB.

Deploy the SC scripts via Ansible:

```bash
ansible-playbook -k -i ./utility/config/bikes.ini concepts/uwb/uwb_shape.yml
```

For standalone testing on a single machine with an ESP32 attached:

```bash
sclang SOLO_VIEW.scd
```

---

## Dependencies

| Component | Dependency |
|---|---|
| UWB ranging | DW1000 module (Decawave), `DW1000Ranging` Arduino library |
| Node coordination | ESP-NOW (built into ESP32 WiFi stack) |
| OLED display | Adafruit SSD1306 + GFX libraries |
| Audio engine | SuperCollider (`sclang`, `scsynth`) |
| Audio routing | JACK (`jackd`) |
| Network messaging | P2PSC |
| Deployment | Ansible |