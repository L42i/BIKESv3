# Utility Scripts

## sync_folder.yml 
THIS IS THE MOST IMPORTANT ONE

This is the primary deployment script and lives in the **root of the BIKES project directory**, not in `utility/`. Run it whenever you want to push your local working copy of the entire project to all bikes. It rsyncs the current directory (`./`) to `~/Desktop/BIKES/` on every host with `delete: true`, meaning the remote is kept as an exact mirror of the local — files removed locally are removed remotely too.

```bash
ansible-playbook -k -i ./utility/config/bikes.ini  --extra-vars "key=/path/to/your/key.pub" utility/copy_ssh_key.yml
```
`times: false` is set so that file timestamps are not synced, which avoids unnecessary re-transfers on filesystems where clock skew between the controller and the Pis would otherwise mark everything as changed. Archive mode is on for everything else (permissions, ownership, recursion).

This is the script you run most often during development. The scripts in `utility/` are mostly one-time setup; `sync_folder.yml` is the daily driver.

---

A collection of Ansible playbooks for setting up, maintaining, and operating the BIKES network. All scripts live in the `utility/` folder. Most target `hosts: all` and work against any inventory file you pass with `-i`.

---

## Setup & Installation

### copy_ssh_key.yml
Installs a public SSH key for the `student` user via `authorized_key`. Pass the key path at runtime with `-e key=/path/to/key.pub`. Run this once to enable passwordless Ansible access to all hosts.

### install_supercollider.yml
Installs `supercollider` and `sc3-plugins` via apt on all hosts.

### install_jack.yml
Installs `jackd2`, `qjackctl`, and `libjack-jackd2-dev`. Also sets realtime audio permissions (`rtprio 95`, `memlock unlimited`) for the `audio` group and adds the current user to it.

### install_alsa.yml
Installs `alsa-utils` via apt. Required for `aplay` and other ALSA command-line tools used in the timesync concept.

### install_pythondeps.yml
Installs `python-osc` and `pygame` system-wide via pip with `--break-system-packages`. Required for all Python GUI scripts.

### install_screeninfo.yml
Installs the `screeninfo` Python package via pip. Used by GUI scripts that need to query screen dimensions.

### install_p2psc.yml
Installs P2PSC from the bundled offline source in `offline-libraries/p2psc`, using a local wheelhouse so no internet is required. Also verifies the install by importing `p2psc`, `pythonosc`, and `zeroconf`. 

### move_p2psc.yml
Copies the P2PSC SuperCollider Quark (`sclang/` library) from `offline-libraries/p2psc/libs/sclang` into each bike's SuperCollider Extensions directory (`~/.local/share/SuperCollider/Extensions`), making it available to `sclang` on boot. 

*PLEASE CHECK THIS STEP CAREFULLY, AN ERROR MAY OCCUR WHEN TRYING TO POINT TO THE RIGHT FOLDER*

### synchronizeTimes.yml
Sets up Chrony for NTP clock synchronization across the network. bikes1 becomes the stratum-8 time server; bikes2–4 sync from it. See 

---

## Operations

### start_jack.yml
Kills any existing `jackd` process and starts a fresh instance targeting the `hw:Gen` ALSA device at 48000 Hz, 128-frame buffer. Output is logged to `~/Desktop/jack_log.txt`. Adjust `jack_hw_device` in vars if the device name differs.

### kill_everything.yml
Kills all running audio and application processes across all hosts: `jackd`, `sclang`, `scsynth`, `python3`, `vlc`, `processing`, and anything holding `/dev/snd/*`. Useful for a clean reset before running a concept.

### ping.yml
Runs Ansible's built-in `ping` module against all hosts. Use this to verify connectivity and SSH access before running anything else.

### reboot_all.yml
Reboots all hosts simultaneously using `ansible.builtin.reboot`.

---

## Run Order (Fresh Setup)

For a new node from scratch, run the setup scripts in this order (roughly):

1. `copy_ssh_key.yml` — enable passwordless SSH
2. `sync_folder.yml` — deploy the full project
3. `install_supercollider.yml`
4. `install_jack.yml`
5. `install_alsa.yml`
6. `install_pythondeps.yml`
7. `install_screeninfo.yml`
8. `install_p2psc.yml`
9. `move_p2psc.yml`
10. `synchronizeTimes.yml`