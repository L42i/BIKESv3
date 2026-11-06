# BIKES Flocking: SuperCollider Guide

For the team taking over the trigger logic and audio design. You can do all of this work in three places, without touching Python:

| File | What it holds |
|---|---|
| `FlockSpeech.scd` | Trigger logic, playback, settings |
| `sentences.txt` | Which sentence belongs to which event |
| `media/flock/` | The speech files |

See [README.md](README.md) for how the whole concept runs on a bike.

## Current status

- Trigger logic was tested on bike 1 with test tones. Real speech has not been played yet.
- It has only run on the bikes (Linux, SuperCollider 3.13). It has not been tried on a laptop, so expect small fixes on Windows or Mac.
- Bikes 2 to 4 have working cameras, but Flocking is not deployed on them yet.

## Inputs

All messages arrive at sclang on port 57120 with one argument.

| Address | Value | Meaning |
|---|---|---|
| `/object/detected/person` | int 1 or 0 | A person is in view |
| `/object/detected/car` | int 1 or 0 | A car, truck or bus is in view |
| `/object/detected/vehicle` | int 1 or 0 | A motorcycle, bicycle, train, boat or airplane is in view |
| `/flock/zone` | int 1 or 0 | FLOCK ON/OFF on the touchscreen: the bike is inside a Flock camera zone. Used while `config[\zoneSource]` is `\gui` (the default). |
| `/location/flock` | int 1 or 0 | GPS: the bike is inside a Flock camera zone (75 ft). Used only when `config[\zoneSource]` is `\gps`. |
| `/flock/proximity` | float 0 to 1 | 1 at a camera, 0 outside the zone. Not used yet. |
| `/flock/echo` | string, string, int, int | Another bike's bike ID, event, sentence and voice, sent when it finished a sentence |

What this means for your logic:

- The three int messages repeat every 2 s, so always react to a change, never to a message arriving.
- The camera sends 1 at once, and sends 0 about 2 s after the object leaves.
- The GPS zone goes to 0 only 30 ft past the edge, so GPS noise does not flicker it. The GPS is set aside for now because its USB link keeps dropping; set `zoneSource: \gps` to go back to it.
- `/flock/proximity` updates about once per second, at the GPS rate. Smooth it if you map it to sound.
- If sclang restarts while something is in view, the next repeated 1 counts as a new trigger.

## How the script works

```
OSCdef -> receive -> route -> trigger -> playSpeech -> pickSentence, pickVoice
```

| Function | Job |
|---|---|
| `receive` | Keeps the last value per address and passes on only 0 to 1 changes |
| `route` | Turns a person inside a zone, or a zone entered with a person in view, into `monitored` |
| `trigger` | Decides play or skip, in this order: disabled, busy, cooldown |
| `pickSentence` | Picks a sentence for the event |
| `pickVoice` | Picks a voice for that sentence |
| `playSpeech` | Starts the synth and sets the busy time and cooldown. Stops any echo, and schedules `sendEcho` |
| `sendEcho` | When the sentence has played to the end, sends `/flock/echo` to the other bikes, unless a newer sentence replaced it |
| `receiveEcho` | Checks the sender, then queues the echo (one per bike) |
| `drainEchoes` | Plays queued echoes one at a time when the bike is quiet, and drops any older than `maxWait` |
| `playEcho` | Plays an echo in its own group, with the sender's voice if this bike has it |

Rules as they stand:

| Situation | Event | Sentences |
|---|---|---|
| A person, outside any zone | `person` | 1, 2 |
| A car, truck or bus | `car` | 5, 6 |
| Any other vehicle (no license plate sentence) | `vehicle` | 5 |
| Entering a zone, no person in view | `flock` | 8 |
| A person and a zone at the same time, whichever came first | `monitored` | 3, 4, 7 |

- Only one sentence plays at a time, across all events.
- Cooldowns are per event, counted from the start of the last play. All four are 1 s, which is shorter than every sentence (2.1 to 4.4 s), so in practice an event can play again as soon as the speech before it ends.
- A skipped trigger is dropped, not queued. A person who arrives while something else is speaking and stays hears nothing.
- The exception: a `monitored` trigger skipped because something else is speaking is tried again when that speech ends, if the person and the zone are both still there.
- After an automatic `person`, `car`, `vehicle` or `monitored` sentence has played, the other bikes echo it. An echo never blocks this bike's own triggers: a local trigger stops it. An echo is not sent on, so echoes cannot loop.

