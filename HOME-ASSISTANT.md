# Home Assistant

Every machine reports its backups to Home Assistant by itself, over MQTT. There is no
central collector and nothing to write in Home Assistant for each machine: a machine
appears as a device the first time it publishes, with its entities already set up.

The client side is configured by the installer (see *Home Assistant reporting* in
`COMMANDS.md`). This page covers what the machines send, the broker, and the few
lines on the Home Assistant side that cover the whole fleet.

## What each machine sends

After every real backup (success, failure or failed prune, never after a dry run),
and on `restic-ctl publish`, each machine sends three messages, all QoS 1 and
**retained**, so Home Assistant has them again after it restarts:

| Topic | Content |
|---|---|
| `homeassistant/device/restic/<id>/config` | MQTT discovery: the device and its entities |
| `restic/<box>` | the state: `last-run.json` plus `box`, `verify` and `publishedAt` |
| `restic/<box>/log` | the last run's whole log, `last-run.log`, as plain text |

After a check (the sample read-back or the daily data check) only the first two are
sent: a check does not change the run's log.

The log topic has no entity and Home Assistant never subscribes to it, so it stays
out of HA's database however long it is. It is there to be read from any machine
with an MQTT client (see *Why it failed* below). It is capped at the last 256 KiB of
the run; the whole run is in `last-run.log` on the machine.

Discovery goes first, so Home Assistant is already subscribed to the state topic
when the state arrives. The `restic` level in the discovery topic is the optional
node id Home Assistant allows there: it puts the whole fleet under one prefix, so the
broker can grant `homeassistant/device/restic/#` and nothing else of the discovery
space. Both are resent on every run; an unchanged discovery message
costs Home Assistant nothing, and resending it brings a device back if it was
deleted by mistake.

**Names.** `<box>` is `homeAssistant.box` in `config.json`, or the NAS user when that
is empty. `<id>` is the box reduced to `[A-Za-z0-9_-]`, with `restic-` in front when
it does not start with `restic` already, cut at 23 characters. `<id>` is also the MQTT
client id, which is what makes the ACL pattern below possible.

| box | id / client id | device name | entity ids |
|---|---|---|---|
| `restic-laptop` (the default) | `restic-laptop` | `restic-laptop` | `sensor.restic_laptop_*` |
| `laptop` | `restic-laptop` | `Restic laptop` | `sensor.restic_laptop_*` |

Either way every machine's entities start with `restic_`, and the fleet templates
below rely on it. Two boxes that reduce to the same id would be one device: give
each machine its own box.

## Entities

| Entity | Type | From | Notes |
|---|---|---|---|
| Outcome | sensor, enum | `outcome` | `ok`, `warnings`, `failed`, `prune-failed`, `never`. The whole state message is also its attributes: snapshot id, file counts, host, exit code, and the diagnosis below |
| Reason | sensor, enum | `reason` | why the last run did not end `ok`, from a fixed list (see *Diagnosis*); `none` for `ok` and `never`, `unknown` for a failure recorded by an older version |
| Diagnosis | sensor | `message` | the log line that says what went wrong, cut at 250 characters; reads the outcome itself (`ok`, `never`) when there is nothing to say |
| Last run | sensor, timestamp | `finishedAt` | the end of the last run, successful or not |
| Duration | sensor, seconds | `durationSec` | |
| Data added | sensor, bytes | `dataAddedBytes` | what the last snapshot added to the repository |
| Source size | sensor, bytes | `bytesProcessed` | the size of what was backed up |
| Problem | binary sensor, problem | `outcome` | on for anything but `ok`, including `warnings` and `never` |
| Verification | sensor, enum | `verify.status` | `ok`, `error` (a check could not run), `failed` (a check found damage, or the prune is frozen), `never` |
| Last data check | sensor, timestamp | `verify.data.at` | the last run of the rotating data check |
| Data fully verified | sensor, timestamp | `verify.data.cycleCompletedAt` | when the data check last finished a full pass over the repository |
| Verification problem | binary sensor, problem | `verify.status` | on for `failed` and `error`; off for `never`, so a machine just updated does not alarm before its first check |

The `verify` block carries the latest result of each level of verification (see
`restic-ctl help verify`): `sample`, the read-back after each backup; `data`, the
daily slice of `restic check --read-data-subset`; and `pruneFrozen` with its reason
when a check found damage. It is read from `verify-state.json` on every publish, so a
backup and a check never overwrite each other's results.

A machine that has never backed up sends only `outcome: never`: the other sensors
read *unknown* until its first run.

### Diagnosis

A run that does not end `ok` carries five more fields in its state, written by the
backup script from that run's own part of the log:

