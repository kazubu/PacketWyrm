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
# One command: generate, start packetwyrmd, wait for TAPs,
# tinet up, tinet conf.
sudo python3 tools/pktwyrm-tinet/pktwyrm-tinet up \
    configs/examples/lab-frr-2node/lab.yaml \
    -o /tmp/lab-frr/

# Watch the session establish.
sudo docker exec r1 vtysh -c 'show bgp summary'

# Check status any time:
python3 tools/pktwyrm-tinet/pktwyrm-tinet status -o /tmp/lab-frr/
```

Without a real FPGA the TAPs still appear but no traffic flows; this
recipe is useful to validate the daemon + tinet + netns plumbing end
to end before plugging the SFP+ cables in.

## Tear down

```sh
sudo python3 tools/pktwyrm-tinet/pktwyrm-tinet down -o /tmp/lab-frr/
```

## See also

  - `tools/pktwyrm-tinet/README.md` -- generator docs
  - `configs/examples/container-frr/` -- the bare `ip netns` recipe
    that this lab spec supersedes once you have >1 router
