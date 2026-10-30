/* BIKES GPS-controlled local file player.
   sclang GPSListener.scd marine 4 /path/to/gps_motion.ready 0.3 0.2 0.22
   /motion [kind, number, eventID, sourceBike, acceleration, turnRate]
   /rhythmRate [rate, defaultRate, returnTime, glideTime]
   Peer matching is performed by PixelGPS.py; this script receives local OSC.
*/
(
var args = thisProcess.argv;
var failed = false;

// Replace this module's previous stop handler instead of accumulating callbacks.
if(~gpsCmdPeriodCleanup.notNil) {
    CmdPeriod.remove(~gpsCmdPeriodCleanup);
    ~gpsCmdPeriodCleanup = nil;
};
if(~gpsCleanup.notNil) { ~gpsCleanup.value(false) };

~soundscape = if(args.size > 0) { args[0] } { "marine" };
~sampleCount = if(args.size > 1) { args[1].asInteger } { 4 };
~readyFile = if(args.size > 2) { args[2] } { nil };
~amp = if(args.size > 3) { args[3].asFloat } { 0.3 };
~fadeTime = if(args.size > 4) { args[4].asFloat } { 0.2 };
~rhythmAmp = if(args.size > 5) { args[5].asFloat } { 0.22 };
~absolutePrefix = thisProcess.nowExecutingPath.dirname;
~absolute = ~absolutePrefix +/+ "../../media/gps_motion/samples" +/+ ~soundscape;
~host = "whoami".unixCmdGetStdOut.stripWhiteSpace;
~motionTypes = ["accelerate", "decelerate", "turn_left", "turn_right"];
~buffers = Dictionary.new;
~activeSynth = nil;
~baseSynth = nil;
~currentRate = 1.0;
~defaultRate = 1.0;
~rateReturnTime = 4.0;
~lastRateTime = Main.elapsedTime;
~gpsRateWatchdog = nil;
~seenEvents = List.new;
~lastEventID = nil;

// Idempotent cleanup. Ctrl+. already frees synth nodes on the server, so its
// callback must not send a second /n_free. Buffer.free clears bufnum locally.
~gpsCleanup = { |fromCmdPeriod=false|
    OSCdef(\gpsMotionListener).free;
    OSCdef(\gpsRhythmRateListener).free;
    if(~gpsRateWatchdog.notNil) {
        ~gpsRateWatchdog.stop;
        ~gpsRateWatchdog = nil;
    };
    if(~activeSynth.notNil) {
        if(fromCmdPeriod.not and: { ~activeSynth.isPlaying == true }) {
            ~activeSynth.free;
        };
        ~activeSynth = nil;
    };
    if(~baseSynth.notNil) {
        if(fromCmdPeriod.not and: { ~baseSynth.isPlaying == true }) {
            ~baseSynth.free;
        };
        ~baseSynth = nil;
    };
    ~buffers.values.do { |b|
        if(b.bufnum.notNil) { b.free };
    };
    ~buffers.clear;
    if(~readyFile.notNil and: { File.exists(~readyFile) }) { File.delete(~readyFile) };
};
~gpsCmdPeriodCleanup = { ~gpsCleanup.value(true) };
CmdPeriod.add(~gpsCmdPeriodCleanup);

if(~sampleCount <= 0 or: { ~amp <= 0 } or: { ~fadeTime <= 0 }) {
    "Invalid sampleCount, amp or fadeTime".error;
    1.exit;
};
if(~readyFile.notNil and: { File.exists(~readyFile) }) { File.delete(~readyFile) };

s.waitForBoot({
    var specifications, path, buffer;
    specifications = List.new;
    ~rhythmPath = ~absolute +/+ "rhythm/0.wav";
    if(File.exists(~rhythmPath).not) {
        ~rhythmPath = ~absolute +/+ "base/0.wav";
        "rhythm/0.wav unavailable; using the previous base/0.wav as the rhythm loop".warn;
    };
    specifications.add(["rhythm/0", ~rhythmPath]);
    ~motionTypes.do { |kind|
        ~sampleCount.do { |number|
            specifications.add([kind ++ "/" ++ number.asString,
                ~absolute +/+ kind +/+ (number.asString ++ ".wav")]);
        };
    };

    // Preload once: no disk loading or Buffer allocation on each GPS event.
    specifications.do { |entry|
        path = entry[1];
        if(File.exists(path).not) {
            ("Missing audio: " ++ path).error;
            failed = true;
        } {
            buffer = Buffer.read(s, path);
            s.sync;
            if(buffer.numFrames <= 0 or: {
                (buffer.numChannels != 1) and: { buffer.numChannels != 2 }
            }) {
                ("Audio must be readable mono/stereo WAV: " ++ path).error;
                buffer.free;
                failed = true;
            } {
                ~buffers[entry[0]] = buffer;
            };
        };
    };
    if(failed) {
        ~gpsCleanup.value(false);
        1.exit;
    };

    SynthDef(\gps_player_mono, { |out=0, buf=0, amp=0.3, gate=1, fadeTime=0.2, rate=1, rateLag=0.12|
        var playbackRate = Lag.kr(rate, rateLag).clip(0.1, 4.0);
        var sig = PlayBuf.ar(1, buf, BufRateScale.kr(buf) * playbackRate, loop: 1);
        var env = EnvGen.kr(Env.asr(fadeTime, 1, fadeTime), gate, doneAction: 2);
        Out.ar(out, (sig * env * amp) ! 2);
    }).add;
    SynthDef(\gps_player_stereo, { |out=0, buf=0, amp=0.3, gate=1, fadeTime=0.2, rate=1, rateLag=0.12|
        var playbackRate = Lag.kr(rate, rateLag).clip(0.1, 4.0);
        var sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf) * playbackRate, loop: 1);
        var env = EnvGen.kr(Env.asr(fadeTime, 1, fadeTime), gate, doneAction: 2);
        Out.ar(out, sig * env * amp);
    }).add;
    s.sync;

    // The rhythmic bed has its own player and survives motion sample switches.
    ~startRhythm = {
        var song = ~buffers["rhythm/0"];
        var songInstr, player;
        if(song.notNil and: { ~baseSynth.isNil }) {
            songInstr = if(song.numChannels == 1) { \gps_player_mono } { \gps_player_stereo };
            player = Synth(songInstr, [\buf, song.bufnum, \amp, ~rhythmAmp,
                \fadeTime, ~fadeTime, \rate, ~currentRate]);
            player.register(true);
            ~baseSynth = player;
            player.onFree({ if(~baseSynth === player) { ~baseSynth = nil } });
            ("Rhythm loop: " ++ ~rhythmPath).postln;
        };
    };

    ~setRhythmRate = { |rate=1.0, normalRate=1.0, returnTime=4.0, glideTime=0.12|
        ~currentRate = rate.clip(0.1, 4.0);
        ~defaultRate = normalRate.clip(0.1, 4.0);
        ~rateReturnTime = returnTime.clip(0.1, 60.0);
        ~lastRateTime = Main.elapsedTime;
        if(~baseSynth.notNil and: { ~baseSynth.isPlaying == true }) {
            ~baseSynth.set(\rate, ~currentRate, \rateLag, glideTime.clip(0.01, 60.0));
        };
    };

    ~rSound = { |key|
        var song = ~buffers[key];
        var songInstr, player;
        if(["base/0", "rhythm/0"].includes(key)) {
            if(~activeSynth.notNil and: { ~activeSynth.isPlaying == true }) {
                ~activeSynth.set(\gate, 0);
            };
            ~activeSynth = nil;
            ~startRhythm.();
        } {
          if(song.notNil) {
            songInstr = if(song.numChannels == 1) { \gps_player_mono } { \gps_player_stereo };
            if(~activeSynth.notNil and: { ~activeSynth.isPlaying == true }) {
                ~activeSynth.set(\gate, 0);
            };
            player = Synth(songInstr, [\buf, song.bufnum, \amp, ~amp, \fadeTime, ~fadeTime]);
            player.register(true);
            ~activeSynth = player;
            player.onFree({
                if(~activeSynth === player) { ~activeSynth = nil };
            });
            ("Bike " ++ ~host ++ " playing " ++ key ++ ".wav").postln;
        } {
            ("Unknown audio key: " ++ key).warn;
          };
        };
    };

    OSCdef(\gpsRhythmRateListener, { |msg|
        if(msg.size >= 5) {
            ~setRhythmRate.(msg[1].asFloat, msg[2].asFloat, msg[3].asFloat, msg[4].asFloat);
        };
    }, "/rhythmRate", NetAddr("127.0.0.1", nil), recvPort: 57120);

    OSCdef(\gpsMotionListener, { |msg|
    var kind, number, eventID, sourceBike, key;

    ("Received /motion: " ++ msg.asString).postln;

    if(msg.size >= 7) {
        kind = msg[1].asString;
        number = msg[2].asInteger;
        eventID = msg[3].asString;
        sourceBike = msg[4].asString;

        if(
            ~motionTypes.includesEqual(kind)
            and: { number >= 0 }
            and: { number < ~sampleCount }
        ) {
            if(~seenEvents.includesEqual(eventID).not) {
                key = kind ++ "/" ++ number.asString;

                ~seenEvents.add(eventID);
                if(~seenEvents.size > 128) {
                    ~seenEvents.removeAt(0);
                };
                ~lastEventID = eventID;

                ("Accepted motion: " ++ key
                    ++ "; sourceBike=" ++ sourceBike).postln;

                ~rSound.(key);
            } {
                ("Ignored duplicate event: " ++ eventID).postln;
            };
        } {
            ("Rejected motion: kind=" ++ kind
                ++ "; number=" ++ number).warn;
        };
    } {
        ("Malformed /motion: " ++ msg.asString).warn;
    };
}, "/motion", NetAddr("127.0.0.1", nil), recvPort: 57120);

    ~startRhythm.();
    // Return to default if Python crashes or rate heartbeats stop arriving.
    ~gpsRateWatchdog = Routine({
        loop {
            0.2.wait;
            if((Main.elapsedTime - ~lastRateTime > 2.0) and: {
                ~currentRate != ~defaultRate
            }) {
                ~currentRate = ~defaultRate;
                if(~baseSynth.notNil and: { ~baseSynth.isPlaying == true }) {
                    ~baseSynth.set(\rate, ~defaultRate, \rateLag, ~rateReturnTime);
                };
                "Rhythm heartbeat timed out; returning to default rate".postln;
            };
        };
    }).play(AppClock);
    if(~readyFile.notNil) {
        File.use(~readyFile, "w", { |file| file.write("ready\n") });
    };
    "GPSListener READY; listening for local /motion on UDP 57120".postln;
});
) 