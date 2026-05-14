# Forwarding



Forwarding is the simplest of the network concepts — a pure P2PSC ping chain. Each node plays a sine tone when it receives a ping, then forwards the message to the next node in the ring. Node `bikes1` auto-starts the chain 5 seconds after boot, so no manual trigger is needed. There is no GUI.

---

## Architecture Overview

```
bikes1 ──/2/ping──▶ bikes2 ──/3/ping──▶ bikes3 ──/4/ping──▶ bikes4
  ▲                                                               │
  └───────────────────────/1/ping────────────────────────────────┘
```

The chain loops indefinitely — each forward triggers the next node, which plays its tone and passes the message on.

---

## Components

### forwarding.scd

Single SuperCollider script that runs identically on all four nodes. On boot it:

1. Determines the node's identity via `whoami` and sets the ring topology:

| Hostname | `~myName` | `~nextPeer` |
|---|---|---|
| bikes1 | 1 | 2 |
| bikes2 | 2 | 3 |
| bikes3 | 3 | 4 |
| bikes4 | 4 | 1 |

2. Registers the `\bikePing` SynthDef — a percussive sine tone with a 0.99 s release, output to both channels.
3. Connects to P2PSC under the node's name.

**`/ping` handler**

On receiving a `/ping` message, the node forks a routine that:

1. Waits 0.25 s.
2. Plays `\bikePing` at 200 Hz.
3. Waits another 0.25 s.
4. Forwards `/<nextPeer>/ping` to the next node in the ring.

**Auto-start (bikes1 only)**

After connecting to P2PSC, bikes1 waits 5 seconds then plays its own tone and sends `/2/ping` directly, launching the chain without any external trigger.

### runForwarding.yml

Ansible playbook targeting the `bikes` host group. It:

1. Kills any existing `sclang`, `scsynth`, `p2psc`, `jackd`, and `qjackctl` processes.
2. Starts JACK (`jackd -d alsa -d hw:2,0`).
3. Starts the P2PSC daemon.
4. Launches `forwarding.scd` via `sclang` on all nodes simultaneously.

Because all nodes run the same script, there is no host/receiver distinction — the Ansible playbook is uniform across the group.

---

## File & Media Layout

```
concepts/forwarding/
├── forwarding.scd
└── runForwarding.yml
```

No external media files are required; the tone is synthesized.

---

## Running

```bash
ansible-playbook -k -i ./utility/config/bikes.ini concepts/forwarding/runForwarding.yml
```

The ping chain starts automatically on bikes1 after a 5-second delay. No further interaction is needed.

To run on a single node manually (for testing):

```bash
sclang forwarding.scd
```

Note: on a machine that doesn't match any `bikesN` hostname, the script will post an error and exit. The auto-start only fires on bikes1.

---

## Dependencies

| Component | Dependency |
|---|---|
| Audio engine | SuperCollider (`sclang`, `scsynth`) |
| Audio routing | JACK (`jackd`) |
| Network messaging | P2PSC |
| Deployment | Ansible |
