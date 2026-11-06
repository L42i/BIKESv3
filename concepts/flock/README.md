# BIKES: Flocking

The bikes announce surveillance out loud. This is the BIKES: Flocking concept (Henrik von Coler, 2026-10-30) for Atlanta Streets Alive on November 8, 2026.

Each bike runs two Python processes, one for the camera and one for GPS. Both send OSC events to a local SuperCollider, which plays pre-generated speech through the bike's loudspeaker.

- Camera: a person in view makes the bike say "Person detected." or "The bikes are watching you.", a car, truck or bus makes it say "Vehicle detected." or "Your license plate has been recorded." Any other vehicle (motorcycle, bicycle, train, boat or airplane) only says "Vehicle detected." Bicycles count too, so a camera that sees another bike of the group will speak; drop `bicycle:vehicle` from `--class-map` to stop that.
- Flock zone: the FLOCK ON/OFF button on the touchscreen says whether the bike is inside a Flock camera zone. Switching it on makes the bike say "A Flock camera is watching this street." The GPS zone check is not used for now (`zoneSource` in `FlockSpeech.scd`), because the GPS dongles keep dropping off USB. GPS still feeds the map.
- Both: a person in view while the bike is inside a zone makes it say "You are entering a surveilled area.", "Please dismount your bike. You are being monitored." or "This is a surveilled area.". Only this case mentions a surveilled area.
- Echo: when a bike has finished saying something because of a detection, the other bikes repeat the same sentence in the same voice.

```
IMX500 -> flock_camera.py --\
                             +-- OSC --> FlockSpeech.scd --> loudspeaker
FLOCK ON/OFF -> flock_gui.py/        |  ^
                                     v  |  /flock/echo, UDP 57120
                              the other bikes' FlockSpeech.scd
```

## OSC

