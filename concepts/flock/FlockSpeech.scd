/*
BIKES Flocking: camera and GPS events -> spoken announcements

Speech files: <project>/media/flock/sentence_N_voice_M.wav (mono or stereo)
Which sentence belongs to which event: sentences.txt in this folder (N|event|text)
Each sentence has 28 voices numbered 1 through 28. Every accepted trigger
randomly selects an available voice for the selected sentence. Repeats are allowed.

OSC, one int argument, 1 = entered / present, 0 = left / absent:
    /object/detected/person   from flock_camera.py
    /object/detected/car      from flock_camera.py: car, truck or bus
    /object/detected/vehicle  from flock_camera.py: any other vehicle (no plate sentence)
    /flock/zone               from flock_gui.py's FLOCK ON/OFF button (zoneSource \gui)
    /location/flock           from flock_gps.py (zoneSource \gps only)
Senders resend the current state every 2 s. Only a 0 -> 1 change can trigger speech.
With zoneSource \gui (the default) the GPS zone is ignored: FLOCK ON means inside
a Flock camera zone, FLOCK OFF means outside every zone.

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

Echo: when an automatic event in config.echo.events has finished playing here,
this bike sends /flock/echo [STRING bike ID, STRING event, INT sentence, INT voice]
to the other bikes' sclang (UDP 57120). Each of them plays the same sentence, in
the same voice when it has that file, as soon as it is quiet. An echo that waits
longer than config.echo.maxWait is dropped, and a newer echo from the same bike
replaces an older one still waiting. Local speech always wins: a local trigger
stops an echo that is playing. Echoes are never sent on, so they cannot loop, and
they do not change local cooldowns or presence states. Only the configured peer
IPs are accepted. The bike ID comes from the bikesN user name.

Stop and release resources: ~flockStop.value;
Reevaluate the block to restart.
*/
(
var config, addresses, scriptPath, mediaPath, sentencesPath, server, state;
var readSentences, scanMedia, cleanup, pickSentence, pickVoice, playSpeech, trigger, route, receive;
var loadAlarm, playAlarm;
var findBikeId, sendEcho, stopEcho, playEcho, drainEchoes, receiveEcho;

config = (
    oscPort: 57120,            // sclang receiver, not scsynth's 57110
    amp: 0.8,
    alarmAmp: 0.8,
    alarmCooldown: 2.0,        // shared by all peer notifications, seconds from start
    out: 0,                    // stereo output channels 0 and 1
    cooldown: (person: 1, car: 1, vehicle: 1, flock: 1, monitored: 1),  // seconds per event, from the start of its last play
    enabled: (person: true, car: true, vehicle: true, flock: true, monitored: true),  // stationary vs moving mode
    voiceIds: (1..28),         // 28 voices, filenames numbered 1-28; use (0..27) for 0-27
    order: \random,            // \random, or \sequence through the event's sentences
    zoneSource: \gui,          // \gui: FLOCK ON/OFF on the touchscreen, \gps: flock_gps.py
    echo: (
        enabled: true,                        // send and accept echoes
        events: [\person, \car, \vehicle, \monitored],  // automatic events the other bikes repeat
        manual: false,                        // true: touchscreen taps are echoed too
        sameVoice: true,                      // false: each bike picks its own voice
        maxWait: 10,                          // seconds an echo may wait for silence here
        amp: 0.8,
        port: 57120,                          // the other bikes' sclang port
        peers: ["10.10.10.11", "10.10.10.12", "10.10.10.13", "10.10.10.14"]  // bikes 1-4
    )
);

addresses = (
    person: "/object/detected/person",
    car: "/object/detected/car",
    vehicle: "/object/detected/vehicle",
    flock: (gui: "/flock/zone", gps: "/location/flock")[config[\zoneSource]]
);
if(addresses[\flock].isNil) { Error("config.zoneSource must be \\gui or \\gps").throw };

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

// The hostname is the same on every bike, so use the bikesN user (as flock_gps.py does).
findBikeId = {
    var id;
    ["USER".getenv, "HOME".getenv !? { |home| PathName(home).fileName }].do { |name|
        if(id.isNil and: { name.notNil } and: { "^bikes[0-9]+$".matchRegexp(name) }) {
            var number = name.drop(5).asInteger;
            if((number >= 1) and: { number <= config[\echo][\peers].size }) { id = number };
        };
    };
    id
};

// Stop the previous instance before replacing its OSC handlers and buffers.
if(~flockStop.notNil) { ~flockStop.value };
server = Server.default;
state = (
    stopped: false, group: nil, stopHook: nil,
    sentences: readSentences.value,
    buffers: Dictionary.new,      // sentence -> voice -> Buffer
    alarmBuffer: nil, alarmGroup: nil, lastAlarm: -inf,
    last: (person: 0, car: 0, vehicle: 0, flock: 0),  // last OSC value per address
    lastPlayed: (person: -inf, car: -inf, vehicle: -inf, flock: -inf, monitored: -inf),
    position: (person: 0, car: 0, vehicle: 0, flock: 0, monitored: 0),
    retryPending: false,
    busyUntil: -inf,              // end of this bike's own speech
    speechCount: 0,               // tells a scheduled echo whether its speech was replaced
    bikeId: findBikeId.value,
    peers: [], peerIds: [],       // NetAddr and number of every other bike
    echoGroup: nil,
    echoUntil: -inf,              // end of the echo playing here
    echoQueue: List.new,          // echoes from other bikes waiting for silence
    drainPending: false
);
if(state[\bikeId].isNil) {
    "Cannot tell which bike this is (no bikesN user), so no echoes are sent.".warn;
} {
    config[\echo][\peers].do { |ip, index|
        if(index + 1 != state[\bikeId]) {
            state[\peers] = state[\peers].add(NetAddr(ip, config[\echo][\port]));
            state[\peerIds] = state[\peerIds].add(index + 1);
        };
    };
};

cleanup = { |fromCmdPeriod = false|
    if(state[\stopped].not) {
        state[\stopped] = true;
        addresses.keysDo { |event| OSCdef(("flockSpeech_" ++ event).asSymbol).free };
        OSCdef(\flockManualTrigger).free;
        OSCdef(\flockPeerAlarm).free;
        OSCdef(\flockPeerAlarmRelay).free;
        OSCdef(\flockEcho).free;
        state[\echoQueue].clear;
        if(state[\stopHook].notNil) { CmdPeriod.remove(state[\stopHook]) };
        if(server.serverRunning) {
            // CmdPeriod itself frees the synths; do not free those nodes twice.
            if(fromCmdPeriod.not and: { state[\group].notNil }) { state[\group].free };
            if(fromCmdPeriod.not and: { state[\echoGroup].notNil }) { state[\echoGroup].free };
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

// Once this speech has played to the end, ask every other bike to repeat it.
sendEcho = { |event, sentence, voice, delay, speech|
    SystemClock.sched(delay, {
        if(state[\stopped].not) {
            if(state[\speechCount] == speech) {
                state[\peers].do { |address|
                    try {
                        address.sendMsg("/flock/echo", state[\bikeId].asString, event.asString, sentence, voice);
                    } { |error|
                        ("could not send echo to " ++ address.ip ++ ": " ++ error.errorString).postln;
                    };
                };
                ("sent echo " ++ event ++ ": sentence " ++ sentence ++ " voice " ++ voice
                    ++ " to bikes " ++ state[\peerIds]).postln;
            } {
                ("no echo for " ++ event ++ ": its speech was replaced").postln;
            };
        };
        nil
    });
};

stopEcho = {
    if(Main.elapsedTime < state[\echoUntil]) {
        state[\echoGroup].freeAll;
        "stopped echo: local speech".postln;
    };
    state[\echoUntil] = -inf;
};

playSpeech = { |event, now, manual = false|
    var sentence, voice, buffer;
    sentence = pickSentence.value(event);
    if(sentence.isNil) {
        ("skipped " ++ event ++ ": no speech files").postln;
    } {
        voice = pickVoice.value(sentence);
        buffer = state[\buffers][sentence][voice];
        stopEcho.value;  // this bike's own speech wins over another bike's echo
        Synth.tail(state[\group], ("flockSpeech" ++ buffer.numChannels).asSymbol, [
            \buf, buffer.bufnum, \amp, config[\amp], \out, config[\out]
        ]);
        state[\lastPlayed][event] = now;
        state[\busyUntil] = now + buffer.duration;
        state[\speechCount] = state[\speechCount] + 1;
        ("played " ++ event ++ ": sentence " ++ sentence ++ " voice " ++ voice
            ++ " (" ++ buffer.duration.round(0.01) ++ " s)").postln;
        if(config[\echo][\enabled] and: { state[\peers].notEmpty }
            and: { config[\echo][\events].includes(event) }
            and: { manual.not or: { config[\echo][\manual] } }) {
            sendEcho.value(event, sentence, voice, buffer.duration, state[\speechCount]);
        };
    };
};

playEcho = { |item, now|
    var voices = state[\buffers][item[\sentence]], voice, buffer;
    if(voices.isNil or: { voices.isEmpty }) {
        ("skipped echo from bike " ++ item[\from] ++ ": no files for sentence " ++ item[\sentence]).postln;
    } {
        voice = if(config[\echo][\sameVoice] and: { voices[item[\voice]].notNil }) {
            item[\voice]
        } {
            voices.keys.asArray.choose
        };
        buffer = voices[voice];
        Synth.tail(state[\echoGroup], ("flockSpeech" ++ buffer.numChannels).asSymbol, [
            \buf, buffer.bufnum, \amp, config[\echo][\amp], \out, config[\out]
        ]);
        state[\echoUntil] = now + buffer.duration;
        ("echoed bike " ++ item[\from] ++ " " ++ item[\event] ++ ": sentence " ++ item[\sentence]
            ++ " voice " ++ voice ++ " (" ++ buffer.duration.round(0.01) ++ " s)").postln;
    };
};

// Play waiting echoes one at a time whenever this bike is quiet.
drainEchoes = {
    var now = Main.elapsedTime, until;
    state[\echoQueue] = state[\echoQueue].reject { |item|
        var stale = (now - item[\received]) > config[\echo][\maxWait];
        if(stale) {
            ("dropped echo from bike " ++ item[\from] ++ " " ++ item[\event]
                ++ ": waited over " ++ config[\echo][\maxWait] ++ " s").postln;
        };
        stale
    };
    if(state[\stopped].not and: { state[\echoQueue].notEmpty }) {
        until = max(state[\busyUntil], state[\echoUntil]);
        if(now >= until) {
            playEcho.value(state[\echoQueue].removeAt(0), now);
            until = state[\echoUntil];
        };
        if(state[\echoQueue].notEmpty and: { state[\drainPending].not }) {
            state[\drainPending] = true;
            SystemClock.sched(max(0, until - now) + 0.05, {
                state[\drainPending] = false;
                drainEchoes.value;
                nil
            });
        };
    };
};

receiveEcho = { |msg, addr|
    var from, event;
    if(msg.size >= 5 and: { msg[3].isInteger } and: { msg[4].isInteger }) {
        from = msg[1].asString.asInteger;
        // Only a configured bike, from its own address, and never this bike itself.
        if((from != state[\bikeId]) and: { from >= 1 }
            and: { config[\echo][\peers][from - 1] == addr.ip }) {
            event = msg[2].asString.asSymbol;
            state[\echoQueue] = state[\echoQueue].reject { |item| item[\from] == from };
            state[\echoQueue].add((from: from, event: event, sentence: msg[3], voice: msg[4],
                received: Main.elapsedTime));
            ("echo request from bike " ++ from ++ ": " ++ event ++ " sentence " ++ msg[3]
                ++ " voice " ++ msg[4]).postln;
            drainEchoes.value;
        };
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
    var files = scanMedia.value, count = 0, requeried = 0;
    state[\alarmBuffer] = loadAlarm.value;

    state[\sentences].keysValuesDo { |event, numbers|
        numbers.do { |n|
            if(files[n].isNil) { ("no files for sentence " ++ n ++ " (" ++ event ++ ")").warn };
        };
    };
    config[\enabled].keysDo { |event|
        if(state[\sentences][event].isNil) { ("no sentences for event " ++ event).warn };
    };

    // Small batches: reading all ~200 files at once floods sclang with /b_info
    // replies, and on some bikes a few get lost, leaving buffers with no size.
    files.keysValuesDo { |sentence, voices|
        state[\buffers][sentence] = Dictionary.new;
        voices.keysValuesDo { |voice, path|
            state[\buffers][sentence][voice] = Buffer.read(server, path);
            count = count + 1;
            if(count % 16 == 0) { server.sync };
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
    // A buffer whose /b_info reply was lost has no numFrames: ask again, then drop it.
    3.do {
        var missing = List.new;
        state[\buffers].do { |voices| voices.do { |buffer| if(buffer.numFrames.isNil) { missing.add(buffer) } } };
        if(state[\alarmBuffer].notNil and: { state[\alarmBuffer].numFrames.isNil }) { missing.add(state[\alarmBuffer]) };
        if(missing.notEmpty) {
            requeried = requeried + missing.size;
            missing.do(_.updateInfo);
            server.sync;
        };
    };
    if(requeried > 0) { ("asked the server again for " ++ requeried ++ " buffer sizes").postln };
    state[\buffers].keys.asArray.do { |sentence|
        var voices = state[\buffers][sentence];
        voices.keys.asArray.do { |voice|
            var buffer = voices[voice];
            if(buffer.numFrames.isNil or: { buffer.numFrames <= 0 }) {
                ("sentence " ++ sentence ++ " voice " ++ voice ++ " did not load; skipping it").warn;
                buffer.free;
                voices.removeAt(voice);
            };
        };
        if(voices.isEmpty) { state[\buffers].removeAt(sentence) };
    };
    if(state[\alarmBuffer].notNil and: { state[\alarmBuffer].numFrames.isNil or: { state[\alarmBuffer].numFrames <= 0 } }) {
        state[\alarmBuffer].free;
        state[\alarmBuffer] = nil;
        "Alarm buffer failed to load; peer alarms are unavailable.".warn;
    };
    if(state[\stopped].not) {
        state[\group] = Group.head(server);
        state[\echoGroup] = Group.after(state[\group]);
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
                if(["person", "car", "vehicle", "flock", "monitored"].includesEqual(msg[1].asString)) {
                    event = msg[1].asString.asSymbol;
                    if((state[\sentences][event] ?? { [] }).any { |n| state[\buffers][n].notNil }) {
                        state[\group].freeAll;
                        playSpeech.value(event, Main.elapsedTime, true);
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
        // Another bike finished a sentence and asks this one to repeat it.
        OSCdef(\flockEcho, { |msg, time, addr|
            if(config[\echo][\enabled]) { receiveEcho.value(msg, addr) };
        }, "/flock/echo", recvPort: config[\oscPort]);
        ("Speech directory: " ++ mediaPath).postln;
        ("Flock zone from " ++ addresses[\flock] ++ " ("
            ++ (gui: "FLOCK ON/OFF button", gps: "GPS")[config[\zoneSource]] ++ ")").postln;
        ("Bike " ++ (state[\bikeId] ? "unknown") ++ ", echoes "
            ++ (if(config[\echo][\enabled]) {
                "to bikes " ++ state[\peerIds] ++ " for " ++ config[\echo][\events]
            } { "off" })).postln;
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
n.sendMsg("/flock/zone", 1);              // FLOCK ON: plays flock when idle
n.sendMsg("/object/detected/person", 1);  // person inside the zone: plays monitored, then echoes it
n.sendMsg("/flock/peer/entered", "2", "test-entry"); // alarm (2-second cooldown)
n.sendMsg("/location/flock/peer", "2", 1, "test-entry"); // same alarm via GPS relay
n.sendMsg("/flock/zone", 0);              // FLOCK OFF
// An echo is accepted only from the sending bike's own IP, so test it from another bike:
//   python3 -c "from pythonosc.udp_client import SimpleUDPClient as C; C('10.10.10.11', 57120).send_message('/flock/echo', ['2', 'person', 1, 5])"
~flockStop.value;
*/
