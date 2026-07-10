# Firmware update

`pktwyrm firmware update` writes a new FPGA bitstream to the config
flash on a card. Unlike most CLI verbs, this is a **local, direct-card**
operation — it does *not* go over the daemon control socket. It needs
root, and the card must **not** be in use by a running daemon, so stop
`packetwyrmd` first.

```sh
sudo systemctl stop packetwyrmd            # free the card
sudo pktwyrm firmware update image.bin --card 07:00.0 --boot
sudo systemctl start packetwyrmd           # bring it back
```

## What it does

In order:

1. Reads the currently running `build_id`.
2. Validates the `.bin` (size / range).
3. Live-writes the config flash over PCIe — the PCIe link stays up
   throughout.
4. Read-back verifies the written image.
5. With `--boot`, triggers an ICAP reload plus a PCIe remove/rescan,
   then confirms the `build_id` **changed** — proving the new image
   actually booted.

Without `--boot` it writes and verifies only; the running image is left
untouched until the next power-cycle or reboot.

## Flags

- `--card BDF` (required) — the PCIe address, e.g. `07:00.0` or the
  fully-qualified `0000:07:00.0`.
- `--boot` — reload into the new image now. Expect a brief PCIe drop
  during the remove/rescan.
- `--scratch` — write the `0xE00000` dev/scratch region instead of the
  boot image at offset `0`. Incompatible with `--boot` (the loader boots
  from offset `0`), and a full ~12 MB image does **not** fit in the
  scratch region — use the default (boot image) for a real update.

## Cautions

- The default target is the **boot image** (offset `0`), so a plain
  `firmware update image.bin --card BDF` (no `--scratch`) replaces what
  the card boots on next reload.
- A bad image that fails to re-enumerate needs **JTAG recovery** — keep
  a known-good `.bin` on hand before you flash.
- Multiple cards: run the command once per `--card`.
- A bitstream/software mismatch is possible, and there is **no
  auto-rollback**. Confirm the daemon comes back healthy after a
  `--boot` (see [installation.md](installation.md) and
  [running-tests.md](running-tests.md)).

If the update fails with `backend open failed`, the card is still bound
to a daemon (or not bound to `vfio-pci`), or the BDF is wrong — see
[troubleshooting.md](troubleshooting.md).
