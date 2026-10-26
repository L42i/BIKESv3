# BIKES Camera

The bikes' Raspberry Pi AI Camera (IMX500) as an input for sound. The camera detects people, vehicles, bicycles and animals on the sensor itself, and `camera_osc.py` turns that into a few OSC messages that any SuperCollider script (or Python, Max, Pd, ...) can react to.

You don't need a bike to work on camera-reactive sounds: `fake_camera.py` sends the same messages from your laptop, and `CamTemplate.scd` is a ready-to-run starting point.

**Status:** Only **bikes1** has a camera so far; it faces the bike's **left** side. Every bike will get one, and the mounting direction may still change, so write sounds that work for any direction (use the `category` and `azimuth` fields, see below).

## Files

| File | Purpose |
|---|---|
| `camera_osc.py` | Runs on a bike. Reads the camera, tracks objects, sends `/cam/*` OSC. Exits quietly on bikes without a camera. |
| `CamListener.scd` | SuperCollider include. Receives `/cam/*`, keeps every bike's camera state, shares it over P2PSC, and calls your hooks. |
| `CamTemplate.scd` | A complete example sound effect (synthesized, no media needed). Copy it to start your own. |
| `fake_camera.py` | Sends realistic fake camera messages from any laptop. |
| `../soundscapes/CamReactions.scd` | How the Soundscapes concept uses the camera (a real-world example). |

## 1. Get the code

If you already have the repo:

```bash
git switch main
git pull
```

If you don't:

```bash
git clone https://github.com/L42i/BIKESv3.git
cd BIKESv3
```

