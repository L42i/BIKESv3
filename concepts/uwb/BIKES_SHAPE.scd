(
s.waitForBoot({

    var win, padView, muteButtons, muteButton;
    var padRect, dragRadius;
    var serialPort, serialRunning;
    var screen;
    var who;

    dragRadius = 18;
    screen = Window.screenBounds;

    ~myName = "";
    ~nextPeer = "";

    who = "whoami".unixCmdGetStdOut;
    if(who.contains("bikes1")) { ~myName = "1"; ~nextPeer = "2"; };
    if(who.contains("bikes2")) { ~myName = "2"; ~nextPeer = "3"; };
    if(who.contains("bikes3")) { ~myName = "3"; ~nextPeer = "4"; };
    if(who.contains("bikes4")) { ~myName = "4"; ~nextPeer = "1"; };

    if(~myName == "") {
        "ERROR: hostname not recognized, GUI will malfunction".postln
    };

    ("My bike name: " ++ ~myName).postln;
    ("Next peer: " ++ ~nextPeer).postln;

    s.meter;

    ~numStems        = 4;
    ~maxRange        = 5.0;
    ~currentMode     = \words;
    ~previousMode    = nil;
    ~mySlot          = ~myName.asInteger;
    ~isActive        = false;
    ~lastPingTime    = Main.elapsedTime;
    ~loopSynth       = nil;
    ~lastLoopMode    = nil;
    ~proximityThresh = 5.0;
    ~isMuted         = false;
    ~alphabetPlaying = false;

    // ---------- distance helpers ----------
    ~distToDelay = { |distMeters|
        var minDist  = 3.4;
        var maxDist  = 90.0;
        var maxDelay = 10.0;
        if(distMeters <= minDist) {
            0.0
        } {
            distMeters.linlin(minDist, maxDist, 0.0, maxDelay).clip(0, maxDelay)
        };
    };

    ~getDelayToNext = {
        var nextSlot = ~nextPeer.asInteger;
        var dist = ~distMatrix[~mySlot - 1][nextSlot - 1];
        if(dist > 0) { ~distToDelay.(dist) } { 0.0 };
    };

    ~isNearNeighbor = {
        var nextSlot = ~nextPeer.asInteger;
        var dist = ~distMatrix[~mySlot - 1][nextSlot - 1];
        (dist > 0) and: { dist < ~proximityThresh }
    };

    ~isNearEither = {
        var nextSlot = ~nextPeer.asInteger;
        var prevSlot = ((~mySlot - 2) % 4) + 1;
        var distToNext = ~distMatrix[~mySlot - 1][nextSlot - 1];
        var distToPrev = ~distMatrix[~mySlot - 1][prevSlot - 1];
        var nextClose = (distToNext > 0) and: { distToNext < ~proximityThresh };
        var prevClose = (distToPrev > 0) and: { distToPrev < ~proximityThresh };
        nextClose or: prevClose
    };

    ~distToFreq = {
        var nextSlot = ~nextPeer.asInteger;
        var prevSlot = ((~mySlot - 2) % 4) + 1;
        var distToNext = ~distMatrix[~mySlot - 1][nextSlot - 1];
        var distToPrev = ~distMatrix[~mySlot - 1][prevSlot - 1];
        var nextClose = (distToNext > 0) and: { distToNext < ~proximityThresh };
        var prevClose = (distToPrev > 0) and: { distToPrev < ~proximityThresh };

        if(nextClose or: prevClose) {
            200  // locked at base — at least one leg is close
        } {
            // both legs far — use closer of the two to drive frequency up
            var dist = if((distToPrev > 0) and: (distToNext > 0)) {
                distToPrev.min(distToNext)
            } {
                if(distToPrev > 0) { distToPrev } { distToNext }
            };
            dist.linlin(~proximityThresh, 90, 200, 2000).clip(200, 2000)
        };
    };

    ~isNearNeighbor = {
        var nextSlot = ~nextPeer.asInteger;
        var dist = ~distMatrix[~mySlot - 1][nextSlot - 1];
        (dist > 0) and: { dist < ~proximityThresh }
    };

    ~bufForMode = {
        switch(~currentMode,
            \words,        { ~wordsBuf },
            \birds,        { ~birdsBuf },
            \alphabetSoup, {
                var loaded = ~alphabetBufs.select({ |b| b.notNil });
                if(loaded.size > 0) { loaded.choose } { nil }
            },
            { nil }
        )
    };

    // ---------- mode switching ----------
    ~setMode = { |modeSym|
        if(modeSym == \mute) {
            if(~currentMode != \mute) { ~previousMode = ~currentMode };
            ~currentMode = \mute;
            ~isMuted = true;
            if(~loopSynth.notNil) {
                ~loopSynth.free;
                ~loopSynth = nil;
                ~lastLoopMode = nil;
            };
            ~alphabetPlaying = false;
        } {
            ~currentMode = modeSym;
            ~isMuted = false;
        };
        {
            muteButtons[0].value = if(~currentMode == \alphabetSoup) { 1 } { 0 };
            muteButtons[1].value = if(~currentMode == \birds)        { 1 } { 0 };
            muteButtons[2].value = if(~currentMode == \words)        { 1 } { 0 };
            muteButtons[3].value = if(~currentMode == \hertz)        { 1 } { 0 };
            muteButton.value     = if(~currentMode == \mute)         { 1 } { 0 };
        }.defer;
        ("Mode changed to: " ++ modeSym).postln;
        ~updateLoop.();
    };

    ~broadcastMode = { |modeSym|
        ~setMode.(modeSym);
        [1,2,3,4].do { |slot|
            if(slot.asString != ~myName) {
                p.sendMsg("/" ++ slot ++ "/mode", modeSym.asString);
            };
        };
    };

    // ---------- SynthDefs ----------
    SynthDef(\bikePing, {
        |out=0, freq=440, amp=0.5, rel=0.99|
        var env, sig;
        env = EnvGen.kr(Env.perc(releaseTime: rel), doneAction: 2);
        sig = SinOsc.ar(freq) * env * amp;
        Out.ar(out, [sig, sig]);
    }).add;

    SynthDef(\sampleOnce, {
        |out=0, bufnum=0, amp=0.8|
        var sig;
        sig = PlayBuf.ar(2, bufnum, BufRateScale.kr(bufnum), doneAction: 2);
        Out.ar(out, sig * amp);
    }).add;

    SynthDef(\sampleLoop, {
        |out=0, bufnum=0, amp=0.8, fadeTime=0.05|
        var sig;
        sig = PlayBuf.ar(2, bufnum, BufRateScale.kr(bufnum), loop: 1);
        sig = sig * amp * EnvGen.kr(Env.asr(fadeTime, 1, fadeTime), 1);
        Out.ar(out, sig);
    }).add;

    SynthDef(\sineLoop, {
        |out=0, freq=200, amp=0.3|
        var sig;
        sig = SinOsc.ar(freq.lag(0.5)) * amp;
        Out.ar(out, [sig, sig]);
    }).add;

    s.sync;

    // ---------- buffer management ----------
    ~freeBuffer = { |buf|
        if(buf.notNil) { buf.free };
    };

    ~freeAllBuffers = {
        ~freeBuffer.(~wordsBuf);
        ~freeBuffer.(~birdsBuf);
        ~alphabetBufs.do { |buf| ~freeBuffer.(buf) };
        ~wordsBuf     = nil;
        ~birdsBuf     = nil;
        ~alphabetBufs = Array.newClear(26);
    };

    ~wordsBuf     = nil;
    ~birdsBuf     = nil;
    ~alphabetBufs = Array.newClear(26);

    ~loadBuffers = {
        var path;
        ~freeAllBuffers.();

        path = "media/uwb/words/" ++ ~myName ++ ".wav";
        if(File.exists(path)) {
            ~wordsBuf = Buffer.read(s, path);
            ("Loaded: " ++ path).postln;
        } { ("WARNING: not found: " ++ path).postln };

        path = "media/uwb/birds/" ++ ~myName ++ ".wav";
        if(File.exists(path)) {
            ~birdsBuf = Buffer.read(s, path);
            ("Loaded: " ++ path).postln;
        } { ("WARNING: not found: " ++ path).postln };

        "ABCDEFGHIJKLMNOPQRSTUVWXYZ".do { |char, i|
            path = "media/uwb/alphabet/" ++ char.asString ++ ".wav";
            if(File.exists(path)) {
                ~alphabetBufs[i] = Buffer.read(s, path);
                ("Loaded: " ++ path).postln;
            } { ("WARNING: not found: " ++ path).postln };
        };
    };

    ~loadBuffers.();

    s.sync;

    // ---------- distance matrix ----------
    ~distMatrix = Array.fill(4, { Array.fill(4, { -1.0 }) });
    4.do { |i| ~distMatrix[i][i] = 0.0 };

    ~slotState = IdentityDictionary.new;
    ~numStems.do { |i|
        var slot   = i + 1;
        var xStart = [-0.75, -0.25, 0.25, 0.75][i];
        ~slotState[slot] = (
            xNorm:      xStart,
            yNorm:      0.0,
            present:    true,
            manualMute: false,
            distance:   0.0,
            active:     false
        );
    };

    // ---------- loop management ----------
    ~updateLoop = {
        if(~isMuted) {
            if(~loopSynth.notNil) {
                ~loopSynth.free;
                ~loopSynth = nil;
                ~lastLoopMode = nil;
            };
        } {
            if(~isNearEither.()) {
                if(~loopSynth.isNil or: { ~currentMode != ~lastLoopMode }) {
                    var buf, freq;
                    if(~loopSynth.notNil) {
                        ~loopSynth.free;
                        ~loopSynth = nil;
                    };
                    if(~currentMode == \alphabetSoup) {
                        "Alphabet Soup mode — random letter per ping.".postln;
                        ~lastLoopMode = ~currentMode;
                        ~isActive = true;
                        { padView.refresh }.defer;
                    } {
                        buf = ~bufForMode.();
                        if(buf.notNil) {
                            ~loopSynth = Synth(\sampleLoop, [\bufnum, buf.bufnum, \amp, 0.8]);
                        } {
                            freq = ~distToFreq.();
                            ("Starting sine loop at " ++ freq ++ "hz").postln;
                            ~loopSynth = Synth(\sineLoop, [\freq, freq, \amp, 0.3]);
                        };
                        ~lastLoopMode = ~currentMode;
                        ~isActive = true;
                        { padView.refresh }.defer;
                    };
                } {
                    if(~currentMode == \hertz and: { ~loopSynth.notNil }) {
                        ~loopSynth.set(\freq, ~distToFreq.());
                    };
                };
            } {
                if(~loopSynth.notNil) {
                    "Stopping continuous loop (both legs far)".postln;
                    ~loopSynth.free;
                    ~loopSynth = nil;
                    ~lastLoopMode = nil;
                    ~isActive = false;
                    { padView.refresh }.defer;
                };
                if(~currentMode == \alphabetSoup) {
                    ~lastLoopMode = nil;
                    ~isActive = false;
                    { padView.refresh }.defer;
                };
            };
        };
    };

    // ---------- layout from distance matrix ----------
    ~layoutFromMatrix = {
        var d01, d02, d03, d12, d13, d23;
        var x0, y0, x1, y1, x2, y2, x3, y3;
        var dx, dy, x3a, y3a, x3b, y3b, d23a, d23b;
        var coords, span, scale;
        var xNorm, yNorm, maxDist;
        var minX, maxX, minY, maxY, cxN, cyN;

        x0 = 0.0; y0 = 0.0;

        d01 = if(~distMatrix[0][1] > 0){ ~distMatrix[0][1] }{ 1.0 };
        d02 = if(~distMatrix[0][2] > 0){ ~distMatrix[0][2] }{ 1.0 };
        d03 = if(~distMatrix[0][3] > 0){ ~distMatrix[0][3] }{ 1.0 };
        d12 = if(~distMatrix[1][2] > 0){ ~distMatrix[1][2] }{ 1.0 };
        d13 = if(~distMatrix[1][3] > 0){ ~distMatrix[1][3] }{ 1.0 };
        d23 = if(~distMatrix[2][3] > 0){ ~distMatrix[2][3] }{ 1.0 };

        maxDist = [d01, d02, d03, d12, d13, d23].maxItem.max(0.01);

        d01 = d01.clip(0.01, maxDist);
        d02 = d02.clip(0.01, maxDist);
        d03 = d03.clip(0.01, maxDist);
        d12 = d12.clip(0.01, maxDist);
        d13 = d13.clip(0.01, maxDist);
        d23 = d23.clip(0.01, maxDist);

        x1 = d01; y1 = 0.0;

        dx = (d02.squared - d12.squared + d01.squared) / (2.0 * d01);
        dy = (d02.squared - dx.squared);
        dy = if(dy > 0){ dy.sqrt }{ 0.0 };
        x2 = dx; y2 = dy;

        dx  = (d03.squared - d13.squared + d01.squared) / (2.0 * d01);
        dy  = (d03.squared - dx.squared);
        dy  = if(dy > 0){ dy.sqrt }{ 0.0 };
        x3a = dx; y3a =  dy;
        x3b = dx; y3b = dy.neg;
        d23a = hypot(x3a - x2, y3a - y2);
        d23b = hypot(x3b - x2, y3b - y2);
        if((d23a - d23).abs < (d23b - d23).abs) {
            x3 = x3a; y3 = y3a;
        } {
            x3 = x3b; y3 = y3b;
        };

        coords = [[x0,y0],[x1,y1],[x2,y2],[x3,y3]];

        span  = max(
            coords.collect(_.first).maxItem - coords.collect(_.first).minItem,
            coords.collect(_.last).maxItem  - coords.collect(_.last).minItem
        );
        scale = if(span > 0){ 1.4 / span }{ 1.0 };

        xNorm = coords.collect { |p| (p[0] * scale) };
        yNorm = coords.collect { |p| (p[1] * scale).neg };

        minX = xNorm.minItem; maxX = xNorm.maxItem;
        minY = yNorm.minItem; maxY = yNorm.maxItem;
        cxN  = (minX + maxX) / 2;
        cyN  = (minY + maxY) / 2;
        xNorm = xNorm.collect { |v| (v - cxN).clip(-1, 1) };
        yNorm = yNorm.collect { |v| (v - cyN).clip(-1, 1) };

        [xNorm, yNorm];
    };

    ~updatePositionsFromMatrix = {
        var layout, xN, yN;
        var x1, y1, x2, y2, x3, y3, x4, y4;
        var st, d12, d23, d34, d41;

        layout = ~layoutFromMatrix.();
        xN = layout[0];
        yN = layout[1];

        4.do { |i|
            var slot = i + 1;
            st = ~slotState[slot];
            st[\xNorm] = xN[i];
            st[\yNorm] = yN[i];
            ~slotState[slot] = st;
        };

        x1 = ~slotState[1][\xNorm]; y1 = ~slotState[1][\yNorm];
        x2 = ~slotState[2][\xNorm]; y2 = ~slotState[2][\yNorm];
        x3 = ~slotState[3][\xNorm]; y3 = ~slotState[3][\yNorm];
        x4 = ~slotState[4][\xNorm]; y4 = ~slotState[4][\yNorm];

        d12 = (hypot(x1 - x2, y1 - y2) / 2.828).clip(0, 1);
        d23 = (hypot(x2 - x3, y2 - y3) / 2.828).clip(0, 1);
        d34 = (hypot(x3 - x4, y3 - y4) / 2.828).clip(0, 1);
        d41 = (hypot(x4 - x1, y4 - y1) / 2.828).clip(0, 1);

        st = ~slotState[2]; st[\distance] = d12; ~slotState[2] = st;
        st = ~slotState[3]; st[\distance] = d23; ~slotState[3] = st;
        st = ~slotState[4]; st[\distance] = d34; ~slotState[4] = st;
        st = ~slotState[1]; st[\distance] = d41; ~slotState[1] = st;

        ~updateLoop.();
        { padView.refresh }.defer;
    };

    ~updateDistanceFromSerial = { |fromNode, toNode, distMeters|
        ~distMatrix[fromNode - 1][toNode - 1] = distMeters;
        ~distMatrix[toNode - 1][fromNode - 1] = distMeters;
        ~maxRange = max(~maxRange, distMeters);
        ~updatePositionsFromMatrix.();
    };

    // ---------- serial reader ----------
    {
        var portName, baudRate, lineBuffer, byte, char;
        portName   = "/dev/ttyUSB0";
        baudRate   = 115200;
        lineBuffer = "";

        if(serialPort.notNil and: { serialPort.isOpen }) { serialPort.close };

        try {
            serialPort = SerialPort(portName, baudRate, crtscts: true);
        } { |err|
            "Serial port failed to open — running without UWB input.".postln;
            serialPort = nil;
        };

        if(serialPort.notNil and: { serialPort.isOpen }) {
            "Serial port opened, listening...".postln;
            serialRunning = true;
            {
                while { serialRunning } {
                    byte = serialPort.read;
                    if(byte.notNil) {
                        char = byte.asAscii;
                        if(char == Char.nl) {
                            if(lineBuffer.size > 0) {
                                var line, parts, from, to, dist;
                                line  = lineBuffer.replace(13.asAscii.asString, "").stripWhiteSpace;
                                parts = line.split($ );
                                if(parts.size >= 4) {
                                    from = parts[0].asInteger;
                                    to   = parts[2].replace(":", "").asInteger;
                                    dist = parts[3].asFloat;
                                    if((from > 0) and: { to > 0 } and: { dist > 0 }) {
                                        { ~updateDistanceFromSerial.(from, to, dist) }.defer;
                                    };
                                };
                                lineBuffer = "";
                            };
                        } {
                            lineBuffer = lineBuffer ++ char;
                        };
                    };
                    0.01.wait;
                };
                serialPort.close;
                "Serial reader stopped.".postln;
            }.fork(AppClock);
        } {
            "No serial port — GUI running in standalone mode.".postln;
        };
    }.value;

    // ---------- P2PSC ping chain ----------
    fork {
        p = P2PSC();
        p.sync;
        p.setName(~myName);
        p.sync;
        0.2.wait;
        p.sync;

        ("P2PSC Ready! Node: " ++ ~myName).postln;
        p.getPeers().postln;

        p.addPath({ |msg|
            var modeSym = msg[1].asSymbol;
            ("Received mode change: " ++ modeSym).postln;
            ~setMode.(modeSym);
        }, "/mode");

        p.addPath({ |msg|
            var delay, minVisible, buf, bufDur;
            delay = 0; minVisible = 0.5; buf = nil; bufDur = 0;
            "GOT PING".postln;
            if(~myName == "1") { ~lastPingTime = Main.elapsedTime };

            fork {
                if(~isMuted) {
                    "Muted — forwarding ping silently.".postln;
                    minVisible.wait;
                    p.sendMsg("/" ++ ~nextPeer ++ "/ping", p.name);
                } {
                    if(~isNearNeighbor.()) {
                        // ---- near neighbor branch ----
                        if(~currentMode == \alphabetSoup) {
                            if(~alphabetPlaying.not) {
                                var loaded = ~alphabetBufs.select({ |b| b.notNil });
                                if(loaded.size > 0) {
                                    var chosenBuf = loaded.choose;
                                    ~alphabetPlaying = true;
                                    Synth(\sampleOnce, [\bufnum, chosenBuf.bufnum, \amp, 0.8]);
                                    fork {
                                        chosenBuf.duration.wait;
                                        ~alphabetPlaying = false;
                                    };
                                };
                            } {
                                "Alphabet soup already playing — dropping, forwarding.".postln;
                            };
                        };
                        "Near neighbor — passing ping forward immediately.".postln;
                        p.sendMsg("/" ++ ~nextPeer ++ "/ping", p.name);

                    } {
                        // ---- normal branch ----
                        ~isActive = true;
                        { padView.refresh }.defer;

                        buf = ~bufForMode.();
                        if(buf.notNil) {
                            if(~currentMode == \alphabetSoup and: { ~alphabetPlaying }) {
                                "Alphabet soup busy — forwarding without playing.".postln;
                            } {
                                if(~currentMode == \alphabetSoup) { ~alphabetPlaying = true };
                                Synth(\sampleOnce, [\bufnum, buf.bufnum, \amp, 0.8]);
                                bufDur = buf.duration;
                                delay  = ~getDelayToNext.();
                                if(~currentMode == \alphabetSoup) {
                                    fork { bufDur.wait; ~alphabetPlaying = false };
                                };
                                [delay, minVisible, bufDur].maxItem.wait;
                            };
                        } {
                            var freq = ~distToFreq.();
                            Synth(\bikePing, [\freq, freq, \rel, 0.99]);
                            delay = ~getDelayToNext.();
                            delay.max(minVisible).wait;
                        };

                        ~isActive = false;
                        { padView.refresh }.defer;
                        ("Forwarding to bike " ++ ~nextPeer).postln;
                        p.sendMsg("/" ++ ~nextPeer ++ "/ping", p.name);
                    };
                };
            };
        }, "/ping");

        ("Ready as bike " ++ ~myName).postln;

        if(~myName == "1") {
            fork {
                loop {
                    15.wait;
                    if((Main.elapsedTime - ~lastPingTime) > 14.0) {
                        "CHAIN DIED — RESTARTING".postln;
                        ~lastPingTime = Main.elapsedTime;
                        if(~isMuted.not) {
                            var buf = ~bufForMode.();
                            if(buf.notNil) {
                                if(~currentMode == \alphabetSoup) {
                                    var loaded = ~alphabetBufs.select({ |b| b.notNil });
                                    if(loaded.size > 0 and: { ~alphabetPlaying.not }) {
                                        var chosenBuf = loaded.choose;
                                        ~alphabetPlaying = true;
                                        Synth(\sampleOnce, [\bufnum, chosenBuf.bufnum, \amp, 0.8]);
                                        fork { chosenBuf.duration.wait; ~alphabetPlaying = false };
                                    };
                                } {
                                    Synth(\sampleOnce, [\bufnum, buf.bufnum, \amp, 0.8]);
                                };
                            } {
                                Synth(\bikePing, [\freq, ~distToFreq.(), \rel, 0.99]);
                            };
                        };
                        p.sendMsg("/2/ping", p.name);
                    };
                };
            };

            fork {
                5.wait;
                "AUTO STARTING PING CHAIN".postln;
                ~isActive = true;
                { padView.refresh }.defer;
                if(~isMuted.not) {
                    var buf = ~bufForMode.();
                    if(buf.notNil) {
                        if(~currentMode == \alphabetSoup) {
                            var loaded = ~alphabetBufs.select({ |b| b.notNil });
                            if(loaded.size > 0) {
                                var chosenBuf = loaded.choose;
                                ~alphabetPlaying = true;
                                Synth(\sampleOnce, [\bufnum, chosenBuf.bufnum, \amp, 0.8]);
                                fork { chosenBuf.duration.wait; ~alphabetPlaying = false };
                            };
                        } {
                            Synth(\sampleOnce, [\bufnum, buf.bufnum, \amp, 0.8]);
                        };
                    } {
                        Synth(\bikePing, [\freq, ~distToFreq.(), \rel, 0.99]);
                    };
                };
                ~lastPingTime = Main.elapsedTime;
                p.sendMsg("/2/ping", p.name);
            };
        };
    };

    // ---------- GUI ----------
    ~slotToViewPoint = { |slot|
        var st = ~slotState[slot];
        Point(
            ((st[\xNorm] + 1) / 2) * padRect.width,
            (1 - ((st[\yNorm] + 1) / 2)) * padRect.height
        );
    };

    win = Window("Bike UWB Shape", screen).front;
    win.fullScreen;

    padRect = Rect(0, 0, screen.width - 170, screen.height);

    padView = UserView(win, padRect)
        .background_(Color.white)
        .clearOnRefresh_(true);

    // ---------- mode buttons ----------
    muteButtons = [
        Button(win, Rect(screen.width - 160, 30, 150, 60))
        .states_([
            ["ALPHABET SOUP", Color.white, Color.magenta(0.6)],
            ["ALPHABET SOUP", Color.white, Color.magenta(0.9)]
        ])
        .value_(0)
        .action_({ ~broadcastMode.(\alphabetSoup) }),

        Button(win, Rect(screen.width - 160, 100, 150, 60))
        .states_([
            ["BIRDS",  Color.white, Color.blue(0.5)],
            ["BIRDS",  Color.white, Color.blue(1.0)]
        ])
        .value_(0)
        .action_({ ~broadcastMode.(\birds) }),

        Button(win, Rect(screen.width - 160, 170, 150, 60))
        .states_([
            ["WORDS",  Color.white, Color.green(0.5)],
            ["WORDS",  Color.white, Color.green(0.8)]
        ])
        .value_(1)
        .action_({ ~broadcastMode.(\words) }),

        Button(win, Rect(screen.width - 160, 240, 150, 60))
        .states_([
            ["HERTZ",  Color.white, Color.cyan(0.5)],
            ["HERTZ",  Color.white, Color.cyan(0.9)]
        ])
        .value_(0)
        .action_({ ~broadcastMode.(\hertz) })
    ];

    // ---------- mute button (bottom right) ----------
    muteButton = Button(win, Rect(screen.width - 160, screen.height - 80, 150, 60))
    .states_([
        ["MUTE",   Color.white, Color.red(0.5)],
        ["UNMUTE", Color.white, Color.red(0.9)]
    ])
    .value_(0)
    .action_({ |btn|
        if(btn.value == 1) {
            ~broadcastMode.(\mute);
        } {
            ~broadcastMode.(~previousMode ?? { \words });
        };
    });

    // ---------- draw ----------
    padView.drawFunc = {
        var w, h, slot, st, pt, r, fc;
        w = padRect.width;
        h = padRect.height;

        Pen.fillColor = Color.white;
        Pen.addRect(Rect(0, 0, w, h));
        Pen.fill;

        Pen.width = 2;
        #[1,2,3,4,1].doAdjacentPairs { |a, b|
            var cpa, cpb, rawDist;
            cpa = ~slotToViewPoint.(a);
            cpb = ~slotToViewPoint.(b);

            rawDist = ~distMatrix[a-1][b-1];
            if(rawDist > 0) {
                var norm = rawDist.linlin(0, ~maxRange, 0, 1);
                Pen.strokeColor = Color.hsv(0.33 - (norm * 0.33), 0.8, 0.7);
            } {
                Pen.strokeColor = Color.gray(0.7);
            };

            Pen.moveTo(cpa);
            Pen.lineTo(cpb);
            Pen.stroke;

            if(rawDist > 0) {
                Pen.color = Color.black;
                Pen.stringAtPoint(
                    rawDist.round(0.01).asString ++ "m",
                    Point((cpa.x + cpb.x) * 0.5, (cpa.y + cpb.y) * 0.5 - 10)
                );
            };
        };

        ~numStems.do { |j|
            slot = j + 1;
            st   = ~slotState[slot];
            pt   = ~slotToViewPoint.(slot);
            r    = if(slot == ~mySlot and: { ~isActive }) { 24 } { 14 };
            fc   = if(slot == ~mySlot and: { ~isActive }) { Color.yellow } { Color.green(0.75) };
            Pen.fillColor   = fc;
            Pen.strokeColor = Color.black;
            Pen.width = 2;
            Pen.addOval(Rect.aboutPoint(pt, r, r));
            Pen.fillStroke;
            Pen.color = Color.black;
            Pen.font = Font("Arial", 14, true);
            Pen.stringAtPoint(slot.asString, Point(pt.x - 5, pt.y - 7));
        };
    };

    padView.mouseDownAction = nil;
    padView.mouseMoveAction = nil;
    padView.mouseUpAction   = nil;

    // ---------- cleanup on close ----------
    win.onClose = {
        serialRunning = false;
        if(~loopSynth.notNil) { ~loopSynth.free; ~loopSynth = nil };
        ~freeAllBuffers.();
        if(serialPort.notNil and: { serialPort.isOpen }) { serialPort.close };
        SerialPort.closeAll;
    };

    ~updatePositionsFromMatrix.();
    padView.refresh;
    "Ready - waiting for UWB serial data.".postln;

});
)