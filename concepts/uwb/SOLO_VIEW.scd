(

s.waitForBoot({

    var win, padView, statusText, muteButtons;
    var padRect, activePoint, dragRadius;
    var serialPort, serialRunning;
    var screen;

    activePoint = nil;
    dragRadius = 18;
    screen = Window.screenBounds;

    s.meter;

    ~numStems = 4;
    ~maxRange = 5.0;
    ~currentMode = \birds;

    ~bikeFreqs = [220, 277.18, 329.63, 440];

    SynthDef(\bikeSinePing, {
        |out=0, freq=220, amp=0.35, dur=0.35|
        var env, sig;
        env = EnvGen.kr(Env.perc(0.01, dur), doneAction: 2);
        sig = SinOsc.ar(freq) * env * amp;
        Out.ar(out, Pan2.ar(sig, 0));
    }).add;

    s.sync;

    ~distMatrix = Array.fill(4, { Array.fill(4, { -1.0 }) });
    4.do { |i| ~distMatrix[i][i] = 0.0 };

    ~slotState = IdentityDictionary.new;
    ~numStems.do { |i|
        var slot = i + 1;
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

    ~nextSlot = Dictionary[1->2, 2->3, 3->4, 4->1];
    ~chainIsRunning = false;
    ~currentSlot    = 1;
    ~minDelay = 0.15;
    ~maxDelay = 1.5;

    // ---------- chain ----------
    ~playSlot = { |slot|
        var st, sst;
        st = ~slotState[slot];
        if(st[\present] and: { st[\manualMute].not }) {
            Synth(\bikeSinePing, [
                \freq, ~bikeFreqs[slot - 1],
                \amp,  0.35,
                \dur,  0.35
            ]);
        };
        ~numStems.do { |i|
            sst = ~slotState[i + 1];
            sst[\active] = ((i + 1) == slot);
            ~slotState[i + 1] = sst;
        };
        ~currentSlot = slot;
        ~updateStatus.();
        { padView.refresh }.defer;
    };

    ~startChain = {
        if(~chainIsRunning.not) {
            ~chainIsRunning = true;
            Routine({
                var slot, next, dist, waitTime;
                slot = ~currentSlot;
                while({ ~chainIsRunning }, {
                    ~playSlot.(slot);
                    next     = ~nextSlot[slot];
                    dist     = ~slotState[next][\distance];
                    waitTime = dist.linlin(0, 1, ~minDelay, ~maxDelay);
                    waitTime.wait;
                    slot = next;
                });
            }).play;
        };
    };

    ~endChain = {
        var st;
        ~chainIsRunning = false;
        ~numStems.do { |i|
            st = ~slotState[i + 1];
            st[\active] = false;
            ~slotState[i + 1] = st;
        };
        ~updateStatus.();
        { padView.refresh }.defer;
    };

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

        minX = xNorm.minItem;
        maxX = xNorm.maxItem;
        minY = yNorm.minItem;
        maxY = yNorm.maxItem;
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
            var slot;
            slot = i + 1;
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

        ~updateStatus.();
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
                                line = lineBuffer.replace(13.asAscii.asString, "").stripWhiteSpace;
                                line.postln;
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

    ~updateStatus = {};

    // ---------- GUI helpers ----------
    ~slotToViewPoint = { |slot|
        var st;
        st = ~slotState[slot];
        Point(
            ((st[\xNorm] + 1) / 2) * padRect.width,
            (1 - ((st[\yNorm] + 1) / 2)) * padRect.height
        );
    };

    ~nearestSlotAtPoint = { |pt|
        var bestSlot, bestDist, slot, p, d;
        bestSlot = nil;
        bestDist = 1e12;
        ~numStems.do { |j|
            slot = j + 1;
            p    = ~slotToViewPoint.(slot);
            d    = hypot(p.x - pt.x, p.y - pt.y);
            if(d < bestDist) { bestDist = d; bestSlot = slot };
        };
        if(bestDist <= dragRadius) { bestSlot } { nil };
    };

    // ---------- window fullscreen ----------
    win = Window("Bike UWB Shape", screen).front;
    win.fullScreen;

    padRect = Rect(0, 0, screen.width - 170, screen.height);

    padView = UserView(win, padRect)
        .background_(Color.white)
        .clearOnRefresh_(true);

    // ---------- BIRDS BEES AFFIRMATIONS ----------
    muteButtons = [
        Button(win, Rect(screen.width - 160, 30, 150, 60))
        .states_([
            ["BIRDS",  Color.white, Color.blue(0.5)],
            ["BIRDS",  Color.white, Color.blue(1.0)]
        ])
        .value_(1)
        .action_({
            ~currentMode = \birds;
            muteButtons[0].value = 1;
            muteButtons[1].value = 0;
            muteButtons[2].value = 0;
        }),

        Button(win, Rect(screen.width - 160, 100, 150, 60))
        .states_([
            ["BEES",   Color.black, Color.yellow(0.8)],
            ["BEES",   Color.black, Color.yellow(1.0)]
        ])
        .value_(0)
        .action_({
            ~currentMode = \bees;
            muteButtons[0].value = 0;
            muteButtons[1].value = 1;
            muteButtons[2].value = 0;
        }),

        Button(win, Rect(screen.width - 160, 170, 150, 60))
        .states_([
            ["AFFIRMATIONS", Color.white, Color.green(0.5)],
            ["AFFIRMATIONS", Color.white, Color.green(0.8)]
        ])
        .value_(0)
        .action_({
            ~currentMode = \affirmations;
            muteButtons[0].value = 0;
            muteButtons[1].value = 0;
            muteButtons[2].value = 1;
        })
    ];

    padView.drawFunc = {
        var w, h, slot, st, p, r, fc;
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
            p    = ~slotToViewPoint.(slot);
            r    = if(st[\active]) { 20 } { 14 };
            fc   = if(st[\active])     { Color.yellow     } {
                   if(st[\manualMute]) { Color.red(0.8)   } {
                   if(st[\present])   { Color.green(0.75) } {
                                        Color.blue(0.7)   }}};
            Pen.fillColor   = fc;
            Pen.strokeColor = Color.black;
            Pen.width = 2;
            Pen.addOval(Rect.aboutPoint(p, r, r));
            Pen.fillStroke;
            Pen.color = Color.black;
            Pen.font = Font("Arial", 14, true);
            Pen.stringAtPoint(slot.asString, Point(p.x - 5, p.y - 7));
        };
    };

    padView.mouseDownAction = nil;
    padView.mouseMoveAction = nil;
    padView.mouseUpAction   = nil;

    win.onClose = {
        ~chainIsRunning = false;
        serialRunning   = false;
        if(serialPort.notNil and: { serialPort.isOpen }) { serialPort.close };
        SerialPort.closeAll;
    };

    ~updatePositionsFromMatrix.();
    ~updateStatus.();
    padView.refresh;
    "Ready - waiting for UWB serial data.".postln;
    ~startChain.();

});
)