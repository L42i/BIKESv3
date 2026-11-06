/*
BIKES Flocking: camera and GPS events -> spoken announcements

Speech files: <project>/media/flock/sentence_N_voice_M.wav (mono or stereo)
Which sentence belongs to which event: sentences.txt in this folder (N|event|text)
Each sentence has 28 voices numbered 0 through 27. Every accepted trigger
randomly selects an available voice for the selected sentence. Repeats are allowed.

OSC, one int argument, 1 = entered / present, 0 = left / absent:
    /object/detected/person   from flock_camera.py
    /object/detected/car      from flock_camera.py
    /location/flock           from flock_gps.py
Senders resend the current state every 2 s. Only a 0 -> 1 change can trigger speech.

A person and a Flock zone at the same time make the \monitored event: a person
arriving inside a zone, or the bike entering a zone with a person in view.
Otherwise a person plays \person and a zone plays \flock.

A trigger plays one sentence if its event is enabled, its cooldown has passed
and nothing else is speaking. Every decision goes to the post window.
A \monitored trigger that finds something else speaking is retried when that
speech ends, if the person and the zone are both still there.

Peer alarm: /flock/peer/entered, or the GPS relay's /location/flock/peer,
on this sclang's port 57120. Plays the first readable mono/stereo WAV in
media/flock/alarm/ (alphabetical), falling back to media/flock/alarm.wav
when the folder has no WAVs. Preloaded once; independent 2-second cooldown
from playback start, shared by both paths. Alarms can play alongside speech.

Stop and release resources: ~flockStop.value;
Reevaluate the block to restart.
*/
(
var config, addresses, scriptPath, mediaPath, sentencesPath, server, state;
var readSentences, scanMedia, cleanup, pickSentence, pickVoice, playSpeech, trigger, route, receive;
var loadAlarm, playAlarm;

config = (
    oscPort: 57120,            // sclang receiver, not scsynth's 57110
    amp: 0.8,
    alarmAmp: 0.8,
    alarmCooldown: 2.0,        // shared by all peer notifications, seconds from start
    out: 0,                    // stereo output channels 0 and 1
    cooldown: (person: 8, car: 8, flock: 20, monitored: 8),  // seconds per event
    enabled: (person: true, car: true, flock: true, monitored: true),  // stationary vs moving mode
    voiceIds: (0..27),         // 28 voices; use (1..28) for filenames numbered 1-28
    order: \random             // \random, or \sequence through the event's sentences
);

addresses = (
    person: "/object/detected/person",
    car: "/object/detected/car",
    flock: "/location/flock"
);

scriptPath = thisProcess.nowExecutingPath;
if(scriptPath.isNil) {
    Error("Save this .scd file before evaluating it so media paths can be resolved.").throw;
};
scriptPath = File.realpath(scriptPath).dirname;
mediaPath = (scriptPath +/+ "../../media/flock").standardizePath;
sentencesPath = scriptPath +/+ "sentences.txt";

// event -> list of sentence numbers
readSentences = {
    var table = ();
    File.readAllString(sentencesPath).replace("\r", "").split($\n).do { |line|
        var parts = line.split($|);
        if(parts.size >= 3) {
            var event = parts[1].asSymbol;
            table[event] = (table[event] ?? { [] }).add(parts[0].asInteger);
        };
    };
    table
};

// sentence number -> voice number -> path
scanMedia = {
    var files = Dictionary.new;
    PathName(mediaPath).files.do { |file|
        // Match decimal digits, then check the numeric voice ID against voiceIds.
        var match = file.fileName.findRegexp("^sentence_([0-9]+)_voice_([0-9]+)\\.wav$");
        if(match.notEmpty) {
            var sentence = match[1][1].asInteger, voice = match[2][1].asInteger;
            if(config[\voiceIds].includes(voice)) {
                files[sentence] = (files[sentence] ?? { Dictionary.new }).put(voice, file.fullPath);
            };
        };
    };
    files
};

loadAlarm = {
    var directory = PathName(mediaPath +/+ "alarm"), paths = [], buffer;
    if(directory.isFolder) {
        paths = directory.files.select { |file| file.extension.toLower == "wav" }
            .collect(_.fullPath).sort;
    };
    if(paths.isEmpty) { paths = [mediaPath +/+ "alarm.wav"] };
    paths.do { |path|
        if(buffer.isNil) {
            var soundFile = SoundFile.openRead(path);
            if(soundFile.notNil) {
                if((soundFile.numFrames > 0) and: { [1, 2].includes(soundFile.numChannels) }) {
                    buffer = Buffer.read(server, path);
                    ("Peer alarm file: " ++ path).postln;
                };
                soundFile.close;
            };
        };
    };
    if(buffer.isNil) { "No readable mono/stereo alarm WAV; peer alarms are unavailable.".warn };
    buffer
};

// Stop the previous instance before replacing its OSC handlers and buffers.
if(~flockStop.notNil) { ~flockStop.value };
server = Server.default;
state = (
    stopped: false, group: nil, stopHook: nil,
    sentences: readSentences.value,
    buffers: Dictionary.new,      // sentence -> voice -> Buffer
    alarmBuffer: nil, alarmGroup: nil, lastAlarm: -inf,
    last: (person: 0, car: 0, flock: 0),  // last OSC value per address
    lastPlayed: (person: -inf, car: -inf, flock: -inf, monitored: -inf),
    position: (person: 0, car: 0, flock: 0, monitored: 0),
    retryPending: false,
    busyUntil: -inf
);

cleanup = { |fromCmdPeriod = false|
    if(state[\stopped].not) {
        state[\stopped] = true;
        addresses.keysDo { |event| OSCdef(("flockSpeech_" ++ event).asSymbol).free };
        OSCdef(\flockManualTrigger).free;
        OSCdef(\flockPeerAlarm).free;
        OSCdef(\flockPeerAlarmRelay).free;
        if(state[\stopHook].notNil) { CmdPeriod.remove(state[\stopHook]) };
        if(server.serverRunning) {
            // CmdPeriod itself frees the synths; do not free those nodes twice.
            if(fromCmdPeriod.not and: { state[\group].notNil }) { state[\group].free };
            if(fromCmdPeriod.not and: { state[\alarmGroup].notNil }) { state[\alarmGroup].free };
            if(state[\alarmBuffer].notNil) { state[\alarmBuffer].free };
            state[\buffers].do { |voices| voices.do(_.free) };
        };
        state[\buffers].clear;
        state[\alarmBuffer] = nil;
        "Flock speech stopped.".postln;
    };
};
~flockStop = { cleanup.value(false) };
state[\stopHook] = { cleanup.value(true) };
CmdPeriod.add(state[\stopHook]);

pickSentence = { |event|
    var numbers = (state[\sentences][event] ?? { [] }).select { |n| state[\buffers][n].notNil };
    var index;
    if(numbers.notEmpty) {
        if(config[\order] == \sequence) {
            index = state[\position][event] % numbers.size;
            state[\position][event] = index + 1;
            numbers[index]
        } {
            numbers.choose
        }
    }
};

pickVoice = { |sentence|
    // Choose afresh on every playback, using voices found for this sentence.
    state[\buffers][sentence].keys.asArray.choose
};

playSpeech = { |event, now|
    var sentence, voice, buffer;
    sentence = pickSentence.value(event);
    if(sentence.isNil) {
        ("skipped " ++ event ++ ": no speech files").postln;
    } {
        voice = pickVoice.value(sentence);
        buffer = state[\buffers][sentence][voice];
        Synth.tail(state[\group], ("flockSpeech" ++ buffer.numChannels).asSymbol, [
            \buf, buffer.bufnum, \amp, config[\amp], \out, config[\out]
        ]);
        state[\lastPlayed][event] = now;
        state[\busyUntil] = now + buffer.duration;
        ("played " ++ event ++ ": sentence " ++ sentence ++ " voice " ++ voice
            ++ " (" ++ buffer.duration.round(0.01) ++ " s)").postln;
    };
};

playAlarm = {
    var now = Main.elapsedTime;
    var buffer = state[\alarmBuffer];
    var remaining = state[\lastAlarm] + config[\alarmCooldown] - now;
    if(state[\stopped].not) {
        if(buffer.isNil) {
            "skipped peer alarm: no alarm WAV".postln;
        } {
            if(remaining > 0) {
                ("skipped peer alarm: cooldown, " ++ remaining.round(0.01) ++ " s left").postln;
            } {
                Synth.tail(state[\alarmGroup], ("flockSpeech" ++ buffer.numChannels).asSymbol, [
                    \buf, buffer.bufnum, \amp, config[\alarmAmp], \out, config[\out]
                ]);
                state[\lastAlarm] = now;
                "played peer alarm".postln;
            };
        };
    };
};

trigger = { |event|
    var now = Main.elapsedTime;
    var wait = state[\lastPlayed][event] + config[\cooldown][event] - now;
    case
    { config[\enabled][event].not } {
        ("skipped " ++ event ++ ": disabled").postln;
    }
    { now < state[\busyUntil] } {
        if((event == \monitored) and: { state[\retryPending].not }) {
            ("skipped " ++ event ++ ": busy, retrying when the speech ends").postln;
            state[\retryPending] = true;
            SystemClock.sched(state[\busyUntil] - now + 0.05, {
                state[\retryPending] = false;
                if(state[\stopped].not and: { state[\last][\person] != 0 } and: { state[\last][\flock] != 0 }) {
                    trigger.value(\monitored);
                };
                nil
            });
        } {
            ("skipped " ++ event ++ ": busy").postln;
        };
    }
    { wait > 0 } {
        ("skipped " ++ event ++ ": cooldown, " ++ wait.round(0.1) ++ " s left").postln;
    }
    { playSpeech.value(event, now) };
};

// A person and a Flock zone together become \monitored, whichever arrived first.
route = { |event|
    var other = (person: \flock, flock: \person)[event];
    if(other.notNil and: { state[\last][other] != 0 }) { \monitored } { event }
};

receive = { |event, value|
    var previous = state[\last][event];
    state[\last][event] = value;
    if((previous == 0) and: { value != 0 }) { trigger.value(route.value(event)) };
};

server.waitForBoot({
    var files = scanMedia.value;
    state[\alarmBuffer] = loadAlarm.value;

    state[\sentences].keysValuesDo { |event, numbers|
        numbers.do { |n|
            if(files[n].isNil) { ("no files for sentence " ++ n ++ " (" ++ event ++ ")").warn };
        };
    };
    config[\enabled].keysDo { |event|
        if(state[\sentences][event].isNil) { ("no sentences for event " ++ event).warn };
    };

    files.keysValuesDo { |sentence, voices|
        state[\buffers][sentence] = Dictionary.new;
        voices.keysValuesDo { |voice, path|
            state[\buffers][sentence][voice] = Buffer.read(server, path);
        };
    };

    // PlayBuf channel counts must be fixed when each SynthDef is built.
    [1, 2].do { |channels|
        SynthDef(("flockSpeech" ++ channels).asSymbol, { |out = 0, buf = 0, amp = 0.8|
            var sound = PlayBuf.ar(channels, buf, BufRateScale.kr(buf), loop: 0, doneAction: 2);
            if(channels == 1) { sound = sound ! 2 };
            Out.ar(out, sound * amp);
        }).add;
    };

    server.sync;  // Wait for buffers AND synth definitions before OSC.
    if(state[\alarmBuffer].notNil and: { state[\alarmBuffer].numFrames <= 0 }) {
        state[\alarmBuffer].free;
        state[\alarmBuffer] = nil;
        "Alarm buffer failed to load; peer alarms are unavailable.".warn;
    };
    if(state[\stopped].not) {
        state[\group] = Group.head(server);
        state[\alarmGroup] = Group.tail(server);  // manual speech replacement leaves alarms alone
        if(NetAddr.langPort != config[\oscPort]) {
            if(thisProcess.openUDPPort(config[\oscPort]).not) {
                ("Cannot open OSC port " ++ config[\oscPort]).warn;
            };
        };
        addresses.keysValuesDo { |event, path|
            OSCdef(("flockSpeech_" ++ event).asSymbol, { |msg|
                if(msg.size > 1 and: { msg[1].isNumber }) { receive.value(event, msg[1].asInteger) };
            }, path);
        };
        // Touchscreen commands are events, not camera/GPS presence states.
        // Each tap replaces current speech and bypasses automatic cooldowns.
        OSCdef(\flockManualTrigger, { |msg|
            var event;
            if(msg.size == 2) {
                if(["person", "car", "flock", "monitored"].includesEqual(msg[1].asString)) {
                    event = msg[1].asString.asSymbol;
                    if((state[\sentences][event] ?? { [] }).any { |n| state[\buffers][n].notNil }) {
                        state[\group].freeAll;
                        playSpeech.value(event, Main.elapsedTime);
                    } {
                        ("skipped manual " ++ event ++ ": no speech files").postln;
                    };
                };
            };
        }, "/flock/trigger", recvPort: config[\oscPort]);
        // Direct trigger path requested for peer zone entries.
        OSCdef(\flockPeerAlarm, { |msg| playAlarm.value },
            "/flock/peer/entered", recvPort: config[\oscPort]);
        // Existing flock_gps.py relay: [bikeID, 1, eventID] on local port 57120.
        // Keep 57122 owned by Python; sclang does not bind the peer network port.
        OSCdef(\flockPeerAlarmRelay, { |msg|
            if(msg.size >= 3 and: { msg[2] == 1 }) { playAlarm.value };
        }, "/location/flock/peer", recvPort: config[\oscPort]);
        ("Speech directory: " ++ mediaPath).postln;
        ("Flock speech ready: " ++ state[\buffers].size ++ " sentences, OSC ports "
            ++ thisProcess.openPorts.asArray.sort).postln;
    };
});
)

/*
OPTIONAL TEST: evaluate these lines ONE AT A TIME.

n = NetAddr("127.0.0.1", NetAddr.langPort);
n.sendMsg("/object/detected/person", 1);  // person only: plays person with a random voice
n.sendMsg("/object/detected/person", 1);  // same state, ignored
n.sendMsg("/object/detected/person", 0);
n.sendMsg("/object/detected/person", 1);  // skipped: busy or cooldown
n.sendMsg("/object/detected/person", 0);
n.sendMsg("/location/flock", 1);          // zone only: plays flock when idle
n.sendMsg("/object/detected/person", 1);  // person inside the zone: plays monitored
n.sendMsg("/flock/peer/entered", "2", "test-entry"); // alarm (2-second cooldown)
n.sendMsg("/location/flock/peer", "2", 1, "test-entry"); // same alarm via GPS relay
n.sendMsg("/location/flock", 0);
~flockStop.value;
*/
