# BIKES: Flocking

The bikes announce surveillance out loud. This is the BIKES: Flocking concept (Henrik von Coler, 2026-10-30) for Atlanta Streets Alive on November 8, 2026.

Each bike runs two Python processes, one for the camera and one for GPS. Both send OSC events to a local SuperCollider, which plays pre-generated speech through the bike's loudspeaker.

- Stationary: the camera sees a person or a car near a Flock camera, and the bike speaks ("You are entering a surveilled area.").
- Moving: the GPS position is compared with an offline list of Flock camera coordinates. Entering a zone makes the bike speak ("This is a surveilled area.").

```
IMX500 -> flock_camera.py --\
                             +-- OSC --> FlockSpeech.scd --> loudspeaker
u-blox -> flock_gps.py -----/
```

## OSC

Everything goes to `127.0.0.1:57120` (the bike's sclang). Senders send on every change and resend the current state every 2 s, because UDP can drop packets. SuperCollider only acts on a 0 to 1 change, so the repeats never retrigger speech.

| Address | Argument | Sender |
|---|---|---|
| `/object/detected/person` | int, 1 present, 0 absent | `flock_camera.py` |
| `/object/detected/car` | int, 1 present, 0 absent | `flock_camera.py` |
| `/location/flock` | int, 1 inside a zone, 0 outside | `flock_gps.py` |
| `/flock/proximity` | float 0..1, not used by `FlockSpeech.scd` | `flock_gps.py` |

## Files

| File | Purpose |
|---|---|
| `flock_camera.py` | IMX500 detections to `/object/detected/*`. Imports the tracker from `../camera/camera_osc.py`. |
| `flock_gps.py` | GPS position to `/location/flock` and `/flock/proximity`. Derived from `../flock_detection/flock_gps.py`. |
| `FlockSpeech.scd` | Receives the events and plays speech. Settings are in `config` at the top. See [SUPERCOLLIDER.md](SUPERCOLLIDER.md) to work on it. |
| `sentences.txt` | One sentence per line: `N\|event\|text`. Events are `person`, `car`, `flock`. |
| `make_placeholder_corpus.py` | Renders `sentences.txt` with espeak-ng into `media/flock/`. |
| `osc_monitor.py` | Prints all OSC that arrives. |
| `run_flock.sh` | Starts everything on the bike you are logged in to. |
| `flock.yml` | Ansible playbook, starts everything from the laptop. |

## Speech corpus

Files live in `media/flock/` and are named `sentence_N_voice_M.wav`, where `N` is the sentence number in `sentences.txt` and `M` is the voice. Mono or stereo, any sample rate.

`media/` is ignored by git, so the corpus does not travel with the repo. For placeholders, on the bike:

```bash
sudo apt install espeak-ng
python3 make_placeholder_corpus.py
```

To swap in the Kokoro corpus, put the generated files in `media/flock/` with the same names, replacing the placeholders. To add a sentence, add a line to `sentences.txt` and add its wav files. Restart `FlockSpeech.scd` after either change. A sentence with no files gets a warning in the post window and is skipped.

`sync_folder.yml` makes the Pi an exact copy of the laptop folder and deletes anything else, so the laptop clone must contain `media/flock/` before syncing.

## Run it

Python packages needed on every bike: `picamera2`, `python-osc`, `pyserial`, `pynmea2`. `pynmea2` is not preinstalled:

```bash
pip3 install --user --break-system-packages pynmea2
```

On the bike:

```bash
./run_flock.sh
./run_flock.sh stop
```

Options go through the environment. Logs are in `~/Desktop/flock_*.log`.

```bash
CAMERA_ARGS="--facing left --stream-port 8000" GPS_ARGS="--radius-feet 100" ./run_flock.sh
```

`--stream-port 8000` shows what the camera sees at `http://10.10.10.11:8000/` from a laptop on the bikes network.

From the laptop, at the repo root, after syncing:

```bash
ansible-playbook -i ./utility/config/bikes.ini concepts/flock/flock.yml --limit 10.10.10.11
```

Stationary or moving mode is chosen in `config.enabled` at the top of `FlockSpeech.scd`. Cooldowns, volume, voice choice and sentence order are next to it. `voiceMode: \bike` gives each bike its own voice for the chorus.

Only one program can open the camera. `run_flock.sh` stops `camera_osc.py` and old copies of `flock_camera.py` first. If another sclang is running, a new one can end up on port 57121, so check the "Flock speech ready" line.

## Test without hardware

Print what the senders send. Stop sclang first, since the monitor needs the same port.

```bash
python3 osc_monitor.py
```

Walk through the first GPS target, or type positions by hand:

```bash
python3 flock_gps.py --simulate walk
python3 flock_gps.py --simulate
```

Send fake events to a running `FlockSpeech.scd`:

```bash
python3 -c "from pythonosc.udp_client import SimpleUDPClient as C; C('127.0.0.1', 57120).send_message('/object/detected/person', 1)"
```

## Flock camera coordinates

The built-in list is `TARGETS` in `flock_gps.py`. To use another list without editing code, make a file with one `lat,lon` per line (`#` starts a comment) and pass it. `--targets-file` replaces the list, `--add-target` appends to it.

```bash
python3 flock_gps.py --targets-file route.csv --add-target 33.7745,-84.3954
```

## Tuning

`flock_camera.py`:

| Option | Default | Meaning |
|---|---|---|
| `--threshold` | `0.55` | Minimum detection score. Raise it if people at the edge of the picture flicker. |
| `--confirm-hits` | `3` | Detections needed to confirm an object. |
| `--lost-after` | `0.6` | Seconds unseen before an object is gone. |
| `--release` | `1.5` | Seconds with no objects before sending 0. Added to `--lost-after`, so 0 comes about 2 s after someone leaves. |
| `--class-map` | `person:person,car:car,truck:car,bus:car,motorcycle:car` | Detector label to address. |
| `--facing`, `--rotate180` | `left`, off | Camera mount. |
| `--send HOST:PORT` | none | Also send to a laptop. Repeatable. |

`flock_gps.py`:

| Option | Default | Meaning |
|---|---|---|
| `--gps-port`, `--baud-rate` | `/dev/ttyACM0`, `9600` | The bikes' u-blox receiver. |
| `--radius-feet` | `75` | Entering a zone. |
| `--exit-margin-feet` | `30` | Extra distance before leaving a zone. |
| `--gps-timeout` | `5` | Seconds without a fix before the zone is forced to 0. |
