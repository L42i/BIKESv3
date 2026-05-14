# Timesync

Timesync is the most minimal concept in the set — no SuperCollider, no P2PSC, no Python. It uses Ansible to coordinate a single synchronized playback moment across all nodes: bikes1 picks a future Unix timestamp, and every node tight-loops until that moment then fires `aplay` simultaneously.

---

## Architecture Overview

```
Ansible controller
       │
       ├── captures timestamp from bikes1 (T + 10 seconds)
       │
       └── broadcasts timestamp to all nodes
                  │
       ┌──────────┼──────────┐
       ▼          ▼          ▼ ...
    bikes1      bikes2     bikes3
  busy-wait   busy-wait  busy-wait
       │          │          │
       └──────────┴──────────┴──── aplay fires at T
```

---

## Components

### timesync.yml

The entire concept lives in a single Ansible playbook. It has no companion script files.

**Teardown**

Before playback, the playbook kills any processes that might hold the audio device: `sclang`, `scsynth`, `p2psc`, `aplay`, `jacktrip`, `qjackctl`, `jackd`, `python3`, and anything holding `/dev/snd/*` via `fuser -k`.

**Timestamp negotiation**

bikes1 computes a target time by running:

```bash
echo $(( $(date +%s) + 10 ))
```

This gives a Unix timestamp 10 seconds in the future. The result is registered as `play_at` and made available to all hosts via Ansible's `hostvars`.

**Synchronized playback**

Every node runs a bash busy-wait loop that polls `date +%s` at 1 ms intervals until the target timestamp is reached, then immediately calls `aplay`:

```bash
while [ $(date +%s) -lt <target> ]; do sleep 0.001; done
aplay -D hw:2,0 <remote_app_dir>/../../media/timesync/1.wav
```

All nodes play the same file (`1.wav`) and use the same ALSA hardware device (`hw:2,0`).

!!! note "Prerequisite: clock synchronization"
    This works because all nodes share a common clock — bikes1 acts as a Chrony NTP server and bikes2–4 sync from it. This is a one-time infrastructure setup, not repeated per-run. See [Clock Sync](../setup/clock-sync.md) for details.

---

## File & Media Layout

```
concepts/timesync/
└── timesync.yml

media/timesync/
└── 1.wav       # played simultaneously on all nodes
```

Note: there is a path issue in the current playbook — `remote_app_dir` points to `concepts/timesync/` but the `aplay` command appends `../../media/timesync/1.wav` without a separating `/`. Verify the resolved path on deployment.

---

## Running

```bash
ansible-playbook -k -i ./utility/config/bikes.ini concepts/timesync/timesync.yml
```

Playback fires automatically ~10 seconds after the playbook reaches the timestamp task. No further interaction is needed.

---

## Dependencies

| Component | Dependency |
|---|---|
| Audio playback | `aplay` (ALSA utils) |
| Deployment & coordination | Ansible |