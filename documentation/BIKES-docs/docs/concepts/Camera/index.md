# Camera

Each bike is getting a Raspberry Pi AI Camera (Sony IMX500). The camera runs object detection on the sensor itself, so the Pi only receives what was seen: people, vehicles, bicycles, animals, where they are relative to the bike, and roughly how close. `camera_osc.py` turns this into OSC messages that any concept can use to react to its surroundings.

Only **bikes1** has a camera so far, mounted facing the bike's **left** side. The code runs on every bike and does nothing where no camera is attached.

The full guide for writing camera-reactive sounds, including how to work on your laptop without a bike, is in [`concepts/camera/README.md`](https://github.com/L42i/BIKESv3/tree/camera-soundscapes/concepts/camera) (on the `camera-soundscapes` branch until it is merged).

---

## Architecture Overview

```
IMX500 camera (detection on the sensor)
   │
   ▼
camera_osc.py ── /cam/* OSC ──▶ sclang on the same bike (port 57120)
   │                              │  CamListener.scd: state + hooks
   │                              │  concept reactions (e.g. CamReactions.scd)
   │                              └── P2PSC /camEvent, /camState ──▶ other bikes
   │
   ├── optional --send ──▶ teammates' laptops
   └── optional --stream-port ──▶ live view in a browser
```

---

## Messages

Every message starts with the number of the bike whose camera saw it.

| Address | Arguments | When |
|---|---|---|
| `/cam/state` | node, people, vehicles, bikes, animals, total, passRate | 10 times a second |
| `/cam/enter` | node, id, label, category, azimuth, closeness | an object is confirmed in view |
| `/cam/approach` | node, id, label, category, azimuth, closeness, growth | an object is coming closer quickly |
| `/cam/exit` | node, id, label, category, duration | an object has left |

- **azimuth** is relative to the bike: 0 ahead, −90 left, +90 right, ±180 behind. It comes from the camera's mounting direction (`camera_facing` in `utility/config/bikes.ini`), so sounds keep working if the camera is moved.
- **closeness** is 0–1, the square root of how much of the picture the object fills.
- **passRate** is objects entering view per minute; while riding it follows how busy the street is.

---

## Components

| File | Role |
|---|---|
| `concepts/camera/camera_osc.py` | Camera service on each bike: detection, tracking, OSC output, optional live view |
| `concepts/camera/CamListener.scd` | SuperCollider include: camera state for every bike, P2PSC sharing, `~onCamEnter` / `~onCamApproach` / `~onCamExit` / `~onCamState` hooks |
| `concepts/camera/CamTemplate.scd` | Ready-to-run example sound effect, synthesized |
| `concepts/camera/fake_camera.py` | Sends realistic fake camera messages from any laptop |
| `concepts/soundscapes/CamReactions.scd` | Soundscapes' camera mappings |

---

## Used by

**Soundscapes**: the base track's level and brightness follow how busy it is around the bikes; people, vehicles, bicycles and animals trigger theme samples; someone walking up to a bike sends a ripple around the ring. See [Soundscapes](../Soundscapes/index.md).

---

## Running

The camera starts automatically as the last step of the Soundscapes playbook. To stream it to a laptop at the same time:

```bash
ansible-playbook -i ./utility/config/bikes.ini concepts/soundscapes/soundscapes.yml -e soundscape="marine" -e camera_args="--send 10.10.10.50:57120 --stream-port 8000"
```

By hand on bikes1, with every event printed and a live view at `http://10.10.10.11:8000/`:

```bash
cd ~/Desktop/BIKES/concepts/camera
python3 camera_osc.py --facing left --verbose --stream-port 8000
```

On a laptop, without a bike: run `CamTemplate.scd` in SuperCollider, then `python3 fake_camera.py --interactive`.

---

## Dependencies

| Component | Dependency |
|---|---|
| Camera | Raspberry Pi AI Camera, `imx500-all` (apt), `python3-picamera2` |
| OSC | `python-osc` |
| Live view | `python3-simplejpeg`, `python3-pil` (preinstalled on Raspberry Pi OS) |
| Sound | SuperCollider; P2PSC for sharing between bikes |
| Deployment | Ansible |
