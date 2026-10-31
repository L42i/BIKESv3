// CamListener.scd: shared camera input for BIKES concepts.
//
// Receives /cam/* OSC from camera_osc.py on this bike, keeps the latest camera
// state of every bike, shares this bike's camera with its peers over P2PSC,
// and calls hooks that a concept can define. With no camera service running,
// nothing arrives and nothing happens.
//
// In a concept script (inside s.waitForBoot):
//     (~absolutePrefix +/+ "../camera/CamListener.scd").load;
// once P2PSC has its name set:
//     ~camAttachP2PSC.(p);
// and define any of these hooks. Each gets one Event:
//     ~onCamEnter    = { |ev| };  // ev.node .id .label .category .azimuth .closeness .local
//     ~onCamExit     = { |ev| };  // ev.node .id .label .category .duration .local
//     ~onCamApproach = { |ev| };  // ev.node .id .label .category .azimuth .closeness .growth .local
//     ~onCamState    = { |st| };  // st.node .people .vehicles .bikes .animals .total .passRate .local
// Labels and categories arrive as Symbols (\person, \vehicle, \bike, \animal).
//
// Helpers:
//     ~camAlive.(node)   true if that bike's camera reported in the last 2.5 s
//     ~camLocal.()       this bike's latest state Event, or nil
//     ~camEnsemble.()    summed state of all bikes whose camera is alive

(
~camPeers = ["1", "2", "3", "4"];
// bike number from the user name (bikes1 -> "1"); on a laptop set ~camHost = "1" before loading
~camHost = ~camHost ?? { "whoami".unixCmdGetStdOut.select(_.isDecDigit) };
~camNodes = ();
~camP2P = nil;
~camVerbose = false;
~camStateFields = [\people, \vehicles, \bikes, \animals, \total, \passRate];

~camMakeState = { |args, local|
	var st = (node: args[0].asString, local: local, time: Main.elapsedTime);
	~camStateFields.do { |key, i| st[key] = args[i + 1] ? 0 };
	st
};

~camMakeEvent = { |type, args, local|
	var ev = (type: type, node: args[0].asString, id: args[1], label: args[2].asSymbol,
		category: args[3].asSymbol, local: local);
	switch(type,
		\enter, { ev.azimuth = args[4]; ev.closeness = args[5] },
		\approach, { ev.azimuth = args[4]; ev.closeness = args[5]; ev.growth = args[6] },
		\exit, { ev.duration = args[4] }
	);
	ev
};

~camHandleState = { |st|
	~camNodes[st.node.asSymbol] = st;
	~onCamState.value(st);
};

~camHandleEvent = { |ev|
	if(~camVerbose) { ("camera " ++ ev.type ++ " from bike " ++ ev.node ++ ": " ++ ev.label).postln };
	switch(ev.type,
		\enter, { ~onCamEnter.value(ev) },
		\exit, { ~onCamExit.value(ev) },
		\approach, { ~onCamApproach.value(ev) }
	);
};

~camAlive = { |node|
	var st = ~camNodes[node.asString.asSymbol];
	st.notNil and: { Main.elapsedTime - st.time < 2.5 }
};

~camLocal = { if(~camAlive.(~camHost)) { ~camNodes[~camHost.asSymbol] } };

~camEnsemble = {
	var sum = (cameras: 0);
	~camStateFields.do { |key| sum[key] = 0 };
	~camNodes.keysValuesDo { |node, st|
		if(~camAlive.(node)) {
			sum.cameras = sum.cameras + 1;
			~camStateFields.do { |key| sum[key] = sum[key] + st[key] };
		};
	};
	sum
};

// Send to every other bike; P2PSC drops messages for bikes that are offline
~camShare = { |path ...args|
	if(~camP2P.notNil) {
		~camPeers.do { |peer|
			if(peer != ~camHost) { ~camP2P.sendMsg("/" ++ peer ++ path, *args) };
		};
	};
};

// Local messages from camera_osc.py
OSCdef(\camState, { |msg|
	~camHandleState.(~camMakeState.(msg.drop(1), true));
}, "/cam/state");

[\enter, \exit, \approach].do { |type|
	OSCdef(("cam_" ++ type).asSymbol, { |msg|
		~camHandleEvent.(~camMakeEvent.(type, msg.drop(1), true));
		~camShare.("/camEvent", type, *msg.drop(1));
	}, "/cam/" ++ type);
};

// Share this bike's state with peers twice a second while the camera is alive
~camShareTask.stop;
~camShareTask = SkipJack({
	var st = ~camLocal.();
	if(st.notNil) {
		~camShare.("/camState", st.node, *~camStateFields.collect { |key| st[key] });
	};
}, 0.5, name: "camShare");

~camAttachP2PSC = { |p2p|
	~camP2P = p2p;
	p2p.addPath({ |msg|
		~camHandleEvent.(~camMakeEvent.(msg[1].asSymbol, msg.drop(2), false));
	}, "/camEvent");
	p2p.addPath({ |msg|
		~camHandleState.(~camMakeState.(msg.drop(1), false));
	}, "/camState");
	("CamListener: sharing camera over P2PSC as bike " ++ ~camHost).postln;
};

("CamListener ready on bike " ++ ~camHost).postln;
)
