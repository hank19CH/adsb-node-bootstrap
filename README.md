# adsb-node-bootstrap

One-command ADS-B feeder node setup for Ubuntu 24.04 / 26.04 on Raspberry Pi and x86_64.

Installs [readsb](https://github.com/wiedehopf/readsb) + [tar1090](https://github.com/wiedehopf/tar1090) and configures feeds to up to seven aggregators — fully unattended, no whiptail dialogs, no per-service configuration.

## What it does

1. Installs RTL-SDR drivers and build dependencies
2. Installs readsb (ADS-B decoder) and tar1090 (local web map)
3. Works around the **GCC 15 `-Werror` build failure** in two feed clients (see below)
4. Feeds your selected aggregators (all optional, enable what you want):
   - [adsb.lol](https://adsb.lol) — ODbL-licensed, community-run
   - [FlightAware / PiAware](https://flightaware.com/adsb/)
   - [adsb.fi](https://adsb.fi)
   - [ADS-B Exchange](https://adsbexchange.com)
   - [airplanes.live](https://airplanes.live)
   - [OpenSky Network](https://opensky-network.org)
   - [FlightRadar24](https://www.flightradar24.com) (opt-in, interactive signup only)

## Quick start

```bash
curl -sL https://raw.githubusercontent.com/hank19CH/adsb-node-bootstrap/main/bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

Or with a config file to skip prompts:

```bash
cp config.env.example config.env
# Edit config.env — set your lat/lon, altitude, and which feeds to enable
sudo ./bootstrap.sh --config config.env
```

Re-running is safe: feeds that are already running get their config refreshed and restarted; pass `--force` to rebuild everything.

## Cloud-init (headless deploy)

For Raspberry Pi Imager, cloud VMs, or any cloud-init-capable system:

1. Copy `cloud-init/user-data.yaml` to your boot media as `user-data`
2. Edit the variables at the top (coordinates, feeds, user credentials)
3. Boot — the node configures itself on first boot

See [`cloud-init/user-data.yaml`](cloud-init/user-data.yaml) for the full template.

## How unattended feed setup works

adsb.lol, adsb.fi, ADS-B Exchange and airplanes.live all ship the same installer layout (they are forks of the ADSBx feed client):

| Script | What it does |
|---|---|
| `feed.sh` | clones the repo, runs `setup.sh` |
| `setup.sh` | runs `configure.sh` (whiptail prompts → `/etc/default/<feed>`), then `update.sh` |
| `update.sh` | clones + compiles their readsb fork, builds the mlat-client venv, installs the `<feed>-feed` and `<feed>-mlat` services |

`update.sh` only calls `setup.sh` if `/etc/default/<feed>` is missing a required key. So this bootstrap writes that file itself — with exactly the values `configure.sh` would have written — clones the repo, and runs `update.sh` directly. There is nothing left to prompt for, in either attended or unattended mode. No `curl | bash`, no `/dev/tty` tricks, no expect scripts.

| Feed | Config file | Services |
|---|---|---|
| adsb.lol | `/etc/default/adsblol` | `adsblol-feed`, `adsblol-mlat` |
| adsb.fi | `/etc/default/adsbfi` | `adsbfi-feed`, `adsbfi-mlat` |
| ADS-B Exchange | `/etc/default/adsbexchange` | `adsbexchange-feed`, `adsbexchange-mlat` |
| airplanes.live | `/etc/default/airplanes` | `airplanes-feed`, `airplanes-mlat` |
| FlightAware | `piaware-config` | `piaware` |
| OpenSky | debconf → `/var/lib/openskyd/conf.d/10-debconf.conf` | `opensky-feeder` |

**FlightAware** is a pre-built `.deb` configured with `piaware-config`.

**OpenSky** is a pre-built `.deb` configured through debconf — but its templates are named `openskyd/*`, not `opensky-feeder/*`. Pre-seed the wrong name and the package's Perl `config` script loops forever re-asking for a valid latitude under a noninteractive frontend. This bootstrap seeds `openskyd/latitude`, `openskyd/longitude`, `openskyd/altitude`, `openskyd/dump1090branch`, `openskyd/host` and `openskyd/port`, and the postinst writes the config for you.

**FlightRadar24** has no pre-seed path (`fr24feed --signup` is interactive), so it is opt-in and skipped with a notice in `--non-interactive` mode.

## GCC 15 fix

Ubuntu 26.04 ships GCC 15, which enables `-Wunterminated-string-initialization` by default. Two feed clients compile their own readsb fork with `-Werror` in the Makefile, and both forks are frozen at mid-2024, before upstream fixed three char arrays sized without room for the NUL terminator:

```
interactive.c:126:23: error: initializer-string for array of 'char' truncates NUL terminator
but destination lacks 'nonstring' attribute (5 chars into 4 available)
[-Werror=unterminated-string-initialization]
  126 |     char spinner[4] = "|/-\\";
```

Fixing the spinner alone just moves the error to `uat2esnt/uat_decode.c` (`base40_alphabet[40]`) and then `ais_charset.c` (`ais_charset[64]`).

| Feed | readsb source | Status on GCC 15 |
|---|---|---|
| adsb.fi | `adsbfi/readsb@dev` (last sync 2024-06) | ❌ fails — fix offered in [adsbfi/readsb#2](https://github.com/adsbfi/readsb/pull/2) |
| ADS-B Exchange | `adsbexchange/readsb@master` (last sync 2024-06) | ❌ fails — fix pending in [ADSBexchange/readsb#13](https://github.com/ADSBexchange/readsb/pull/13) |
| adsb.lol | `wiedehopf/readsb@stale` | ✅ fixed upstream ([21d399de](https://github.com/wiedehopf/readsb/commit/21d399de), 2025-07) |
| airplanes.live | `airplanes-live/readsb@dev` (synced 2026-05) | ✅ fixed |
| FlightAware, OpenSky | pre-built binaries | n/a |

Until those PRs merge, this toolkit puts `cc`/`gcc`/`g++` wrappers on `PATH` during feed installation that strip a standalone `-Werror` (preserving `-Werror=<specific>` flags like `-Werror=format-security`), then removes them. No source patches, no forks. Only active when the host GCC is ≥ 15.

## Reimaging without losing your station

Every aggregator identifies your station by a UUID or key kept in a file on the node. Lose the SD card and you start over as a new station — unless you restore those first. The bootstrap saves them all to **`/etc/adsb-node-uuids.env`** at the end of every run:

```bash
# Feeder identities for my-node — captured 2026-09-18T12:00:00Z
ADSBLOL_UUID="…"             # /usr/local/share/adsblol/adsblol-uuid
ADSBFI_UUID="…"              # /usr/local/share/adsbfi/adsbfi-uuid
ADSBX_UUID="…"               # /usr/local/share/adsbexchange/adsbx-uuid
AIRPLANES_UUID="…"           # /usr/local/share/airplanes/airplanes-uuid
FLIGHTAWARE_FEEDER_ID="…"    # piaware-config feeder-id (assigned by FA on first connect)
OPENSKY_SERIAL="…"           # /var/lib/openskyd/conf.d/*.conf (assigned on first connect)
FR24_KEY="…"                 # /etc/fr24feed.ini fr24key=
```

Copy that file somewhere safe (a private git repo, a password manager). FlightAware and OpenSky assign their ids on first connect, so re-copy it after the node has been feeding for a while.

To bring a reimaged node back as the same station, either:

- drop the file on the SD card's `system-boot` partition as **`adsb-uuids.env`** next to `user-data` — the bootstrap auto-detects it, or
- pass it explicitly: `sudo ./bootstrap.sh --config config.env --restore-uuids uuids.env`

Empty values are skipped (that feeder gets a fresh identity); malformed UUIDs are rejected with a warning. The four readsb feeders reuse an existing valid `<feed>-uuid` file rather than generating one, FlightAware is set with `piaware-config feeder-id`, OpenSky via the `openskyd/serial` debconf answer, and FR24 by writing its ini.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `LATITUDE` | *(required)* | Receiver latitude (decimal) |
| `LONGITUDE` | *(required)* | Receiver longitude (decimal) |
| `ALTITUDE_FT` / `ALTITUDE_M` | *(one required)* | Antenna altitude MSL; the other is derived |
| `MLAT_SITE_NAME` | hostname | Name shown on the aggregators' MLAT maps |
| `FEED_ADSBLOL` | `yes` | Feed adsb.lol (ODbL, community-run) |
| `FEED_FLIGHTAWARE` | `yes` | Feed FlightAware (claim the station afterwards) |
| `FEED_ADSBFI` | `yes` | Feed adsb.fi |
| `FEED_ADSBX` | `yes` | Feed ADS-B Exchange |
| `FEED_AIRPLANESLIVE` | `yes` | Feed airplanes.live |
| `FEED_OPENSKY` | `no` | Feed OpenSky Network |
| `FEED_FR24` | `no` | Feed FlightRadar24 (interactive signup only) |
| `OPENSKY_USERNAME` | *(blank)* | OpenSky account name, if you already have one |
| `ENABLE_MLAT` | `yes` | Enable MLAT on supported feeds |
| `ENABLE_UAT` | `no` | Install dump978-fa (978 MHz, US only, needs a second SDR) |
| `SDR_SERIAL_1090` | *(auto)* | 1090ES dongle serial (pin with `rtl_eeprom -s`) |
| `SDR_SERIAL_978` | *(auto)* | 978 UAT dongle serial |
| `NODE_HOSTNAME` | *(skip)* | Set system hostname |
| `TIMEZONE` | *(skip)* | Set system timezone (NTP is always enabled — MLAT needs it) |
| `READSB_GAIN` | `-10` | SDR gain (-10 = AGC) |
| `SKIP_SYSTEM_UPDATE` | `no` | Skip apt update/upgrade on re-runs |
| `FORCE_REINSTALL` | `no` | Rebuild feeds that are already running (or pass `--force`) |
| `RESTORE_UUIDS` | *(auto)* | Path to a saved `uuids.env` (or pass `--restore-uuids`); auto-detects `/boot/firmware/adsb-uuids.env` |

See [`config.env.example`](config.env.example) for the full list.

## Requirements

- Ubuntu 24.04 or 26.04 (64-bit) — Server or Desktop
- Raspberry Pi 4B / 5 or x86_64
- RTL-SDR dongle (any RTL2832U-based, e.g. FlightAware Pro Stick)
- Internet connection for feed uploads

## After install

- **tar1090 map**: `http://<node-ip>/tar1090`
- **FlightAware claim**: If you enabled PiAware, visit [flightaware.com/adsb/piaware/claim](https://flightaware.com/adsb/piaware/claim) to link your station
- **OpenSky**: register at [opensky-network.org/my-opensky](https://opensky-network.org/my-opensky)
- **Back up your station identity**: copy `/etc/adsb-node-uuids.env` off the node (see [Reimaging](#reimaging-without-losing-your-station))
- **Verify feeds**:

```bash
systemctl status adsblol-feed adsbfi-feed adsbexchange-feed airplanes-feed piaware opensky-feeder
jq '.last1min.messages, .last1min.tracks.all' /run/readsb/stats.json
```

Each aggregator also has a station status page — check that your data is arriving. The full install log is at `/var/log/adsb-bootstrap.log`.

## SDR serial pinning

Identical USB dongles enumerate in random order across reboots. If you have multiple SDRs (e.g. 1090 + 978), you **must** pin each to a serial string — don't rely on device index.

```bash
# Program a serial (unplug and replug after)
rtl_eeprom -s "stx:1090:0"

# Check what serial a dongle currently has
rtl_test -t    # serial shown in first few lines; ctrl-c after
```

Set `SDR_SERIAL_1090` and `SDR_SERIAL_978` in your config to match.

## Known gotchas

- `PLL not locked` / `No E4000 tuner found` in `rtl_test` — **harmless**, ignore it
- `soapysdr-module-rtlsdr` is a hidden runtime dep for dump978-fa — pre-installed by the bootstrap
- FlightAware apt repo can be flaky — PiAware is installed via their repo `.deb` fallback
- tar1090 showing traffic ≠ proof of correct dongle pin — verify the serial in `journalctl -u readsb`
- Both RTL-SDR dongles are USB 2.0 internally — the physical port (USB 2 vs 3) doesn't matter for performance; space them apart for thermal reasons
- Feed installer logs live at `/usr/local/share/<feed>/lastlog` if an `update.sh` fails

## Roadmap

- [ ] AIS receiver support (RTL-SDR + AIS-catcher / rtl-ais) — dual-mode nodes
- [ ] Ansible playbook for fleet management
- [ ] Auto-update mechanism for feed scripts

## Contributing

PRs welcome — especially for new aggregator feeds, OS compatibility, and hardware support. Please test on real hardware before submitting.

This project is not affiliated with any of the aggregators listed above.

## License

MIT — see [LICENSE](LICENSE).
