# Installation

PacketWyrm ships three programs:

- `packetwyrmd` — the daemon that owns the FPGA card(s) and serves a control
  socket.
- `pktwyrm` — the command-line client.
- `packetwyrm-proxyd` — an optional HTTPS gateway that serves the Web GUI and
  relays RPCs (see [web-gui.md](web-gui.md)).

## Option A — Debian package (Ubuntu/Debian)

```sh
sudo dpkg -i packetwyrm_<version>_<arch>.deb
# if dpkg reports missing dependencies:
sudo apt-get -f install
```

The package installs:

- the binaries to `/usr/bin`,
- systemd units `packetwyrmd.service` and `packetwyrm-proxyd.service`
  (installed **disabled** — nothing starts automatically),
- an example env config at `/etc/packetwyrm/packetwyrm.yaml` and a gateway
  config at `/etc/packetwyrm/proxyd.yaml` (both conffiles),
- the `packetwyrm` system user/group (the gateway runs as it),
- shell completions, man pages, and a Grafana dashboard under
  `/usr/share/packetwyrm/`.

Release `.deb`s are published on tag pushes (GitHub Releases).

### Bring it up

1. Edit `/etc/packetwyrm/packetwyrm.yaml` for your card(s) — or generate a
   skeleton from the hardware present:

   ```sh
   sudo pktwyrm init --out /etc/packetwyrm/packetwyrm.yaml
   ```

   See [configuration.md](configuration.md).

2. Start the daemon (management plane only — **no traffic yet**):

   ```sh
   sudo systemctl enable --now packetwyrmd
   ```

3. Optional — start the Web GUI gateway (loopback by default; see
   [web-gui.md](web-gui.md) to expose it):

   ```sh
   sudo systemctl enable --now packetwyrm-proxyd
   ```

Upgrading the package (`dpkg -i` a newer one) restarts a running daemon onto
the new binary without leaving it stopped; a fresh install never auto-starts.

## Option B — build from source

Build deps: `build-essential pkg-config libyaml-dev libjson-c-dev libssl-dev`
(plus `python3` for the GUI asset embed).

```sh
make -C sw            # libpacketwyrm + packetwyrmd + pktwyrm + packetwyrm-proxyd
make -C sw test       # host unit tests
sudo make -C sw install    # -> /usr/local (DESTDIR supported)
```

To build a `.deb` yourself:

```sh
make -C sw deb        # -> packaging/dist/packetwyrm_<version>_<arch>.deb
```

## The explicit-start model (read this once)

Starting the daemon — or loading a config — programs the flows but **transmits
nothing**. Traffic begins only on an explicit `pktwyrm test start` (or
`flow start`). This is deliberate: bringing the daemon up never puts packets on
a live network by surprise. Launch `packetwyrmd -a` / `--autostart` for the
legacy "generate as soon as programmed" behavior. See
[running-tests.md](running-tests.md).

## Permissions

`packetwyrmd` runs as root (it mmaps the FPGA BAR and creates TAP devices). The
control socket is `/run/packetwyrm/packetwyrmd.sock`, mode `0660 root:packetwyrm`
— so `pktwyrm` must run as root or as a member of the `packetwyrm` group. If a
`system.secret` is set in the env config, every client must supply it (see
[configuration.md](configuration.md)).