You need [SuperCollider](https://supercollider.github.io) and Python 3 with `python-osc`:

```bash
pip install python-osc
```

On Windows use `py -m pip install python-osc`, and `py` instead of `python3` in the commands below.

## 2. Try it on your laptop (no bike needed)

1. Open `concepts/camera/CamTemplate.scd` in the SuperCollider IDE. Click anywhere inside the big outer parentheses and press **Ctrl+Enter** (**Cmd+Enter** on a Mac). The post window should say:
   ```
   CamListener ready on bike 1
   Listening for camera OSC on port 57120
   CamTemplate ready. ...
   ```
2. In a terminal, from the `concepts/camera` folder:
   ```bash
   python3 fake_camera.py --interactive
   ```
   Type a key and press Enter: `p` person, `c` car, `t` truck, `b` bicycle, `d` dog, `a` a person walking toward the bike. You should hear a sound for each.
3. For a continuous street instead, run `python3 fake_camera.py` (about 12 objects a minute) or `python3 fake_camera.py --busy`.

If the post window shows a port other than 57120 (another SuperCollider was already running), pass it on: `python3 fake_camera.py --port 57121`.

## 3. Listen to the real camera from your laptop

The camera on bikes1 can send its messages to your laptop as well as to the bike's own SuperCollider.

1. Join your laptop to the bikes' network (the UniFi Wi-Fi; credentials are in the BIKES passwords document on Teams) and find your laptop's IP address (`ipconfig` on Windows, `ipconfig getifaddr en0` on a Mac). It will look like `10.10.10.x`.
2. Run `CamTemplate.scd` (or your own script) on your laptop as in step 2.
3. Start the camera on bikes1, adding `--send` with your laptop's IP and the port from the post window:
   ```bash
   ssh bikes1@10.10.10.11
   cd ~/Desktop/BIKES/concepts/camera
   python3 camera_osc.py --facing left --verbose --send 10.10.10.50:57120 --stream-port 8000
   ```
   `--send` can be repeated for several laptops. `--stream-port 8000` lets everyone see what the camera sees at `http://10.10.10.11:8000/` (green boxes are confirmed objects).
4. If the full Soundscapes concept is being started with Ansible, add the same options there instead:
   ```bash
   ansible-playbook -i ./utility/config/bikes.ini concepts/soundscapes/soundscapes.yml --limit 10.10.10.11 -e soundscape="marine" -e camera_args="--send 10.10.10.50:57120 --stream-port 8000"
   ```

Only one program can use the camera at a time. If `camera_osc.py` complains the camera is busy, someone else's copy is running: `pkill -f camera_osc.py` on the bike.

On Windows, allow SuperCollider through the firewall when asked, or incoming messages will be blocked.

## 4. The messages

Every message starts with the bike number (as a string) that saw it.

| Address | Arguments | When |
|---|---|---|
| `/cam/state` | node, people, vehicles, bikes, animals, total, passRate | 10 times a second |
| `/cam/enter` | node, id, label, category, azimuth, closeness | an object is confirmed in view |
| `/cam/approach` | node, id, label, category, azimuth, closeness, growth | an object is getting bigger quickly (coming closer) |
| `/cam/exit` | node, id, label, category, duration | an object has been gone for 0.6 s |

- **label**: the detector's class name: `person`, `bicycle`, `car`, `motorcycle`, `bus`, `truck`, `dog`, ... (80 everyday object types).
- **category**: the label grouped for sound design: `person`, `vehicle` (car, motorcycle, bus, truck, train, boat, airplane), `bike` (bicycle), `animal`, or `other` (only sent if enabled with `--categories`).
- **azimuth**: direction relative to the bike in degrees. 0 is straight ahead, −90 left, +90 right, ±180 behind. With the camera facing left, objects range from about −123 (left and behind) to −57 (left and ahead). Use this rather than "left/right of the picture", so your sound still makes sense if the camera is moved.
- **closeness**: square root of how much of the picture the object fills, 0–1. Roughly: 0.1 is far away, 0.5 is a few metres, 0.8+ is right in front of the lens.
- **counts in `/cam/state`**: smoothed numbers of objects currently in view (so they can be fractional, like 1.6).
- **passRate**: objects entering view per minute, smoothed over about 20 s. While riding, this follows how busy the street is.
- **id**: the same object keeps its id from enter to exit.

## 5. Writing your own sound

Start from a copy of `CamTemplate.scd`. Load the listener once, then define any of these hooks. Each receives one Event:

```supercollider
(thisProcess.nowExecutingPath.dirname +/+ "CamListener.scd").load;

~onCamEnter    = { |ev| ev.category.postln };  // ev.node .id .label .category .azimuth .closeness .local
~onCamApproach = { |ev| };                     // ev.node .id .label .category .azimuth .closeness .growth .local
~onCamExit     = { |ev| };                     // ev.node .id .label .category .duration .local
~onCamState    = { |st| };                     // st.node .people .vehicles .bikes .animals .total .passRate .local
```

Labels and categories arrive as Symbols, so compare with `\person`, `\vehicle`, `\truck`.

Helpers from `CamListener.scd`:

| Helper | Returns |
|---|---|
| `~camEnsemble.()` | The counts summed over every bike whose camera is running, plus `.cameras` (how many). Good for "how busy is it around the whole group". |
| `~camLocal.()` | This bike's latest state, or `nil` if its camera isn't running. |
| `~camAlive.("2")` | Whether bike 2's camera reported in the last 2.5 s. |
| `~camVerbose = true` | Post every event to the post window. |

Things that will save you trouble:

- **Rate-limit your sounds.** A busy street can produce several events a second. `CamTemplate.scd` has a `~gate` helper; Soundscapes uses gaps of 1.5 s overall and 4 s per category.
- **Load samples once, at startup.** Don't call `Buffer.read` inside a hook; every call uses up one of scsynth's limited buffer slots, and they run out within an hour. See how `CamReactions.scd` preloads `~camBufs`.
- **Don't write `ev.size`.** `size` is a built-in method of every Event (it returns how many fields it has), which is why the field is called `closeness`.
- **On the bikes, events from other bikes' cameras arrive too** (marked `ev.local == false`). Decide whether a bike should play sounds for what another bike saw; Soundscapes only plays its own camera's events and uses the others for the shared background level.
- **Expect noise.** The detector sometimes sees things that aren't there. Short-lived detections are already filtered out, but sounds should still feel fine if a "car" appears that isn't real.
- **Keep it street-safe.** The bikes ride in traffic: avoid sudden loud sounds that could startle drivers.

## 6. Putting your sound on the bikes

To make a concept camera-reactive, follow what Soundscapes does (see `concepts/soundscapes/GUIListener.scd`, lines marked `CAMERA`):

1. Inside `s.waitForBoot`, load `../camera/CamListener.scd` and your own reactions file.
2. Once P2PSC has its name set, call `~camAttachP2PSC.(p);` so the bikes share camera events.
3. Add the camera step to the end of your concept's playbook (copy the `Launch camera service` task from `concepts/soundscapes/soundscapes.yml`). It must come after the `killall python3` steps, or they will stop it.

Then deploy as usual with `sync_folder.yml`. Before syncing, make sure your clone has the full `media/` folder and is on the branch you mean to deploy: the sync makes every Pi an exact copy of your folder and deletes anything that isn't in it.

## `camera_osc.py` options

| Option | Default | Meaning |
|---|---|---|
| `--facing` | `left` | Camera direction on the bike: `front`, `left`, `right`, `back`, or degrees. On the bikes this comes from `camera_facing` in `utility/config/bikes.ini`. |
| `--rotate180` | off | The camera is mounted upside down. |
| `--send HOST:PORT` | none | Also send every message to this address. Repeatable. |
| `--stream-port` | off | Serve a live view with boxes at `http://<bike ip>:<port>/`. |
| `--verbose` | off | Print every enter/exit/approach. |
| `--threshold` | `0.55` | Minimum detection confidence. Raise it (e.g. `0.65`) if you get false detections. |
| `--confirm-hits` | `3` | Frames an object must be seen before `/cam/enter`. |
| `--lost-after` | `0.6` | Seconds unseen before `/cam/exit`. Raise it if one car triggers twice. |
| `--approach-growth` | `0.25` | How fast closeness must grow to count as approaching. |
| `--categories` | `person,vehicle,bike,animal` | Categories that send events. Add `other` for everything else. |
| `--osc-host`, `--osc-port` | `127.0.0.1`, `57120` | The main destination (the bike's own sclang). |
| `--node` | from user name | Bike number sent with every message. |

## Troubleshooting

| Problem | Check |
|---|---|
| Nothing reaches SuperCollider | Is it listening on the port you send to (`NetAddr.langPort`)? Windows firewall? Is your laptop on the bikes' network, and did you use its `10.10.10.x` address? |
| `no IMX500 camera found` | Normal on bikes without a camera. On bikes1, check the ribbon cable and `rpicam-hello --list-cameras`. |
| Camera busy / fails to start | Another program has the camera: `pkill -f camera_osc.py`, and close any `rpicam-*` command. |
| Lots of wrong detections | Raise `--threshold`; check the live view (`--stream-port`) for reflections or something close to the lens. |
| Direction numbers are mirrored | The camera is upside down: add `--rotate180`. |
| Events but no sound | Rate limits may be swallowing them; set `~camVerbose = true` and check your hooks' conditions. |
