# Latency Delay

Latency Delay is a networked audio experiment that explores the perceptual effect of propagation delay across a ring of nodes. A bell sample is triggered on one node and then relayed — with a configurable wait time before playing and before forwarding — around the ring indefinitely. A parallel "jam" path floods the network with high-frequency dummy messages, simulating network congestion so the delay's impact can be observed and tuned in real time.

---

## Architecture Overview

```
┌──────────┐    /relay    ┌──────────┐    /relay    ┌──────────┐
│  bikes1  │ ──────────▶  │  bikes2  │ ──────────▶  │  bikes3  │
└──────────┘              └──────────┘              └──────────┘
     ▲                                                    │
     │                   /relay                           │
     └────────────────  bikes4  ◀───────────────────────┘
```

Each node plays the bell sample on receipt, waits briefly, then forwards the message to the next peer. The loop continues indefinitely. Separately, each node sends a continuous stream of `/jam` messages to its peer; the jam recipient ignores them, but the traffic loads the network.

---

## Components

### Latency_delay.scd

SuperCollider script that runs on every node. It has two concurrent concerns: the audio relay chain and a SuperCollider GUI for controlling the jam rate.

**Setup**

On boot, the script:

1. Loads `media/Latency_delay/bell.wav` into a buffer.
2. Registers two SynthDefs — `\samplePlayerMono` and `\samplePlayerStereo` — that play the buffer with a short linear envelope (5 ms attack, full buffer duration sustain, 10 ms release).
3. Determines the node's identity by running `whoami` and mapping the hostname to a ring position:

| Hostname | `~host` | `~peer` |
|---|---|---|
| bikes1 | 1 | 2 |
| bikes2 | 2 | 3 |
| bikes3 | 3 | 4 |
| bikes4 | 4 | 1 |

**Relay path (`/relay`)**

When a `/relay` message arrives, a Routine runs on `AppClock`:

1. Waits `~waitBeforePlay` seconds (default 0.05 s).
2. Frees any currently playing synth.
3. Plays the bell buffer at `~relayAmp` (default 0.8), auto-selecting the mono or stereo SynthDef based on the buffer's channel count.
4. Waits `~waitBeforeForward` seconds (default 0.05 s).
5. Forwards `/<peer>/relay` to the next node.

**Jam path (`/jam`)**

A looping `~jammer` Routine continuously sends `/<peer>/jam` messages — `~jamRate` times per iteration, with `~jamGap` seconds between iterations (defaults: 1 message, 0.01 s gap). The receiving node's `/jam` handler intentionally does nothing; the jam messages exist solely to create network load.

**GUI**

A fullscreen SuperCollider window opens 1 second after boot with two controls:

- **Jam Rate slider** — maps slider position (0–1) through an exponential curve (skew 0.2) to a jam rate of 1–250 messages per gap interval. Allows real-time tuning of network congestion.
- **Send Relay button** — manually fires a `/relay` message to the peer node (with a fixed frequency argument of 440), starting or re-triggering the relay chain.

**Timing parameters**

| Variable | Default | Description |
|---|---|---|
| `~waitBeforePlay` | 0.05 s | Delay between receiving `/relay` and playing the bell |
| `~waitBeforeForward` | 0.05 s | Delay between starting playback and forwarding to the next peer |
| `~relayAmp` | 0.8 | Amplitude of the relayed bell |
| `~jamRate` | 1 | Number of `/jam` messages sent per loop iteration |
| `~jamGap` | 0.01 s | Wait between jam loop iterations |

### latency.yml

Ansible playbook targeting the `bikes` host group. It:

1. Kills any existing `sclang`, `scsynth`, `jacktrip`, `jackd`, `qjackctl`, `p2psc`, and `python3` processes.
2. Starts JACK audio (`jackd -d alsa -d hw:2,0`).
3. Starts the P2PSC daemon.
4. Launches `Latency_delay.scd` via `sclang`.
5. Polls for `scsynth` to appear (up to 10 retries, 1 s apart), then waits an additional 5 seconds for JACK to settle.

No GUI process is launched separately — the SuperCollider script opens its own window.

---

## File & Media Layout

```
concepts/Latency_delay/
├── Latency_delay.scd
└── latency.yml

media/Latency_delay/
└── bell.wav        # mono or stereo; loaded on all nodes
```

---

## Running

Deploy to all nodes via Ansible:

```bash
ansible-playbook -k -i ./utility/config/bikes.ini concepts/Latency_delay/latency.yml
```

To run on a single node manually:

```bash
sclang Latency_delay.scd
```

Once the GUI appears, press **Send Relay** to start the bell travelling around the ring. Use the **Jam Rate** slider to increase network congestion and observe how it affects the inter-node delay.

---

## Dependencies

| Component | Dependency |
|---|---|
| Audio engine | SuperCollider (`sclang`, `scsynth`) |
| Audio routing | JACK (`jackd`) |
| Network messaging | P2PSC |
| Deployment | Ansible |
