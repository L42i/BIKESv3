// CamTemplate.scd: starting point for a camera-reactive sound effect.
//
// Runs anywhere: your laptop (with fake_camera.py or a live bike camera) or a bike.
// Every sound is synthesized, so no media files are needed.
//
//   1. Open this file in the SuperCollider IDE, click inside the outer parentheses
//      and press Ctrl+Enter (Cmd+Enter on a Mac). Or from a terminal:  sclang CamTemplate.scd
//   2. In a terminal in this folder, send it camera events:
//          python3 fake_camera.py --interactive
//   3. Edit the sounds and hooks below, then run the file again.
//
// The OSC messages, Event fields and helpers are described in README.md.

(
s.waitForBoot({
	(thisProcess.nowExecutingPath.dirname +/+ "CamListener.scd").load;
	if(~camHost.isEmpty) { ~camHost = "1" };   // on a laptop, act as bike 1
	~camVerbose = true;                         // post every event; set false once it gets noisy
	("Listening for camera OSC on port " ++ NetAddr.langPort).postln;

	// ---------- Sounds ----------
	SynthDef(\camPing, { |freq = 600, amp = 0.2|
		var sig = (SinOsc.ar(freq) + SinOsc.ar(freq * 2.01, 0, 0.3)) * Env.perc(0.005, 1.2).kr(2);
		Out.ar(0, (sig * amp) ! 2);
	}).add;

	SynthDef(\camWhoosh, { |amp = 0.2, dur = 1.5|
		var env = Env([0, 1, 0], [dur * 0.4, dur * 0.6], \sin).kr(2);
		var sig = BPF.ar(PinkNoise.ar, env.linexp(0, 1, 300, 3000), 0.3) * env;
		Out.ar(0, (sig * amp * 3) ! 2);
	}).add;

	SynthDef(\camChirp, { |amp = 0.15|
		var sig = SinOsc.ar(2500 * XLine.kr(1, 1.6, 0.08) + SinOsc.ar(40, 0, 200)) * Env.perc(0.002, 0.15).kr(2);
		Out.ar(0, (sig * amp) ! 2);
	}).add;

	SynthDef(\camRise, { |amp = 0.12|
		var sig = RLPF.ar(Saw.ar(XLine.kr(200, 800, 1.5)), 1500, 0.3) * Env.linen(0.05, 1.2, 0.4).kr(2);
		Out.ar(0, (sig * amp) ! 2);
	}).add;

	// Continuous bed that follows how busy it is around the bikes
	SynthDef(\camBed, { |amp = 0, density = 0, bright = 300|
		var d = density.lag(2), b = bright.lag(2);
		var clicks = Ringz.ar(Dust.ar(1 + (d * 25)), [420, 630, 950], 0.4).sum * 0.03;
		var air = LPF.ar(BrownNoise.ar(0.05), b);
		Out.ar(0, ((clicks + air) * amp.lag(2)) ! 2);
	}).add;

	s.sync;
	~bed.free;
	~bed = Synth(\camBed);

	// ---------- Helpers ----------
	// true at most once per `seconds` for each key, so a busy street can't flood the speaker
	~camGateTimes = ();
	~gate = { |key, seconds|
		var now = Main.elapsedTime;
		if(now - (~camGateTimes[key] ? -1e9) >= seconds) { ~camGateTimes[key] = now; true } { false }
	};

	// things ahead of the bike sound higher than things behind it, whichever way the camera faces
	~dirToFreq = { |azimuth| azimuth.abs.linexp(0, 180, 1200, 300) };

	// ---------- Hooks: change these ----------
	// On a bike, peers' camera events arrive too; check ev.local if only this bike's camera should play.
	~onCamEnter = { |ev|
		var amp = ev.closeness.linlin(0.05, 0.6, 0.05, 0.3);
		if(~gate.(ev.category, 1)) {
			switch(ev.category,
				\person, { Synth(\camPing, [\freq, ~dirToFreq.(ev.azimuth), \amp, amp]) },
				\vehicle, { Synth(\camWhoosh, [\amp, amp, \dur, if([\bus, \truck, \train].includes(ev.label)) { 3 } { 1.5 }]) },
				\bike, { Synth(\camPing, [\freq, 1800, \amp, amp]) },
				\animal, { Synth(\camChirp, [\amp, amp]) }
			);
		};
	};

	~onCamApproach = { |ev|
		if(ev.category == \person and: { ~gate.(\approach, 3) }) { Synth(\camRise) };
	};

	~onCamExit = { |ev| };

	~onCamState = { |st|
		var ens = ~camEnsemble.();
		~bed.set(\amp, 0.5, \density, (ens.total / 5).clip(0, 1), \bright, ens.passRate.linexp(0, 40, 300, 4000));
	};

	// fade the bed out when no camera is reporting
	~camTemplateWatch.stop;
	~camTemplateWatch = SkipJack({ if(~camEnsemble.().cameras == 0) { ~bed.set(\amp, 0) } }, 0.5, name: "camTemplateBed");

	"CamTemplate ready. Send it events with:  python3 fake_camera.py --interactive".postln;
});
)
