# Home Assistant

Every machine reports its backups to Home Assistant by itself, over MQTT. There is no
central collector and nothing to write in Home Assistant for each machine: a machine
appears as a device the first time it publishes, with its entities already set up.

The client side is configured by the installer (see *Home Assistant reporting* in
`COMMANDS.md`). This page covers what the machines send, the broker, and the few
lines on the Home Assistant side that cover the whole fleet.

## What each machine sends

After every real backup (success, failure or failed prune, never after a dry run),
and on `restic-ctl publish`, each machine sends two messages, both QoS 1 and
**retained**, so Home Assistant has them again after it restarts:

| Topic | Content |
|---|---|
| `homeassistant/device/restic/<id>/config` | MQTT discovery: the device and its entities |
| `restic/<box>` | the state: `last-run.json` plus `box`, `verify` and `publishedAt` |

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
| Outcome | sensor, enum | `outcome` | `ok`, `warnings`, `failed`, `prune-failed`, `never`. The whole state message is also its attributes: snapshot id, file counts, host, exit code |
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

To see exactly what a machine sends without sending it:

```
restic-ctl publish --dry-run
sudo restic-ctl publish --dry-run
```

## The broker

**If the broker has an ACL, every machine must be able to write both of its
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
topic write homeassistant/device/restic/restic-laptop/config
```

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

2. **Create `packages/restic.yaml`** with this content:

   ```yaml
   template:
     - sensor:
         - name: "Restic attention"
           unique_id: restic_attention
           icon: mdi:backup-restore
           # How many problems need a look; the list is in the "machines" attribute. The
           # same loop as below, counted: a template sensor's state cannot read its own
           # attributes.
           state: >
             {% set ns = namespace(l=[]) %}
             {% for e in integration_entities('mqtt') | select('match', 'sensor\.restic_.+_last_run$') %}
               {% set t = states(e) | as_datetime(none) %}
               {% set p = e | replace('sensor.', 'binary_sensor.') | replace('_last_run', '_problem') %}
               {% set vp = e | replace('sensor.', 'binary_sensor.') | replace('_last_run', '_verification_problem') %}
               {% set dc = states(e | replace('_last_run', '_last_data_check')) | as_datetime(none) %}
               {% if t is none or now() - t > timedelta(hours=36) or is_state(p, 'on') %}
                 {% set ns.l = ns.l + [e] %}
               {% endif %}
               {% if is_state(vp, 'on') %}{% set ns.l = ns.l + [vp] %}{% endif %}
               {% if dc is not none and now() - dc > timedelta(hours=72) %}{% set ns.l = ns.l + [e] %}{% endif %}
             {% endfor %}
             {{ ns.l | count }}
           attributes:
             machines: >
               {% set ns = namespace(l=[]) %}
               {% for e in integration_entities('mqtt') | select('match', 'sensor\.restic_.+_last_run$') %}
                 {% set n = device_attr(e, 'name') %}
                 {% set t = states(e) | as_datetime(none) %}
                 {% set p = e | replace('sensor.', 'binary_sensor.') | replace('_last_run', '_problem') %}
                 {% set o = states(e | replace('_last_run', '_outcome')) %}
                 {% set vp = e | replace('sensor.', 'binary_sensor.') | replace('_last_run', '_verification_problem') %}
                 {% set v = states(e | replace('_last_run', '_verification')) %}
                 {% set dc = states(e | replace('_last_run', '_last_data_check')) | as_datetime(none) %}
                 {% if t is none or now() - t > timedelta(hours=36) %}
                   {% set ns.l = ns.l + [n ~ ': no run in 36 h (' ~ o ~ ')'] %}
                 {% elif is_state(p, 'on') %}
                   {% set ns.l = ns.l + [n ~ ': ' ~ o] %}
                 {% endif %}
                 {% if is_state(vp, 'on') %}
                   {% set ns.l = ns.l + [n ~ ': verification ' ~ v] %}
                 {% endif %}
                 {% if dc is not none and now() - dc > timedelta(hours=72) %}
                   {% set ns.l = ns.l + [n ~ ': no data check in 72 h'] %}
                 {% endif %}
               {% endfor %}
               {{ ns.l }}

   automation:
     - id: restic_attention_notify
       alias: "Restic: a machine needs attention"
       triggers:
         - trigger: state
           entity_id: sensor.restic_attention
       conditions:
         - condition: template
           value_template: >
             {{ trigger.to_state.state | int(0) > trigger.from_state.state | int(0) }}
       actions:
         - action: notify.notify
           data:
             title: "Backups"
             message: "{{ state_attr('sensor.restic_attention', 'machines') | join('\n') }}"
   ```

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

## Retiring a machine

`restic-ctl unpublish` sends empty retained messages to both topics: Home Assistant
removes the device and its entities, and the broker forgets the state. The next
backup would announce the machine again, so stop the schedule first:

```
Disable-ScheduledTask -TaskName restic-backup ; restic-ctl unpublish
sudo systemctl disable --now restic-backup.timer && sudo restic-ctl unpublish
```

A machine that is already gone can be removed from Home Assistant itself: Settings >
Devices & services > MQTT > the device > Delete. Its retained state stays on the
broker until something clears it; that is harmless, since nothing subscribes to it
any more.
