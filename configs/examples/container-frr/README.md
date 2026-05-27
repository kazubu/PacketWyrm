# Container / netns FRR example

End-to-end recipe for running an FRR (or BIRD) routing daemon on top
of a PacketWyrm TAP. The routing daemon sees the TAP as a normal NIC;
its peer is reachable through the FPGA's SFP+ port (via the DUT under
test). Control-plane packets (ARP, ICMP, BGP TCP/179, OSPF, ...) are
classified by the FPGA, punted to the daemon, and dispatched into the
TAP fd. The TAP appears in the operator-chosen network namespace.

> The PacketWyrm daemon must be running first (`packetwyrmd -c
> ../single-card.yaml`). Without a real FPGA card the punt path will
> not fire on its own; this recipe still works to validate the daemon
> + TAP + namespace plumbing, and a routing peering against a peer on
> a separate netns / host wired through the same TAP.

## Topology

```
              netns r1                       netns r2
  +-----------------------------+    +----------------------------+
  | FRR  (AS 65001)             |    | FRR (AS 65002)             |
  |    bgpd peers with          |    |   bgpd peers with          |
  |    192.0.2.2                |    |   192.0.2.1                |
  +--------------+--------------+    +--------------+-------------+
                 |                                   |
        tap-pw-p0-v100  (PacketWyrm)        veth-r2 (peer host)
                 |                                   |
                 +--- DUT / switch carrying both ----+
```

In a real lab `r2` lives on a different host or VM reachable through
the SFP+ link. For local-only validation `r2` can be another local
netns wired to `tap-pw-p0-v100` via a bridge.

## Files

  - `frr-r1.conf`     -- FRR (vtysh) config for r1 (AS 65001)
  - `start-r1.sh`     -- moves the TAP into netns r1, brings it up,
                         launches FRR

## Steps

1. Start the PacketWyrm daemon:

   ```sh
   sudo packetwyrmd -c /etc/packetwyrm/single-card.yaml -v
   ```

   You should see `tap tap-pw-p0-v100 lif_id=1000 ...` in the
   startup banner, and the netdev appears in `ip link`.

2. Launch the routing namespace:

   ```sh
   sudo bash configs/examples/container-frr/start-r1.sh tap-pw-p0-v100 r1
   ```

   The script does, equivalently:

   ```sh
   ip netns add r1
   ip link set tap-pw-p0-v100 netns r1
   ip netns exec r1 ip link set tap-pw-p0-v100 up
   ip netns exec r1 ip addr add 192.0.2.1/30 dev tap-pw-p0-v100
   ip netns exec r1 frr -d --vty_port 0 -f frr-r1.conf
   ```

3. Verify with `vtysh`:

   ```sh
   sudo ip netns exec r1 vtysh -c 'show bgp summary'
   ```

   Once the peer is up, this returns a non-empty neighbour table.

4. From PacketWyrm's side, monitor traffic via the stats RPC:

   ```sh
   pktwyrm stats --watch 1000
   ```

   Punt counters (BGP/OSPF/ARP frames forwarded to the TAP) and
   inject counters (FRR's outbound packets pushed to the FPGA TX
   slow path) climb as the BGP session establishes.

## Docker / Podman variant

If you prefer a container runtime, the same idea works with:

```sh
podman run --rm --network none --name r1 \
       --cap-add NET_ADMIN -v /etc/frr-r1:/etc/frr:ro \
       quay.io/frrouting/frr:latest sleep infinity

# Bind the TAP into the container's network namespace:
pid=$(podman inspect -f '{{.State.Pid}}' r1)
mkdir -p /var/run/netns
ln -s /proc/$pid/ns/net /var/run/netns/r1
ip link set tap-pw-p0-v100 netns r1
podman exec r1 ip link set tap-pw-p0-v100 up
podman exec r1 ip addr add 192.0.2.1/30 dev tap-pw-p0-v100
podman exec r1 /usr/lib/frr/frrinit.sh start
```

The choice between bare `ip netns` and a container runtime is
purely operational; PacketWyrm only requires that *something*
holds the TAP fd in the routing daemon's network namespace.