Echo settings, in `config[\echo]`:

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Send and accept echoes |
| `events` | `[\person, \car, \vehicle, \monitored]` | Automatic events that the other bikes repeat |
| `manual` | `false` | Also echo touchscreen taps |
| `sameVoice` | `true` | Use the sender's voice. `false` lets each bike pick its own |
| `maxWait` | `10` | Seconds an echo may wait for this bike to be quiet |
| `amp` | `0.8` | Echo volume |
| `peers` | `10.10.10.11` to `.14` | Bike N's address is entry N. Echoes from any other address are ignored |

## Where to change things

| To change | Edit |
|---|---|
| Volume, cooldowns, sentence order, voice choice | `config` at the top |
| Stationary or moving mode | `config[\enabled]` |
| When speech plays | `trigger` |
| Which sentence or voice plays | `pickSentence`, `pickVoice` |
| The sound itself (filters, reverb, spatialization) | The `flockSpeech` SynthDefs |

- If you add a tail such as reverb, the synth outlives the file, so extend `busyUntil` in `playSpeech` and adjust how the synth frees itself.
- There are two SynthDefs, for mono and stereo files. Change both.
- Read settings with `config[\key]`, as the script does, because some names collide with Event methods.

To add an event, add it to `addresses`, to `cooldown` and `enabled` in `config`, and to `last`, `lastPlayed` and `position` in `state`. Then add its lines to `sentences.txt`. Talk to whoever owns the Python side if it needs a new OSC address. An event made from other events, like `monitored`, has no address: leave it out of `addresses` and `last`, and produce it in `route`.

## Speech files

Name files `sentence_N_voice_M.wav`, where `N` is the first field in `sentences.txt`. Any sample rate, mono or stereo. A line in `sentences.txt` looks like this:

```
3|monitored|You are entering a surveilled area.
```

Files load when the script starts, so restart it after changing them. A sentence without files gets a warning and is skipped.

`media/` is not in git. `sync_folder.yml` deletes anything on the bike that is not in your local folder, so keep `media/flock/` in your clone before syncing.

## Testing

Send fake events from the SuperCollider IDE, one line at a time:

```supercollider
n = NetAddr("127.0.0.1", NetAddr.langPort);
n.sendMsg("/object/detected/person", 1);  // person
n.sendMsg("/object/detected/person", 0);
n.sendMsg("/flock/zone", 1);              // flock (FLOCK ON)
n.sendMsg("/object/detected/person", 1);  // monitored, then echoed by the other bikes
n.sendMsg("/flock/zone", 0);              // FLOCK OFF
```

The GUI resends `/flock/zone` every 2 s, so close it before sending your own zone values.

Every decision goes to the post window: `played monitored: sentence 3 voice 2`, `skipped flock: busy`, `skipped car: disabled`.

On a bike, stop the Python senders before sending fake events, or their repeats will overwrite your values. To test with real senders:

```bash
GPS_ARGS="--simulate walk" ./run_flock.sh
```

```bash
tail -f ~/Desktop/flock_sclang.log | grep -E 'played|skipped'
```

```bash
./run_flock.sh stop
```

## Keep in mind

- Load all audio at startup. Do not call `Buffer.read` inside a trigger; scsynth has a limited number of buffers.
- Free anything new you create in `cleanup`, so `~flockStop` and reevaluating the script stay clean.
- Each bike runs its own copy. The copies talk to each other only through `/flock/echo` (and the GPS peer alarm).
- Audio files load in batches of 16. When all of them loaded at once, a few buffers on bikes 2 and 3 ended up without a size and failed to play.
- The bikes ride in traffic, so avoid sudden loud sounds.
- If the "Flock speech ready" line shows a port other than 57120, another sclang is running. Stop it first.

## Open design questions

- Both modes are on by default, and nothing switches between them automatically. Should a moving bike ignore the camera?
- Should someone who stays in view hear a second announcement?
- Is the 1 s cooldown right on a real street? It used to be 8 s (20 s for `flock`).
- What should `/flock/proximity` do, if anything?
- How should four bikes sound together?
