# Future Directions

The concepts documented here are starting points. Each one isolates a single idea — a ping chain, a granular texture, a synchronized timestamp — and explores it in relative isolation. The next phase of the project is about combining them: using the physical reality of the formation as a live, continuous input that shapes not just sound but the structure of the network itself.

---

## Distance Matrix as a Compositional Engine

The UWB system already produces a full 4×4 distance matrix in real time — every pairwise distance between every node, updating continuously. In the current UWB Shape concept this drives a visual layout and a basic proximity trigger. But the matrix is far richer than that.

The physical formation of the bikes at any moment encodes a set of relationships — who is close, who is far, how the group is shaped — and each of those relationships can independently control a musical parameter. The six unique pairwise distances constitute a 6-channel continuous control surface written by the riders moving through space. 


## From Distance to Rate

Distance is a snapshot. Rate — distance over time — is worth exploring. It builds on feedback that we've gotten -- "What happens when a bike speeds up?".

You should look into how you can calculate this. 

---

## UWB / GPS Handoff

UWB and GPS are complementary. UWB operates at centimetre-level precision but only within a limited range and with no concept of absolute world position. GPS provides absolute coordinates at city scale but with coarse resolution and latency too high to track tight inter-bike dynamics. Used together they cover each other's blind spots: UWB handles relative positioning at close range; GPS derives approximate inter-node distances when bikes spread beyond UWB range. You should explore how you can mix both approaches to get one seamless localization system.

---

## UWB Sensors and Algorithmic Complexity

I encourage you to look into how you can make the UWB sensor algorithm much better.