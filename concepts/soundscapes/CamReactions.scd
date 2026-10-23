// CamReactions.scd — how Soundscapes reacts to the camera. Loaded by GUIListener.scd
// after ../camera/CamListener.scd. Needs ~soundscape and ~absolutePrefix.
//
// Keynote (base track): its level and brightness follow how busy the surroundings
//   are, summed over every bike whose camera is running. With no camera running
//   the base track plays exactly as before (amp 1, LPF 16 kHz).
// Signals: things this bike's camera sees trigger samples from the current theme.
//   person  -> soundmark sample, louder when closer
//   person walking toward the bike -> ~pathTrigger ripple around the ring
//   bicycle / animal -> octave-up sample
//   car / motorcycle -> sample with delay and reverb
//   bus / truck / train -> bitcrushed sample
// Samples are loaded once and reused, so camera triggers never leak buffers.

(
~camReactive = true;      // set false to ignore the camera
~camGain = 0.8;           // level of camera-triggered samples
~camMinGap = 1.5;         // seconds between any two camera-triggered samples
~camCategoryGap = 4;      // seconds between samples for the same category
~camRippleGap = 12;       // seconds between camera-triggered ripples around the ring

// ---------- Keynote: base track follows activity ----------
~keynoteAmpBus = Bus.control(s, 1).set(1);
~keynoteLpfBus = Bus.control(s, 1).set(16000);
~keynoteAmp = 1;
~keynoteLpf = 16000;

// 0 = empty street, approaching 1 = crowded / heavy traffic
~camActivity = { |st|
	1 - exp((st.people + (1.5 * st.vehicles) + st.bikes + st.animals + (st.passRate / 6)).neg / 4)
};

~keynoteTask.stop;
~keynoteTask = SkipJack({
	var ens = ~camEnsemble.();
	var targetAmp = 1, targetLpf = 16000;
	if(~camReactive and: { ens.cameras > 0 }) {
		var a = ~camActivity.(ens);
		targetAmp = 0.75 + (0.25 * a);
		targetLpf = 2500 * ((16000 / 2500) ** a);
	};
	// ~2 s glide so the keynote breathes rather than jumps
	~keynoteAmp = ~keynoteAmp + ((targetAmp - ~keynoteAmp) * 0.05);
	~keynoteLpf = ~keynoteLpf + ((targetLpf - ~keynoteLpf) * 0.05);
	~keynoteAmpBus.set(~keynoteAmp);
	~keynoteLpfBus.set(~keynoteLpf);
}, 0.1, name: "camKeynote");

// ---------- Signals: one SynthDef per channel count, with optional effects ----------
[1, 2].do { |numChannels|
	SynthDef(("camPlay" ++ numChannels).asSymbol, {
		|out = 0, buf, gain = 1, pitch = 1, crush = 0, delay = 0, feedback = 0.5, verb = 0, room = 0.5|
		var sig = PlayBuf.ar(numChannels, buf, BufRateScale.kr(buf));
		sig = Mix(sig) * numChannels.reciprocal.sqrt;
		sig = Select.ar(pitch > 1.001, [sig, PitchShift.ar(sig, 0.2, pitch)]);
		sig = Select.ar(crush > 0, [sig, Latch.ar(sig, Impulse.ar(crush.max(1))).round(0.5 ** 8)]);
		sig = sig + (DelayN.ar(sig, 1, delay.clip(0.01, 1)) * feedback * (delay > 0));
		sig = FreeVerb.ar(sig, verb, room, 0.5);
		// let effect tails ring out after the sample ends
		Line.kr(0, 0, BufDur.kr(buf) + 3, doneAction: 2);
		Out.ar(out, (sig * gain).tanh ! 2);
	}).add;
};

~camFx = (
	plain: [],
	pitch: [\pitch, 2],
	reverb: [\delay, 0.5, \feedback, 0.5, \verb, 0.3, \room, 0.5],
	crush: [\crush, 1000, \verb, 0.2]
);

// Same folders as the touch grid: soundmark/0-3.wav and signal/0-3.wav
~camBufs.do { |bufs| bufs.do(_.free) };
~camBufs = ();
[\soundmark, \signal].do { |kind|
	~camBufs[kind] = (0..3).collect { |i|
		Buffer.read(s, ~absolutePrefix +/+ "../../media/soundscapes/samples" +/+ ~soundscape +/+ kind +/+ i ++ ".wav")
	};
};

~camPlay = { |fx, signalChance = 0.2, closeness = 0.3|
	var kind = if(signalChance.coin) { \signal } { \soundmark };
	var buf = ~camBufs[kind].choose;
	if(buf.numChannels.notNil) {
		Synth(("camPlay" ++ buf.numChannels.clip(1, 2)).asSymbol,
			[\buf, buf, \gain, ~camGain * closeness.linlin(0.05, 0.6, 0.5, 1.0)] ++ ~camFx[fx]);
	};
};

// ---------- Rate limiting ----------
~camLastAny = 0;
~camLast = ();
~camReady = { |key, gap|
	var now = Main.elapsedTime;
	if((now - ~camLastAny >= ~camMinGap) and: { now - (~camLast[key] ? 0) >= gap }) {
		~camLastAny = now;
		~camLast[key] = now;
		true
	} { false }
};

// ---------- Hooks ----------
// Only this bike's own camera triggers sounds here; peers' cameras play on their
// own bikes and reach this one through the shared keynote activity.
~onCamEnter = { |ev|
	if(~camReactive and: { ev.local } and: { ~camReady.(ev.category, ~camCategoryGap) }) {
		switch(ev.category,
			\person, { ~camPlay.(\plain, 0.2, ev.closeness) },
			\bike, { ~camPlay.(\pitch, 0.2, ev.closeness) },
			\animal, { ~camPlay.(\pitch, 0.2, ev.closeness) },
			\vehicle, {
				if([\bus, \truck, \train].includes(ev.label)) {
					~camPlay.(\crush, 0.8, ev.closeness)
				} {
					~camPlay.(\reverb, 0.8, ev.closeness)
				}
			}
		);
	};
};

~onCamApproach = { |ev|
	if(~camReactive and: { ev.local } and: { ev.category == \person } and: { ~camReady.(\ripple, ~camRippleGap) }) {
		"camera: someone is approaching, sending a ripple".postln;
		~pathTrigger.value;
	};
};

"CamReactions ready".postln;
)
