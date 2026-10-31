#!/bin/bash
# Start BIKES Flocking on this bike: jackd, FlockSpeech.scd, GPS, camera.
# Usage: ./run_flock.sh        start (stops any running copy first)
#        ./run_flock.sh stop   stop everything
# Env: CAMERA_ARGS, GPS_ARGS (extra options), JACK_DEVICE (default hw:2,0)
# Logs: ~/Desktop/flock_*.log

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LOGS="$HOME/Desktop"
JACK_DEVICE="${JACK_DEVICE:-hw:2,0}"

stop_all() {
    pkill -f '[c]amera_osc.py'
    pkill -f '[f]lock_camera.py'
    pkill -f '[f]lock_gps.py'
    sleep 1
    killall -9 sclang scsynth jackd 2>/dev/null
    sleep 1
}

stop_all
[ "$1" = "stop" ] && exit 0

cd "$DIR" || exit 1

nohup jackd -d alsa -d "$JACK_DEVICE" > "$LOGS/flock_jack.log" 2>&1 &
sleep 2

env HOME="$HOME" DISPLAY=:0 XAUTHORITY="$HOME/.Xauthority" \
    nohup sclang "$DIR/FlockSpeech.scd" > "$LOGS/flock_sclang.log" 2>&1 &

for _ in $(seq 1 20); do
    pgrep -x scsynth > /dev/null && break
    sleep 1
done
if ! pgrep -x scsynth > /dev/null; then
    echo "scsynth did not start, see $LOGS/flock_sclang.log and $LOGS/flock_jack.log"
    exit 1
fi
sleep 5

nohup python3 -u flock_gps.py $GPS_ARGS > "$LOGS/flock_gps.log" 2>&1 &
nohup python3 -u flock_camera.py $CAMERA_ARGS > "$LOGS/flock_camera.log" 2>&1 &

echo "Flocking running, logs in $LOGS/flock_*.log"
