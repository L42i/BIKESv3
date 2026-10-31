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
| `/object/detected/car` | int 1 or 0 | A car, truck, bus or motorcycle is in view |
| `/location/flock` | int 1 or 0 | The bike is inside a Flock camera zone (75 ft) |
| `/flock/proximity` | float 0 to 1 | 1 at a camera, 0 outside the zone. Not used yet. |

What this means for your logic:

- The three int messages repeat every 2 s, so always react to a change, never to a message arriving.
- The camera sends 1 at once, and sends 0 about 2 s after the object leaves.
- The zone goes to 0 only 30 ft past the edge, so GPS noise does not flicker it.
- `/flock/proximity` updates about once per second, at the GPS rate. Smooth it if you map it to sound.
- If sclang restarts while something is in view, the next repeated 1 counts as a new trigger.

## How the script works

```
OSCdef -> receive -> trigger -> playSpeech -> pickSentence, pickVoice
```

| Function | Job |
|---|---|
| `receive` | Keeps the last value per event and passes on only 0 to 1 changes |
| `trigger` | Decides play or skip, in this order: disabled, busy, cooldown |
| `pickSentence` | Picks a sentence for the event |
| `pickVoice` | Picks a voice for that sentence |
| `playSpeech` | Starts the synth and sets the busy time and cooldown |

Rules as they stand:

- Only one sentence plays at a time, across all events.
- Cooldowns are per event, counted from the start of the last play.
- A skipped trigger is dropped, not queued. A person who arrives during a cooldown and stays hears nothing.

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

To add an event, add it to `addresses`, to `cooldown` and `enabled` in `config`, and to `last`, `lastPlayed` and `position` in `state`. Then add its lines to `sentences.txt`. Talk to whoever owns the Python side if it needs a new OSC address.

## Speech files

Name files `sentence_N_voice_M.wav`, where `N` is the first field in `sentences.txt`. Any sample rate, mono or stereo. A line in `sentences.txt` looks like this:

```
2|person|You are entering a surveilled area.
```

Files load when the script starts, so restart it after changing them. A sentence without files gets a warning and is skipped.

`media/` is not in git. `sync_folder.yml` deletes anything on the bike that is not in your local folder, so keep `media/flock/` in your clone before syncing.

## Testing

Send fake events from the SuperCollider IDE, one line at a time:

```supercollider
n = NetAddr("127.0.0.1", NetAddr.langPort);
n.sendMsg("/object/detected/person", 1);
n.sendMsg("/object/detected/person", 0);
n.sendMsg("/location/flock", 1);
```

Every decision goes to the post window: `played person: sentence 3 voice 2`, `skipped flock: busy`, `skipped person: cooldown, 6.1 s left`.

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
- Each bike runs its own copy and does not talk to the others yet. `voiceMode: \bike` gives each bike its own voice.
- The bikes ride in traffic, so avoid sudden loud sounds.
- If the "Flock speech ready" line shows a port other than 57120, another sclang is running. Stop it first.

## Open design questions

- Both modes are on by default, and nothing switches between them automatically. Should a moving bike ignore the camera?
- Should someone who stays in view hear a second announcement?
- Are the 8 s and 20 s cooldowns right on a real street?
- What should `/flock/proximity` do, if anything?
- How should four bikes sound together?
