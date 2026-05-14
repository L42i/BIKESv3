
s.waitForBoot({

	if(thisProcess.argv.notEmpty)
	{
		~soundscape = thisProcess.argv[0];
	}
	{
		~soundscape = "marine";
	};

	~absolutePrefix = thisProcess.nowExecutingPath.dirname;



	{
		{
			var path = ~absolutePrefix +/+ "../../media/soundscapes/samples" +/+ ~soundscape +/+ "base" +/+ "0.wav";

    ~song = Buffer.read(s, path);

    // MONO
    SynthDef(\song_player_mono, { |out=0, buf=0, rate=1, startpos=0, amp=1, lpfFreq=16000|
        var sig = PlayBuf.ar(
            1, buf,
            rate * BufRateScale.kr(buf),
            trig: 1,
            startPos: startpos * BufFrames.kr(buf),
            loop: 1,
            doneAction: 2
        );
        sig = LPF.ar(sig, lpfFreq);
        Out.ar(out, sig * amp ! 2); // duplicate to stereo output
    }).add;

    // STEREO
    SynthDef(\song_player_stereo, { |out=0, buf=0, rate=1, startpos=0, amp=1, lpfFreq=16000|
        var sig = PlayBuf.ar(
            2, buf,
            rate * BufRateScale.kr(buf),
            trig: 1,
            startPos: startpos * BufFrames.kr(buf),
            loop: 1,
            doneAction: 2
        );
        sig = LPF.ar(sig, lpfFreq);
        Out.ar(out, sig * amp);
    }).add;

    s.sync;

    // Choose the correct instrument based on the loaded buffer
    ~songInstr = { if(~song.numChannels == 1) { \song_player_mono } { \song_player_stereo } };

    // Ableton Link clock
    ~shared_CLOCK = LinkClock(1).latency_(Server.default.latency);
    ~shared_CLOCK.tempo = 4.13;
    ~shared_CLOCK.latency = 0.0;

    // Loop the full song in sync; re-trigger on bar boundaries
    Pbindef(\songLoop,
        \instrument, Pfunc { ~songInstr.() },
        \buf,        Pfunc { ~song.bufnum },
        \amp,        1.0,
        \rate,       1.0,
        \startpos,   0.0,
        \dur,        Pfunc { ~song.duration / ~shared_CLOCK.beatDur }
    ).play(~shared_CLOCK, quant: 4);
	}.();
	}.();


	//RECEIVER FUNCTION STARTS RIGHT AWAY
		{
		//8 = 1, 10 = 2, 11 = 3, 12 = 4
		~host = "";
		~peer = "";
		~absolute = thisProcess.nowExecutingPath.dirname;

		if(("whoami".unixCmdGetStdOut).contains("bikes1"))
		{
			~host = "1";
			~peer = "2";
		};
		if(("whoami".unixCmdGetStdOut).contains("bikes2"))
		{
			~host = "2";
			~peer = "3";
		};
		if(("whoami".unixCmdGetStdOut).contains("bikes3"))
		{
			~host = "3";
			~peer = "4";
		};
		if(("whoami".unixCmdGetStdOut).contains("bikes4"))
		{
			~host = "4";
			~peer = "1";
		};


		fork {
			p = P2PSC();
			p.sync;
			p.setName(~host); // set your name accordingly
			p.sync;

			p.addPath({ |msg|
				var sleeptime = 2;
				var freq = 200;
				var newPattern = (msg[1].asString).drop(1);
				var soundFile = ~absolute +/+ msg[2].asString;

				"received message!".postln;

				fork {
					2.wait;
					//newPattern.postln;
					~peer = newPattern[0];
					//soundFile.postln;

				Buffer.read(s, soundFile, action: { |b| ~sampleLayerBuffer = b; [0].do { |i| { Out.ar(i, PlayBuf.ar(1, b, rate: 1, loop: 0)) }.play } });


					//{SinOsc.ar(freq:freq)*0.5*EnvGen.kr(Env.perc(releaseTime:sleeptime-0.01), doneAction:2)}.play;
					if(newPattern != "")
					{

						msg.postln;
						"sent p2psc msg".postln;


						p.sendMsg("/"++~peer++"/ping" , newPattern, msg[2]);
					};
				};
			},"/ping");
		};
	}.();

	{3.0.wait;}.();




	~rSound = {
	// Pick word with weighted probability
	var word = if (1.0.rand < 0.8) { "soundmark" } { "signal" };

	// Pick number between 0 and 3
	var number = 4.rand;

	// Construct file path
	var path = ~absolutePrefix +/+ "../../media/soundscapes/samples" +/+ ~soundscape +/+ word +/+ number ++ ".wav";

	// Load buffer and play
	Routine({
		// Make sure the synthdef exists
		SynthDef(\simplePlay, {
			| buf, out = 0, rate = 1, loop = 0, gain = 1 |
			var sound;
			sound = PlayBuf.ar(
				numChannels: 1,
				bufnum: buf,
				rate: rate,
				loop: loop,
				doneAction: 2
			);
			Out.ar(out, sound * gain);
		}).add;

		s.sync; // Wait for synthdef to be added

		// Load the buffer
		Buffer.read(s, path, action: { |buf|
			"Loaded: %".format(path).postln;
			"Playing: % %".format(word, number).postln;

			// Play on outputs 0 and 2
			[0].do { |i|
				Synth(\simplePlay, [
					\buf, buf,
					\out, i
				]);
			};
		});

		0.1.wait;
	}).play;
};

	~rSound = {
	// Pick word with weighted probability
	var word = if (1.0.rand < 0.8) { "soundmark" } { "signal" };

	// Pick number between 0 and 3
	var number = 4.rand;

	// Construct file path
	var path = ~absolutePrefix +/+ "../../media/soundscapes/samples" +/+ ~soundscape +/+ word +/+ number ++ ".wav";

	// Load buffer and play
	Routine({
		// Make sure the synthdef exists
		SynthDef(\simplePlay, {
			| buf, out = 0, rate = 1, loop = 0, gain = 1 |
			var sound;
			sound = PlayBuf.ar(
				numChannels: 1,
				bufnum: buf,
				rate: rate,
				loop: loop,
				doneAction: 2
			);
			Out.ar(out, sound * gain);
		}).add;

		s.sync; // Wait for synthdef to be added

		// Load the buffer
		Buffer.read(s, path, action: { |buf|
			"Loaded: %".format(path).postln;
			"Playing: % %".format(word, number).postln;

			// Play on outputs 0 and 2
			[0].do { |i|
				Synth(\simplePlay, [
					\buf, buf,
					\out, i
				]);
			};
		});

		0.1.wait;
	}).play;
};

	~rSoundBitcrush = {
	// Pick word with weighted probability
	var word = if (1.0.rand < 0.8) { "soundmark" } { "signal" };

	// Pick number between 0 and 3
	var number = 4.rand;

	// Construct file path
	var path = ~absolutePrefix +/+ "../../media/soundscapes/samples" +/+ ~soundscape +/+ word +/+ number ++ ".wav";

	// Load buffer and play
	Routine({
		// Make sure the synthdef exists
		SynthDef(\simplePlay, {
			| buf, out = 0, volume = 1, pitchRatio = 1, infVerb = 0, lpfFreq = 20000,
              bitcrushOn = 1, bitcrushRate = 1000, bitcrushBits = 24  |
			var sound, finalSound, reverb, filtered, bitcrushed;

            // stereo file assumed; if mono, change first arg to 1 and do !2 at the end
            sound = PlayBuf.ar(2, buf, loop: 0);
            finalSound = PitchShift.ar(sound, 0.2, pitchRatio, 0.0, 0.0, 1.0, 0.0);
            filtered = LPF.ar(finalSound, lpfFreq);

            // Native bitcrush (always available; defaults: ON, 1000 Hz)
            bitcrushed = if(bitcrushOn > 0, {
                var downsample = Latch.ar(filtered, Impulse.ar(bitcrushRate)); // SR reduction
                var bitreduce  = downsample.round(0.5 ** bitcrushBits);       // bit reduction
                bitreduce
            }, {
                filtered
            });

            reverb = FreeVerb.ar(bitcrushed, infVerb, infVerb, 0.3);
            Out.ar(out, reverb * volume);
		}).add;

		s.sync; // Wait for synthdef to be added

		// Load the buffer
		Buffer.read(s, path, action: { |buf|
			"Loaded: %".format(path).postln;
			"Playing: % %".format(word, number).postln;

			// Play on outputs 0 and 2
			[0].do { |i|
				Synth(\simplePlay, [
					\buf, buf,
					\out, i
				]);
			};
		});

		0.1.wait;
	}).play;
};

	~rSoundPitch = {
	// Pick word with weighted probability
	var word = if (1.0.rand < 0.8) { "soundmark" } { "signal" };

	// Pick number between 0 and 3
	var number = 4.rand;

	// Construct file path
	var path = ~absolutePrefix +/+ "../../media/soundscapes/samples" +/+ ~soundscape +/+ word +/+ number ++ ".wav";

	// Load buffer and play
	Routine({
		// Make sure the synthdef exists
		SynthDef(\simplePlay, {
			| buf, out = 0, pitchShiftAmount = 1, gain = 1 |

        var sound, pitched;

        // play stereo buffer (looping)
        sound = PlayBuf.ar(2, buf, loop: 0);

        // pitch shift (ratio: 1 = no change, 2 = octave up, 0.5 = octave down)
        pitched = PitchShift.ar(sound, windowSize: 0.2, pitchRatio: pitchShiftAmount);

        // output (scaled to prevent overload)
        Out.ar(out, pitched * gain);
		}).add;

		s.sync; // Wait for synthdef to be added

		// Load the buffer
		Buffer.read(s, path, action: { |buf|
			"Loaded: %".format(path).postln;
			"Playing: % %".format(word, number).postln;

			// Play on outputs 0 and 2
			[0].do { |i|
				Synth(\simplePlay, [
					\buf, buf,
            \out, i,
            \pitchShiftAmount, 2,   // no shift by default
            \gain, 1
				]);
			};
		});

		0.1.wait;
	}).play;
};

	~rSoundReverb = {
	// Pick word with weighted probability
	var word = if (1.0.rand < 0.8) { "soundmark" } { "signal" };

	// Pick number between 0 and 3
	var number = 4.rand;

	// Construct file path
	var path = ~absolutePrefix +/+ "../../media/soundscapes/samples" +/+ ~soundscape +/+ word +/+ number ++ ".wav";

	// Load buffer and play
	Routine({
		// Make sure the synthdef exists
		SynthDef(\simplePlay, {
			| buf
        , out = 0
        , delayTime = 0.5
        , feedback = 0.5
        , reverbMix = 0.3
        , roomSize = 0.5
        , damping = 0.8
        , distortionAmount = 10
        , gain = 1 |

        var sound, delayedSound, combinedSound, reverb, output, distorted;

        // play stereo file in loop
        sound = PlayBuf.ar(2, buf, loop: 0);

        // simple delay with feedback
        delayedSound = DelayN.ar(sound, delayTime, delayTime) * feedback;
        combinedSound = sound + delayedSound;

        // reverb
        reverb = FreeVerb.ar(combinedSound, roomSize, damping, reverbMix);

        // gain stage
        output = reverb * gain;

        // soft clipping distortion
        distorted = Clip.ar(output * distortionAmount, -1, 1);

        // send out (attenuated)
        Out.ar(out, distorted * 0.3);
		}).add;

		s.sync; // Wait for synthdef to be added

		// Load the buffer
		Buffer.read(s, path, action: { |buf|
			"Loaded: %".format(path).postln;
			"Playing: % %".format(word, number).postln;

			// Play on outputs 0 and 2
			[0].do { |i|
				Synth(\simplePlay, [
					\buf, buf,
					\out, i
				]);
			};
		});

		0.1.wait;
	}).play;
};




	1.wait;
	s.sync;

	~pathTrigger = {
		var result;
		var soundFile2;
		//if(("hostname".unixCmdGetStdOut).contains("zs-MacBook-Pro-6.local"))




			{

				~pickWordAndNumber = {
					var word, number;

					// pick word with weighted probability
					word = if (1.0.rand < 0.8) { "soundmark" } { "signal" };

					// pick number between 0 and 3, equal distribution
					number = 4.rand;  // gives 0,1,2,3 equally



					// also return them if you want to use later
					[word, number]
				};

				result = ~pickWordAndNumber.value;

				result[0].postln;
				result[1].postln;

			}.();

		{
			soundFile2 = "media/samples" +/+ ~soundscape +/+ result[0] +/+ result[1] ++ ".wav";

			}.();




		~randomChoice = {
			var choice = [0,1].choose;

			if (choice==0, {
				//"Ordered".postln;
				{

						fork {
							var peer, peers, pattern;
							peers = p.getPeers();

							if (peers.size > 0,
								{
									pattern = "1234";

									//{SinOsc.ar(freq:1000)*0.5*EnvGen.kr(Env.perc(releaseTime:1-0.01), doneAction:2)}.play;
								    "sent p2psc msg".postln;

									p.sendMsg("/"++~peer++"/ping" , pattern, soundFile2);
								},
								{"Error: No other peers in the network".postln;}
							);
						};

				}.value; // Need to evaluate the function
			}, {
				"Rand".postln;
				{
					~generateRandomPattern = {
						var patternLength = rrand(3, 6);
							var possiblePeers = ["1", "2", "3", "4"];
						var newPattern = "";
						var lastChar = "";

						patternLength.do {
							var availablePeers = possiblePeers.reject { |peer| peer == lastChar };
							var nextChar = availablePeers.choose;

							newPattern = newPattern ++ nextChar;
							lastChar = nextChar;
						};

						//("Generated random pattern: " ++ newPattern).postln;
						//^newPattern;
						//{SinOsc.ar(freq:1000)*0.5*EnvGen.kr(Env.perc(releaseTime:1-0.01), doneAction:2)}.play;
							p.sendMsg("/"++~peer++"/ping" , newPattern, soundFile2);
					};

					// Test it
					~generateRandomPattern.();
				}.value; // Need to evaluate the function
			});
		};

		// Call the random choice function
		~randomChoice.();


	};






	{
		OSCdef(\gridListener, { |msg|
			var x = msg[1];
			var y = msg[2];

			("Grid clicked: " ++ x ++ ", " ++ y).postln;

			// Check if (x, y) is (0, 0) or (2, 0)

			//FILTERS SECTION
			if((x == 0 and: { y == 0 }) or: (x == 2 and: { y == 0 }) or: (x == 4 and: { y == 1 })) {
				"rSoundReverb".postln;
				~rSoundReverb.value();
			};


			//RSOUND
			if((x == 1 and: { y == 1 }) or: (x == 2 and: { y == 2 }) or: (x == 4 and: { y == 2 })) {
				"rSound".postln;
				~rSound.value();

			};

			if((x == 0 and: { y == 1 }) or: (x == 1 and: { y == 2 }) or: (x == 3 and: { y == 1 } ) or: (x == 0 and: { y == 2 }) or: (x == 2 and: { y == 1 } ) or: (x == 3 and: { y == 2 }) ) {
				"pathTrigger".postln;
				~pathTrigger.value();

			};
			if((x == 1 and: { y == 0 } ) or: (x == 3 and: { y == 0 }) ) {
				"rSoundPitch".postln;
				~rSoundPitch.value();

			};
			if((x == 4 and: { y == 0 } )) {
				"rSoundBitcrush".postln;
				~rSoundBitcrush.value();

			};
			// Example: trigger a sound

		}, "/grid");
	}.();

});






