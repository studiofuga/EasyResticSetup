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
| `homeassistant/device/<id>/config` | MQTT discovery: the device and its entities |
| `restic/<box>` | the state: `last-run.json` plus `box` and `publishedAt` |

Discovery goes first, so Home Assistant is already subscribed to the state topic
when the state arrives. Both are resent on every run; an unchanged discovery message
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

A machine that has never backed up sends only `outcome: never`: the other sensors
read *unknown* until its first run.

To see exactly what a machine sends without sending it:

```
restic-ctl publish --dry-run
sudo restic-ctl publish --dry-run
```

## The broker

With the Mosquitto add-on, give each machine its own MQTT account, either in the
add-on's `logins` option or as a Home Assistant user. The account name and password
are what the installer's `-HaUser` / `--ha-user` and password file expect.

**If the broker has an ACL, each machine must be able to write both of its
topics.** Mosquitto accepts a publish to a denied topic and silently drops it: the
client sees a normal acknowledgement, `restic-ctl publish` reports success, and the
device just never shows up in Home Assistant. The add-on's log says
`Denied PUBLISH`. Per machine:

```
user restic-laptop
topic write restic/laptop
topic write homeassistant/device/restic-laptop/config
```

Or, for the discovery half, one line for the whole fleet, since the discovery id is
the client id:

```
pattern write homeassistant/device/%c/config
```

The pattern is looser: an authenticated machine that picks another machine's client
id could overwrite that machine's device. The per-machine lines do not have that
gap. The account Home Assistant itself connects with must keep read and write on
`#`, or at least on `homeassistant/#` and `restic/#`: removing a device from the UI
is done by publishing to its discovery topic.

To watch the traffic from any machine with the Mosquitto clients installed:

```
mosquitto_sub -h <broker> -u <user> -P <password> -v -t 'restic/#' -t 'homeassistant/device/#'
```

## Home Assistant: the whole fleet, once

The devices need nothing. What a retained message cannot tell you is that a machine
has **stopped** backing up: its last `ok` stays `ok` forever. One template sensor
covers that for every machine, including the ones added later, by looking at each
*Last run* and each *Problem*:

```yaml
template:
  - sensor:
      - name: "Restic attention"
        unique_id: restic_attention
        icon: mdi:backup-restore
        # How many machines need a look; the list is in the "machines" attribute.
        state: >
          {% set ns = namespace(n=0) %}
          {% for e in integration_entities('mqtt') | select('match', 'sensor\.restic_.+_last_run$') %}
            {% set t = states(e) | as_datetime(none) %}
            {% set p = e | replace('sensor.', 'binary_sensor.') | replace('_last_run', '_problem') %}
            {% if t is none or now() - t > timedelta(hours=36) or is_state(p, 'on') %}
              {% set ns.n = ns.n + 1 %}
            {% endif %}
          {% endfor %}
          {{ ns.n }}
        attributes:
          machines: >
            {% set ns = namespace(l=[]) %}
            {% for e in integration_entities('mqtt') | select('match', 'sensor\.restic_.+_last_run$') %}
              {% set t = states(e) | as_datetime(none) %}
              {% set p = e | replace('sensor.', 'binary_sensor.') | replace('_last_run', '_problem') %}
              {% set o = states(e | replace('_last_run', '_outcome')) %}
              {% if t is none or now() - t > timedelta(hours=36) %}
                {% set ns.l = ns.l + [device_attr(e, 'name') ~ ': no run in 36 h (' ~ o ~ ')'] %}
              {% elif is_state(p, 'on') %}
                {% set ns.l = ns.l + [device_attr(e, 'name') ~ ': ' ~ o] %}
              {% endif %}
            {% endfor %}
            {{ ns.l }}
```

36 hours is one missed daily run plus margin. A machine that is often off for a day
or two will show up here; raise it, or accept that as the point.

And a notification when the count goes up:

```yaml
automation:
  - alias: "Restic: a machine needs attention"
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

Both rely on the entity ids Home Assistant generated, `sensor.restic_<name>_last_run`
and so on. Renaming a device in the UI does not change them, but renaming its entity
ids does, and a renamed machine then drops out of both.

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
