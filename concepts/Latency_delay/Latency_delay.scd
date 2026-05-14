s.waitForBoot({
    var samplePath, who;

    samplePath = thisProcess.nowExecutingPath.dirname +/+ "../../media/Latency_delay/" +/+ "bell.wav";
    ~buf = Buffer.read(s, samplePath);

    SynthDef(\samplePlayerMono, { |out=0, bufnum=0, amp=0.8|
        var sig, env;

        env = EnvGen.kr(
            Env.linen(0.005, BufDur.kr(bufnum), 0.01),
            doneAction: 2
        );

        sig = PlayBuf.ar(
            1,
            bufnum,
            BufRateScale.kr(bufnum)
        );

        Out.ar(out, (sig * env * amp) ! 2);
    }).add;

    SynthDef(\samplePlayerStereo, { |out=0, bufnum=0, amp=0.8|
        var sig, env;

        env = EnvGen.kr(
            Env.linen(0.005, BufDur.kr(bufnum), 0.01),
            doneAction: 2
        );

        sig = PlayBuf.ar(
            2,
            bufnum,
            BufRateScale.kr(bufnum)
        );

        Out.ar(out, sig * env * amp);
    }).add;

    s.sync;

    // assign host + peer from machine name
    ~host = "";
    ~peer = "";

    who = "whoami".unixCmdGetStdOut;

    if(who.contains("bikes1")) {
        ~host = "1";
        ~peer = "2";
    };
    if(who.contains("bikes2")) {
        ~host = "2";
        ~peer = "3";
    };
    if(who.contains("bikes3")) {
        ~host = "3";
        ~peer = "4";
    };
    if(who.contains("bikes4")) {
        ~host = "4";
        ~peer = "1";
    };

    if(~host == "" or: { ~peer == "" }) {
        ("Could not determine bike identity from whoami: " ++ who).error;
    } {
        ("Host is: " ++ ~host ++ " | Peer is: " ++ ~peer).postln;

        fork {
            p = P2PSC();
            p.sync;
            p.setName(~host);
            p.sync;

            ~lastRelayTime = nil;
            ~jamRate = 1;
            ~jamGap = 0.01;
            ~relayAmp = 0.8;

            ~isPlaying = false;
            ~playDelay = 0.25;

            // new timing controls
            ~waitBeforePlay = 0.05;
            ~waitBeforeForward = 0.05;

            // relay path
            p.addPath({ |msg|
                var freq = msg[1].asFloat;

                Routine({
                    // wait after receiving, before playing
                    ~waitBeforePlay.wait;

                    if(~sampleSynth.notNil) {
                        ~sampleSynth.free;
                    };

                    if(~buf.numChannels == 1) {
                        ~sampleSynth = Synth(\samplePlayerMono, [
                            \bufnum, ~buf.bufnum,
                            \amp, ~relayAmp
                        ]);
                    } {
                        ~sampleSynth = Synth(\samplePlayerStereo, [
                            \bufnum, ~buf.bufnum,
                            \amp, ~relayAmp
                        ]);
                    };

                    // wait after playback starts, before forwarding
                    ~waitBeforeForward.wait;

                    if(p.notNil) {
                        p.sendMsg("/" ++ ~peer ++ "/relay", freq);
                        ("Forwarded to bike " ++ ~peer).postln;
                    };
                }).play(AppClock);

            }, "/relay");

            // jam path
            p.addPath({ |msg|
                // do nothing
            }, "/jam");

            ~jammer = Routine({
                loop {
                    ~jamRate.do {
                        if(p.notNil) {
                            p.sendMsg("/" ++ ~peer ++ "/jam", 9, 8, 7, 6, 5, 4, 3, 2);
                        };
                    };
                    ~jamGap.wait;
                }
            }).play;

            ("Bike " ++ ~host ++ " ready, forwarding to bike " ++ ~peer).postln;
        };
    };
});

AppClock.sched(1.0, {
    var min = 1;
    var max = 250;
    var skew = 0.2;
    var screen, winW, winH, sliderW, sliderH, buttonW, buttonH, centerX, labelW, labelH;

    screen = Window.screenBounds;
    winW = screen.width;
    winH = screen.height;

    w = Window("Jam Rate Control", screen).front;
    w.fullScreen;

    sliderW = winW * 0.7;
    sliderH = 60;
    buttonW = winW * 0.3;
    buttonH = 120;
    centerX = winW / 2;
    labelW = 300;
    labelH = 60;

    Slider(w, Rect(
        centerX - (sliderW / 2),
        (winH / 2) - 80,
        sliderW,
        sliderH
    ))
    .value_(0.1)
    .action_({ |sl|
        var curved, val;

        curved = sl.value.pow(skew);
        val = curved.linexp(0.0001, 1, min, max);

        ~jamRate = val.asInteger.max(1);
        ("jamRate: " ++ ~jamRate).postln;
    });

    StaticText(w, Rect(
        centerX - (labelW / 2),
        (winH / 2) - 140,
        labelW,
        labelH
    ))
    .string_("Jam Rate Control")
    .align_(\center)
    .font_(Font("Helvetica", 20));

    Button(w, Rect(
        centerX - (buttonW / 2),
        (winH / 2) + 10,
        buttonW,
        buttonH
    ))
    .states_([
        ["Send Relay", Color.black, Color.green]
    ])
    .font_(Font("Helvetica", 20))
    .action_({
        if(p.notNil and: { ~peer != "" }) {
            p.sendMsg("/" ++ ~peer ++ "/relay", 440);
            ("Sent /" ++ ~peer ++ "/relay").postln;
        } {
            "P2PSC not ready or peer not set".postln;
        };
    });
});