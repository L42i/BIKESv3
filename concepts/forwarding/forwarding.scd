s.waitForBoot {
    var who;
    ~myName = "";
    ~nextPeer = "";

    who = "whoami".unixCmdGetStdOut;

    if(who.contains("bikes1")) { ~myName = "1"; ~nextPeer = "2"; };
    if(who.contains("bikes2")) { ~myName = "2"; ~nextPeer = "3"; };
    if(who.contains("bikes3")) { ~myName = "3"; ~nextPeer = "4"; };
    if(who.contains("bikes4")) { ~myName = "4"; ~nextPeer = "1"; };

    ("My bike name: " ++ ~myName).postln;
    ("Next peer: " ++ ~nextPeer).postln;

    if(~myName == "") {
        ("Could not determine bike identity from whoami: " ++ who).error;
    } {
        SynthDef(\bikePing, {
            |out = 0, freq = 440, amp = 0.5, rel = 0.99|
            var env, sig;
            env = EnvGen.kr(
                Env.perc(releaseTime: rel),
                doneAction: 2
            );
            sig = SinOsc.ar(freq) * env * amp;
            Out.ar(out, [sig, sig]);
        }).add;

        s.sync;

        fork {
            p = P2PSC();
            p.sync;
            p.setName(~myName);
            p.sync;
            0.2.wait;
            p.sync;

            ("P2PSC Ready! Node: " ++ ~myName).postln;
            p.getPeers().postln;

            // listen on generic /ping — P2PSC routes by node name
            p.addPath({ |msg|
                "GOT PING".postln;
                msg.postln;
                fork {
                    0.25.wait;
                    Synth(\bikePing, [\freq, 200, \rel, 0.99]);
                    0.25.wait;
                    ("Forwarding to bike " ++ ~nextPeer).postln;
                    p.sendMsg("/" ++ ~nextPeer ++ "/ping", p.name);
                };
            }, "/ping");

            ("Ready as bike " ++ ~myName).postln;

            // bike 1 starts the chain directly — no self send
            if(~myName == "1") {
                fork {
                    5.wait;
                    "AUTO STARTING PING CHAIN".postln;
                    Synth(\bikePing, [\freq, 200, \rel, 0.99]);
                    0.25.wait;
                    p.sendMsg("/2/ping", p.name);
                };
            };
        };
    };
};