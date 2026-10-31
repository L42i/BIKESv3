/*
BIKES Flocking: camera and GPS events -> spoken announcements

Speech files: <project>/media/flock/sentence_N_voice_M.wav (mono or stereo)
Which sentence belongs to which event: sentences.txt in this folder (N|event|text)

OSC, one int argument, 1 = entered / present, 0 = left / absent:
    /object/detected/person   from flock_camera.py
    /object/detected/car      from flock_camera.py
    /location/flock           from flock_gps.py
Senders resend the current state every 2 s. Only a 0 -> 1 change can trigger speech.

A trigger plays one sentence if its event is enabled, its cooldown has passed
and nothing else is speaking. Every decision goes to the post window.

Stop and release resources: ~flockStop.value;
Reevaluate the block to restart.
*/
(
var config, addresses, scriptPath, mediaPath, sentencesPath, bike, server, state;
var readSentences, scanMedia, cleanup, pickSentence, pickVoice, playSpeech, trigger, receive;

config = (
    oscPort: 57120,            // sclang receiver, not scsynth's 57110
    amp: 0.8,
    out: 0,                    // stereo output channels 0 and 1
    cooldown: (person: 8, car: 8, flock: 20),  // seconds per event
    enabled: (person: true, car: true, flock: true),  // stationary vs moving mode
    voiceMode: \random,        // \random, or \bike: voice number = bike number
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
bike = "whoami".unixCmdGetStdOut.select(_.isDecDigit).asInteger;

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
        var match = file.fileName.findRegexp("^sentence_([0-9]+)_voice_([0-9]+)\\.wav$");
        if(match.notEmpty) {
            var sentence = match[1][1].asInteger, voice = match[2][1].asInteger;
            files[sentence] = (files[sentence] ?? { Dictionary.new }).put(voice, file.fullPath);
        };
    };
    files
};

// Stop the previous instance before replacing its OSC handlers and buffers.
if(~flockStop.notNil) { ~flockStop.value };
server = Server.default;
state = (
    stopped: false, group: nil, stopHook: nil,
    sentences: readSentences.value,
    buffers: Dictionary.new,      // sentence -> voice -> Buffer
    last: (person: 0, car: 0, flock: 0),
    lastPlayed: (person: -inf, car: -inf, flock: -inf),
    position: (person: 0, car: 0, flock: 0),
    busyUntil: -inf
);

cleanup = { |fromCmdPeriod = false|
    if(state[\stopped].not) {
        state[\stopped] = true;
        addresses.keysDo { |event| OSCdef(("flockSpeech_" ++ event).asSymbol).free };
        if(state[\stopHook].notNil) { CmdPeriod.remove(state[\stopHook]) };
        if(server.serverRunning) {
            // CmdPeriod itself frees the synths; do not free those nodes twice.
            if(fromCmdPeriod.not and: { state[\group].notNil }) { state[\group].free };
            state[\buffers].do { |voices| voices.do(_.free) };
        };
        state[\buffers].clear;
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
    var voices = state[\buffers][sentence];
    if((config[\voiceMode] == \bike) and: { voices[bike].notNil }) {
        bike
    } {
        voices.keys.asArray.choose
    }
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

trigger = { |event|
    var now = Main.elapsedTime;
    var wait = state[\lastPlayed][event] + config[\cooldown][event] - now;
    case
    { config[\enabled][event].not } {
        ("skipped " ++ event ++ ": disabled").postln;
    }
    { now < state[\busyUntil] } {
        ("skipped " ++ event ++ ": busy").postln;
    }
    { wait > 0 } {
        ("skipped " ++ event ++ ": cooldown, " ++ wait.round(0.1) ++ " s left").postln;
    }
    { playSpeech.value(event, now) };
};

receive = { |event, value|
    var previous = state[\last][event];
    state[\last][event] = value;
    if((previous == 0) and: { value != 0 }) { trigger.value(event) };
};

server.waitForBoot({
    var files = scanMedia.value;

    state[\sentences].keysValuesDo { |event, numbers|
        numbers.do { |n|
            if(files[n].isNil) { ("no files for sentence " ++ n ++ " (" ++ event ++ ")").warn };
        };
    };
    addresses.keysDo { |event|
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
    if(state[\stopped].not) {
        state[\group] = Group.head(server);
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
        ("Speech directory: " ++ mediaPath).postln;
        ("Flock speech ready: " ++ state[\buffers].size ++ " sentences, OSC ports "
            ++ thisProcess.openPorts.asArray.sort).postln;
    };
});
)

/*
OPTIONAL TEST: evaluate these lines ONE AT A TIME.

n = NetAddr("127.0.0.1", NetAddr.langPort);
n.sendMsg("/object/detected/person", 1);  // plays
n.sendMsg("/object/detected/person", 1);  // same state, ignored
n.sendMsg("/object/detected/person", 0);
n.sendMsg("/object/detected/person", 1);  // skipped: busy or cooldown
n.sendMsg("/location/flock", 1);          // plays, once nothing is speaking
~flockStop.value;
*/