Everything goes to `127.0.0.1:57120` (the bike's sclang). Senders send on every change and resend the current state every 2 s, because UDP can drop packets. SuperCollider only acts on a 0 to 1 change, so the repeats never retrigger speech.

| Address | Argument | Sender |
|---|---|---|
| `/object/detected/person` | int, 1 present, 0 absent | `flock_camera.py` |
| `/object/detected/car` | int, 1 present, 0 absent: a car, truck or bus | `flock_camera.py` |
| `/object/detected/vehicle` | int, 1 present, 0 absent: a motorcycle, bicycle, train, boat or airplane | `flock_camera.py` |
| `/flock/zone` | int, 1 FLOCK ON (inside a zone), 0 FLOCK OFF | `flock_gui.py` |
| `/location/flock` | int, 1 inside a zone, 0 outside. Ignored unless `zoneSource` is `\gps` | `flock_gps.py` |
| `/flock/proximity` | float 0..1, not used by `FlockSpeech.scd` | `flock_gps.py` |
| `/flock/echo` | string bike ID, string event, int sentence, int voice. Arrives from the other bikes | `FlockSpeech.scd` on another bike |

## Echo between bikes

When a bike finishes playing a `person`, `car`, `vehicle` or `monitored` sentence that a detection triggered, its `FlockSpeech.scd` sends `/flock/echo` to the sclang of each other bike (`10.10.10.11` to `10.10.10.14`, port 57120). Each of them plays the same sentence, in the same voice if it has that file.

- An echo waits until the receiving bike is quiet. If it waits longer than 10 s it is dropped. A newer echo from the same bike replaces one that is still waiting.
- The receiving bike's own detections come first: a local trigger stops an echo that is playing.
- An echo is never sent on, so the bikes cannot echo each other in a loop. Echoes do not touch cooldowns or presence states.
- Touchscreen taps and the `flock` sentence (FLOCK ON) are not echoed.
- Only messages from the configured bike IPs are accepted. A bike finds its own number from its `bikesN` user name, since every bike has the hostname `L42i`.

The settings are in `config[\echo]` at the top of `FlockSpeech.scd`. The post window shows `sent echo`, `echo request from bike N`, `echoed bike N` and `dropped echo` lines.

## Files

| File | Purpose |
|---|---|
| `flock_camera.py` | IMX500 detections to `/object/detected/*`. Imports the tracker from `../camera/camera_osc.py`. |
| `flock_gps.py` | GPS position to `/location/flock` and `/flock/proximity`. Derived from `../flock_detection/flock_gps.py`. |
| `FlockSpeech.scd` | Receives the events and plays speech. Settings are in `config` at the top. See [SUPERCOLLIDER.md](SUPERCOLLIDER.md) to work on it. |
| `sentences.txt` | One sentence per line: `N\|event\|text`. Events are `person`, `car` (car, truck, bus), `vehicle` (other vehicles), `flock`, and `monitored` for a person inside a zone. A sentence can serve two events with two lines, as sentence 5 does. |
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

Which events speak is chosen in `config.enabled` at the top of `FlockSpeech.scd`. Cooldowns, volume, voice choice and sentence order are next to it.

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

A fake echo has to come from another bike's address. On bike 2, this asks bike 1 to repeat sentence 1 in voice 5:

```bash
python3 -c "from pythonosc.udp_client import SimpleUDPClient as C; C('10.10.10.11', 57120).send_message('/flock/echo', ['2', 'person', 1, 5])"
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
| `--class-map` | `person:person,car:car,truck:car,bus:car,motorcycle:vehicle,bicycle:vehicle,train:vehicle,boat:vehicle,airplane:vehicle` | Detector label to address. `car` can play the license plate sentence, `vehicle` cannot. |
| `--facing`, `--rotate180` | `left`, off | Camera mount. |
| `--send HOST:PORT` | none | Also send to a laptop. Repeatable. |

`flock_gps.py`:

| Option | Default | Meaning |
|---|---|---|
| `--gps-port`, `--baud-rate` | `/dev/ttyACM0`, `9600` | The bikes' u-blox receiver. |
| `--radius-feet` | `75` | Entering a zone. |
| `--exit-margin-feet` | `30` | Extra distance before leaving a zone. |
| `--gps-timeout` | `5` | Seconds without a fix before the zone is forced to 0. |


## Touchscreen speech controls

Start `FlockSpeech.scd` (or `./run_flock.sh`) first, then run this from a terminal
on the Pi desktop in `concepts/flock`:

```bash
python3 flock_gui.py
```

The fullscreen Pygame interface has four buttons: Person, Vehicle, Flock Camera,
and Person + Camera Zone. Each tap sends `/flock/trigger` with the string
`person`, `car`, `flock`, or `monitored` to `127.0.0.1:57120`.
Reload the updated `FlockSpeech.scd` before using the GUI.

The FLOCK ON/OFF switch at the top replaces the GPS zone check. ON means the bike
is inside a Flock camera zone: a person in view plays the surveilled-area
sentences, and switching on with nobody in view plays "A Flock camera is watching
this street." OFF means outside every zone: a person plays "Person detected." or "The bikes
are watching you."
The GUI sends `/flock/zone` 1 or 0 on every tap and again every 2 s, so a
restarted sclang picks the state up. It starts OFF, and closing the GUI sends 0.
Each bike has its own switch.

Manual taps bypass the automatic event enable flags and cooldowns, replacing any
current speech with a random sentence/voice in the selected category. They do not
change camera/GPS presence states and are not echoed to the other bikes.
Automatic detection remains active. The GUI
reports messages sent, not confirmed playback. Camera and GPS processes are not
required for manual playback; JACK, SuperCollider and speech media are required.

Dependencies are `pygame` and `python-osc` (also used by the existing touch GUIs).
For a window use `python3 flock_gui.py --windowed`. To change the destination,
use `--osc-host HOST --osc-port PORT`. Close on screen (or Escape) first asks
"Close the Flock screen?" with Cancel and Close; any tap outside Close, or 10 s
without an answer, cancels. Closing exits only the GUI; it does not stop audio
or the sensors. The existing launchers do not start
the GUI automatically.
