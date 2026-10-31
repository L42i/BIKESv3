/*
BIKES: mapped Flock camera proximity -> sound

Save this file in: <project>/concepts/flock_detection/flock_detection.scd
Put audio files in: <project>/media/flock_detection/
    loop.wav    repeating proximity sound
    enter.wav   one-shot when proximity rises to >= 0.5
    exit.wav    one-shot when proximity falls to < 0.5
Mono and stereo files are supported; output is stereo.

Save the file, then evaluate this entire block. Wait for "Flock audio ready".
Python on this machine should send ONE numeric proximity argument, e.g.:
    SimpleUDPClient("127.0.0.1", 57120).send_message("/flock/proximity", 0.7)
The OSC path is a placeholder: change oscPath below to match Python.
If Python sends [bikeId, proximity], change valueIndex from 1 to 2.

Behavior:
  0: loop fades out; next positive value restarts it from the beginning.
  > 0: loop repeats, with amplitude proportional to proximity.
  Crossing upward to >= 0.5: play enter.wav once, keeping the loop running.
  Crossing downward to < 0.5: play exit.wav once, keeping the loop if > 0.
  > 0.5: distortion increases continuously, reaching maximum at 1.
Each new crossing retriggers its cue; repeated values do not retrigger it.
An exit cue finishes even if proximity has already reached zero.
Rapid changes around 0.5 intentionally generate repeated crossings.

Python must keep sending current values, including 0 on leaving the range.
This receiver holds the last value if messages stop; it has no GPS watchdog.
The audio should have matching loop endpoints to avoid seam clicks.

Stop and release resources: ~flockStop.value;
Cmd/Ctrl + period also stops it. Reevaluate the block to restart.
*/
(
var config, scriptPath, mediaPath, paths, channelCounts, server, state;
var cleanup, playCue, applyProximity, loadTask;

config = (
    oscPath: '/flock/proximity',
    oscPort: 57120,             // sclang receiver, not scsynth's 57110
    valueIndex: 1,             // msg[0] is the OSC address
    threshold: 0.5,
    loopFile: "loop.wav",
    enterFile: "enter.wav",
    exitFile: "exit.wav",
    loopMaxAmp: 0.35,
    cueAmp: 0.45,
    smoothing: 0.12,           // seconds for amplitude/distortion changes
    fadeTime: 0.08,            // loop start/stop envelope
    maxDrive: 12.0,            // maximum tanh distortion drive
    out: 0                    // stereo output channels 0 and 1
);

scriptPath = thisProcess.nowExecutingPath;
if(scriptPath.isNil) {
    Error("Save this .scd file before evaluating it so media paths can be resolved.").throw;
};
mediaPath = (PathName(scriptPath).pathOnly +/+ "../../media/flock_detection").standardizePath;
paths = [config[\loopFile], config[\enterFile], config[\exitFile]].collect {
    |name| mediaPath +/+ name
};

// Check files before starting audio, with clear errors for missing/bad media.
channelCounts = paths.collect { |path|
    var file, channels;
    file = SoundFile.new;
    if(file.openRead(path).not) {
        Error("Cannot open audio file: " ++ path).throw;
    };
    channels = file.numChannels;
    if((file.numFrames <= 0) or: { (channels < 1) or: { channels > 2 } }) {
        file.close;
        Error("Use a nonempty mono/stereo audio file: " ++ path).throw;
    };
    file.close;
    channels
};

// Stop the previous instance before replacing its OSC handler and buffers.
if(~flockStop.notNil) { ~flockStop.value };
server = Server.default;
state = (
    ready: false, stopped: false, previous: 0.0,
    group: nil, loop: nil, responder: nil, stopHook: nil,
    buffers: List.new, defs: List.new
);

cleanup = { |fromCmdPeriod = false|
    if(state[\stopped].not) {
        state[\stopped] = true;
        state[\ready] = false;
        if(state[\responder].notNil) { state[\responder].free };
        if(state[\stopHook].notNil) { CmdPeriod.remove(state[\stopHook]) };
        if(server.serverRunning) {
            // CmdPeriod itself frees the synths; do not free those nodes twice.
            if(fromCmdPeriod.not and: { state[\group].notNil }) {
                state[\group].free;
            };
            state[\buffers].do { |buffer| buffer.free };
            state[\defs].do { |name| server.sendMsg('/d_free', name) };
        };
        state[\buffers].clear;
        state[\loop] = nil;
        "Flock audio stopped.".postln;
    };
};
~flockStop = { cleanup.value(false) };
state[\stopHook] = { cleanup.value(true) };
CmdPeriod.add(state[\stopHook]);

playCue = { |index|
    Synth.tail(state[\group], state[\defs][index], [
        \buf, state[\buffers][index].bufnum,
        \amp, config[\cueAmp], \out, config[\out]
    ]);
};

applyProximity = { |value|
    var previous;
    previous = state[\previous];

    if(value > 0) {
        if(state[\loop].isNil) {
            state[\loop] = Synth.tail(state[\group], state[\defs][0], [
                \buf, state[\buffers][0].bufnum,
                \proximity, value, \threshold, config[\threshold],
                \maxAmp, config[\loopMaxAmp], \maxDrive, config[\maxDrive],
                \smoothTime, config[\smoothing], \fadeTime, config[\fadeTime],
                \out, config[\out]
            ]);
        } {
            state[\loop].set(\proximity, value);
        };
    } {
        if(state[\loop].notNil) {
            // Release the envelope, then the synth frees itself.
            state[\loop].set(\gate, 0);
            state[\loop] = nil;
        };
    };

    if((previous < config[\threshold]) and: { value >= config[\threshold] }) {
        playCue.value(1);
    };
    if((previous >= config[\threshold]) and: { value < config[\threshold] }) {
        playCue.value(2);
    };
    state[\previous] = value;
};

loadTask = {
    Routine({
        if(state[\stopped].not) {
            paths.do { |path| state[\buffers].add(Buffer.read(server, path)) };

            // PlayBuf channel counts must be fixed when each SynthDef is built.
            state[\defs].add(\flockProximityLoop);
            state[\defs].add(\flockEnterCue);
            state[\defs].add(\flockExitCue);

            SynthDef(state[\defs][0], {
                |out = 0, buf = 0, proximity = 0, threshold = 0.5,
                maxAmp = 0.35, maxDrive = 12, smoothTime = 0.12,
                fadeTime = 0.08, gate = 1|
                var source, level, distortion, drive, wet, sound, envelope;
                source = PlayBuf.ar(channelCounts[0], buf, BufRateScale.kr(buf), loop: 1);
                if(channelCounts[0] == 1) { source = source ! 2 };

                level = Lag.kr(proximity.clip(0, 1), smoothTime);
                distortion = Lag.kr(
                    ((proximity - threshold) / (1 - threshold)).clip(0, 1),
                    smoothTime
                );
                drive = 1 + (distortion * (maxDrive - 1));
                wet = (source * drive).tanh / drive.tanh;
                // At <= 0.5 the steady-state mix is fully dry.
                sound = (source * (1 - distortion)) + (wet * distortion);
                envelope = EnvGen.kr(
                    Env.asr(fadeTime, 1, fadeTime), gate, doneAction: 2
                );
                Out.ar(out, LeakDC.ar(sound) * level * maxAmp * envelope);
            }).send(server);

            [1, 2].do { |index|
                SynthDef(state[\defs][index], { |out = 0, buf = 0, amp = 0.45|
                    var sound, edgeFade;
                    sound = PlayBuf.ar(
                        channelCounts[index], buf, BufRateScale.kr(buf),
                        loop: 0, doneAction: 2
                    );
                    if(channelCounts[index] == 1) { sound = sound ! 2 };
                    // A tiny fade reduces clicks at one-shot boundaries.
                    edgeFade = EnvGen.kr(Env.linen(
                        0.005, (BufDur.kr(buf) - 0.01).max(0), 0.005
                    ));
                    Out.ar(out, sound * amp * edgeFade);
                }).send(server);
            };

            server.sync;  // Wait for buffers AND synth definitions before OSC.
            if(state[\stopped].not) {
                if(state[\buffers].any { |buffer| buffer.numFrames <= 0 }) {
                    cleanup.value;
                    Error("A sound buffer failed to load. Check the server Post window.").throw;
                };
                state[\group] = Group.head(server);
                if(NetAddr.langPort != config[\oscPort]) {
                    if(thisProcess.openUDPPort(config[\oscPort]).not) {
                        cleanup.value;
                        Error("Cannot open OSC port " ++ config[\oscPort]).throw;
                    };
                };
                state[\responder] = OSCdef(\flockProximityReceiver, {
                    |msg, time, addr, recvPort|
                    var raw, value;
                    // Python is local. Its ephemeral sending port may vary.
                    if(addr.ip == "127.0.0.1") {
                        if(msg.size > config[\valueIndex]) {
                            raw = msg[config[\valueIndex]];
                            if(raw.isNumber) {
                                // Reject NaN/infinity, and clamp finite values to 0..1.
                                if((raw == raw) and: { raw.abs < inf }) {
                                    value = raw.asFloat.clip(0, 1);
                                    applyProximity.value(value);
                                };
                            };
                        };
                    };
                }, config[\oscPath], recvPort: config[\oscPort]);
                state[\ready] = true;
                ("Flock audio ready: 127.0.0.1:" ++ config[\oscPort]
                    ++ " " ++ config[\oscPath]).postln;
                ("Audio directory: " ++ mediaPath).postln;
            };
        };
    }).play(SystemClock);
};
server.waitForBoot(loadTask);
)

/*
OPTIONAL TEST: after "Flock audio ready", evaluate these lines ONE AT A TIME.
They simulate Python using the default OSC path and port.

n = NetAddr("127.0.0.1", 57120);
n.sendMsg('/flock/proximity', 0.2);  // quiet loop
n.sendMsg('/flock/proximity', 0.5);  // enter once; louder, still dry
n.sendMsg('/flock/proximity', 0.8);  // louder, distorted; no extra enter
n.sendMsg('/flock/proximity', 0.4);  // exit once; quieter, distortion fades away
n.sendMsg('/flock/proximity', 0.0);  // loop fades out
~flockStop.value;                  // stop receiver and free resources
*/
