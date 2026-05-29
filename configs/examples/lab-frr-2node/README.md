# lab-frr-2node

Two FRR routers in containers, each bound to a PacketWyrm TAP, peering
eBGP across a DUT under test.

```
                      DUT under test (switch / router)
                  +-------- VLAN 100 ---------+
                  |                           |
            tap-pw-p0-v100              tap-pw-p1-v100
                  |                           |
   +-----------------+                +-----------------+
   |  netns r1       |                |  netns r2       |
   |  192.0.2.1/30   |                |  192.0.2.2/30   |
   |  FRR (AS 65001) | <--- eBGP ---> |  FRR (AS 65002) |
   +-----------------+                +-----------------+
```

## Files

  - `packetwyrm.yaml` -- PacketWyrm data-plane config (1 card, 2
    LIFs, no flows)
  - `lab.yaml`        -- lab spec consumed by `tools/pktwyrm-tinet`

## Bring up

```sh
# Render lab into tinet + FRR configs under /tmp/lab-frr/
python3 tools/pktwyrm-tinet/generate.py generate \
    configs/examples/lab-frr-2node/lab.yaml \
    -o /tmp/lab-frr/

# Start daemon (creates TAPs in root netns).
sudo packetwyrmd -c configs/examples/lab-frr-2node/packetwyrm.yaml -v &

# tinet up creates containers and moves TAPs into each netns.
sudo sh -c "cd /tmp/lab-frr && tinet up   -c tinet.yaml | sh"
sudo sh -c "cd /tmp/lab-frr && tinet conf -c tinet.yaml | sh"

# Watch the session establish.
sudo docker exec r1 vtysh -c 'show bgp summary'
```

Without a real FPGA the TAPs still appear but no traffic flows; this
recipe is useful to validate the daemon + tinet + netns plumbing end
to end before plugging the SFP+ cables in.

## Tear down

```sh
sudo sh -c "cd /tmp/lab-frr && tinet down -c tinet.yaml | sh"
sudo pkill packetwyrmd
```

## See also

  - `tools/pktwyrm-tinet/README.md` -- generator docs
  - `configs/examples/container-frr/` -- the bare `ip netns` recipe
    that this lab spec supersedes once you have >1 router