| Field | |
|---|---|
| `phase` | where it stopped: `backup`, `prune`, or `script` (the script itself failed) |
| `reason` | what kind of problem, one word from the list below |
| `message` | the line of the log that says it, at most 300 characters |
| `hint` | what to look at first |
| `logTail` | the last 25 lines of the run's log, at most 3000 characters |

| Reason | Meaning |
|---|---|
| `unreadable-files` | the snapshot was saved, but some files could not be read (outcome `warnings`) |
| `nas-unreachable` | name not resolved, timeout, no route, refused: Tailscale or the NAS is down |
| `ssh-auth` | the NAS refused this machine's key |
| `ssh-hostkey` | the NAS's host key is unknown or has changed |
| `sftp-unavailable` | SSH works, SFTP is off on the NAS |
| `nas-permission` | logged in, but cannot write in the repository |
| `nas-full` | no space left, or quota exceeded |
| `repo-missing` | no repository at `nas.repoPath` |
| `wrong-password` | the password file does not open the repository |
| `repo-locked` | another restic process holds the lock |
| `repo-damaged` | restic reported damaged data: do not prune |
| `connection-lost` | the connection dropped during the run |
| `interrupted` | stopped by a shutdown, a suspend, `systemctl stop`, Ctrl+C |
| `killed` | restic was killed outright (out of memory, a stop that timed out) |
| `script-error` | the backup script itself stopped before recording a result |
| `unknown` | none of the above: `message` is the last error in the log |

The specific cause wins over the consequence: an unreachable NAS shows up first as
ssh's own "Could not resolve hostname", then as restic's "server unexpectedly
closed connection"; the reason is `nas-unreachable`, not `connection-lost`. The
rules are the same on Linux and Windows, only the hints differ where the commands do.

The same diagnosis is shown by `restic-ctl status`, by `restic-ctl log --run` /
`--problem` on top of the log, and its reason is the last column of
`restic-ctl history`.

To see exactly what a machine sends without sending it:

```
restic-ctl publish --dry-run
sudo restic-ctl publish --dry-run
```

## The broker

**If the broker has an ACL, every machine must be able to write all three of its
topics.** Mosquitto accepts a publish to a denied topic and silently drops it: the
client sees a normal acknowledgement, `restic-ctl publish` reports success, and the
device just never shows up in Home Assistant. The add-on's log says
`Denied PUBLISH`.

The accounts go in the Mosquitto add-on's `logins` option, or are Home Assistant
users. Their name and password are what the installer's `-HaUser` / `--ha-user` and
password file expect. There are two ways to hand them out.

### One account for the whole fleet

Simplest: every machine uses the same account, and a new machine needs nothing on the
broker.

```
user restic
topic write restic/#
topic write homeassistant/device/restic/#
```

It works because every machine has its own box, hence its own topics and client id.
What it gives up is isolation: any machine, or anyone holding the password, which is
on every machine, can overwrite or remove the state and the device of any other. The
realistic harm is a false `ok` hiding a failed backup. Revoking one machine also
means changing the password on all of them.

### One account per machine

Each machine can write only its own topics:

```
user restic-laptop
topic write restic/laptop
topic write restic/laptop/log
topic write homeassistant/device/restic/restic-laptop/config
```

A machine updated from a version without the log topic needs the `restic/<box>/log`
line added: without it the broker drops the log silently, as above, and only the log
is missing - the state and the diagnosis still arrive.

The discovery half can be one line for the whole fleet, since the discovery id is the
client id:

```
pattern write homeassistant/device/restic/%c/config
```

That line is looser than the per-machine one: a machine that connects with another
machine's client id could overwrite that machine's device. The state topic has no
such pattern, because it is named after the box, not the client id.

### Home Assistant's own account

Whatever account Home Assistant connects with must keep read and write on `#`, or at
least on `homeassistant/#` and `restic/#`: removing a device from the UI is done by
publishing to its discovery topic.

### Watching the traffic

From any machine with the Mosquitto clients installed:

```
mosquitto_sub -h <broker> -u <user> -P <password> -v -t 'restic/#' -t 'homeassistant/device/restic/#'
```

## Home Assistant: the whole fleet, once

The devices need nothing. What a retained message cannot tell you is that a machine
has **stopped** backing up: its last `ok` stays `ok` forever. The same goes for the
data check. One template sensor covers every machine, including the ones added later,
and flags four things:

- no backup in 36 hours (*Last run*), or a backup that did not end `ok` (*Problem*);
- a verification that found damage or could not run (*Verification problem*);
- no data check in 72 hours (*Last data check*). A machine that has not had its first
  data check yet is not flagged for this: *Verification* reads `never` for it.

One automation turns the count into a notification.

Both go in a single package file, not in `configuration.yaml` itself. The default
`configuration.yaml` already has `automation: !include automations.yaml`, and often a
`template:` key too; a second key of the same name in that file is a duplicate, not a
merge. Keys in a package merge with the rest of the configuration. The Template
helper in the UI is not an alternative: it has no attributes, and the list of
machines lives in one.

### Installing it

1. **Enable packages**, once. In `configuration.yaml`:

   ```yaml
   homeassistant:
     packages: !include_dir_named packages
   ```

   If there is already a `homeassistant:` key, add the `packages:` line under it
   instead of a second `homeassistant:`. Then create a `packages` folder next to
   `configuration.yaml`, with the File editor or Studio Code Server add-on, or over
   the Samba share.

2. **Copy `home-assistant/restic.yaml`** from this repository to `packages/restic.yaml`
   in the Home Assistant configuration folder. It holds the *Restic attention* sensor -
   the count, with the list of machines and what is wrong with each in its `machines`
   attribute, the reason and log line included when the machine sends one - and the
   automation that notifies when the count goes up.

3. **Point the notification at a real target.** `notify.notify` exists only on some
   setups. The usual one is the companion app, `notify.mobile_app_<phone>`: find the
   exact name in Developer tools > Actions by typing `notify.`.

4. **Check, then restart.** Developer tools > YAML > *Check configuration*, then
   restart Home Assistant. The restart is needed once, for the `packages:` line. Later
   edits to `restic.yaml` only need *Template entities* and *Automations* reloaded,
   from the same page.

The `triggers:` / `actions:` / `trigger: state` spelling is Home Assistant 2024.10 and
later. An older installation wants `trigger:` / `platform: state` / `action:` /
`service:` instead.

### Checking that it sees the machines

**Do this once after installing, and again after adding a machine.** If the pattern
matches nothing, the sensor reads `0` forever, which looks exactly like "every backup
is fine". In Developer tools > Template:

```
{{ integration_entities('mqtt') | select('match', 'sensor\.restic_.+_last_run$') | list }}
```

It should list one `sensor.restic_<name>_last_run` per machine that has published.
An empty list means the entity ids are not what the template expects: see *Names*
above, and check the device under Settings > Devices & services > MQTT.

Then in Developer tools > States, `sensor.restic_attention` should hold a number, with
the offending machines in its `machines` attribute. To test the notification without
waiting for a failure: Settings > Automations > *Restic: a machine needs attention*
> ⋮ > *Run actions*. It sends the current list, possibly empty, which is enough to
prove the target works.

### Tuning

36 hours is one missed daily run plus margin, 72 hours for the data check, which
skips days on battery and while a backup runs. A machine that is often off for a day
or two will show up here; raise them (each appears in both loops, and in the message
text), or accept that as the point.

Both the sensor and the automation rely on the entity ids Home Assistant generated,
`sensor.restic_<name>_last_run` and so on. Renaming a device in the UI does not change
them, but renaming its entity ids does, and a renamed machine then drops out of both.

## Why it failed

Three places, from quickest to fullest.

**The notification and the device page.** The notification of the package above
carries the reason and the message: `Restic laptop: failed - nas-unreachable: ssh:
Could not resolve hostname ...`. On the device page, *Reason* and *Diagnosis* say
the same; the *Outcome* entity's attributes add `hint` and `logTail`.

**A dashboard card** that shows every machine needing attention, with the reason,
the log line, the hint and the last lines of its log: `home-assistant/restic-card.yaml`.
Dashboard > Edit > Add card > Manual, and paste it. It finds the machines by their
entity ids, like the package, so a new machine appears without editing it.

**The whole log of the last run**, from any machine with the Mosquitto clients:

```
mosquitto_sub -h <broker> -u <user> -P <password> -C 1 -t 'restic/laptop/log'
mosquitto_sub -h <broker> -u <user> -P <password> -v -t 'restic/+/log'
```

The first prints one machine's log and exits; the second every machine's, each
prefixed by its topic. MQTT Explorer shows the same topics in a tree. On the
machine itself: `restic-ctl log --run` for the last run, `restic-ctl log --problem`
for the last one that did not end `ok`, kept even after later good runs.

## Retiring a machine

`restic-ctl unpublish` sends empty retained messages to all three topics: Home
Assistant removes the device and its entities, and the broker forgets the state and
the log. The next
backup would announce the machine again, so stop the schedule first:

```
Disable-ScheduledTask -TaskName restic-backup ; restic-ctl unpublish
sudo systemctl disable --now restic-backup.timer && sudo restic-ctl unpublish
```

A machine that is already gone can be removed from Home Assistant itself: Settings >
Devices & services > MQTT > the device > Delete. Its retained state stays on the
broker until something clears it; that is harmless, since nothing subscribes to it
any more.
