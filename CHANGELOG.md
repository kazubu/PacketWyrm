# Changelog

All notable changes to PacketWyrm. The project is in active
pre-release development; this file is updated per development
push and is the source of truth for "what's working today".

For where work is going next, see `NEXT-STEPS.md`.

## Unreleased

### Added
  - **libpacketwyrm device-driver / IO hardening (part-review #3).** Scope:
    pci/tap/sfp/spi_flash/gpio_sync/ipc. Eleven fixes:
    - **P1: SPI flash — 24-bit address range validated.** `pw_flash_program`
      rejects `offset ≥ 16 MB`, `len > 16 MB`, or `offset+len > 16 MB`
      (`PW_E_OUT_OF_RANGE`, computed in 64-bit) — `addr3()` silently dropped
      high bits, so an out-of-range write could erase/program the WRONG region.
    - **P1: SPI flash — page-program no longer crosses a physical page.** For a
      non-256-aligned offset the first chunk is now clamped to the bytes left in
      that page; a page-program overrun wraps to the page start on most SPI NOR
      and would corrupt the page head.
    - **P1: TAP interface names are validated, not truncated.** `pw_tap_open` /
      `set_up` / `set_mac` / `set_mtu` reject a name `≥ IFNAMSIZ`
      (`PW_E_INVAL`) instead of `strncpy`-truncating — a truncated name targets
      a *different* netdev.
    - **P1: SFP I2C CSR errors propagate.** A latched-error flag in the bit-bang
      bus turns a mid-transaction BAR/VFIO `write32`/`read32` failure into
      `PW_E_IO` from `pw_sfp_read`/`pw_sfp_write`, instead of reading it as
      ACK=0 / data=0 and reporting a successful transfer of zeros.
    - **P1: `pw_ipc_listen` validates the path before touching the filesystem
      and only unlinks a socket.** It no longer `unlink()`s before the length
      check, and refuses (`PW_E_IO`) to replace a non-socket at the path — the
      root-run daemon won't clobber a regular file/dir sharing the name.
    - **P2: `pw_sfp_read` bounds its range to the 256-B page** (matched
      `pw_sfp_write`).
    - **P2: `pw_flash_read_id` NULL-checks its output.**
    - **P2: `pw_gpio_sync_write_correction` bounds the slot** to the flow-table
      capacity (a wild `slot*8` could write past the correction table into the
      flow-id-map window).
    - **P2: IPC writes use `send(MSG_NOSIGNAL)`** so a peer close surfaces as
      `PW_E_IO` rather than SIGPIPE-killing a library user that hasn't ignored
      it.
    - **P3: `logical_if.netns` is rejected at validate** (parsed but the TAP
      layer isn't namespace-aware — was silently ignored, leaving the TAP in
      the daemon's namespace).
    - **The SPI-flash and SFP-I2C serialization contract is documented** in
      `spi_flash.h` / `sfp.h` (not internally synchronized; the caller — the
      daemon's single-threaded control loop — serializes per-card access; the
      card worker never touches those CSRs). A cross-process race is an operator
      hazard no in-process lock addresses.
    - No P0. sw test 473/473, e2e+proxyd 35, check-schema 20, sim_all green.
  - **libpacketwyrm config/flow-compiler hardening (part-review #2).** Eight
    fixes in the config/validate/compile layer:
    - **P1: a cross-card background (load) flow no longer aliases a real flow's
      RX slot.** It speculatively numbered `rx_local_flow_id` from
      `rx_cp->n_flow_rows` but then returned without appending an RX row, so a
      later real flow on the same RX card reused that slot — and the daemon's
      `servo_lat_correction` (which writes every cross-card flow's slot) would
      corrupt the real flow's correction, plus `flow.stats` reported the wrong
      RX counters. `pw_flow_meta` gains `rx_slot_valid` (false for background);
      the compiler points a background flow's `rx_local_flow_id` at its TX slot
      and the daemon skips `!rx_slot_valid` flows in the servo, priming,
      `flow.stats` RX read, and `flow.hist`. Unit test asserts the flag + no
      slot collision.
    - **P1: the flow compiler fails early at flow-table capacity.** `append_flow`
      grew rows unboundedly, so a config with >`PWFPGA_FLOW_TABLE_ROWS` flows on
      a card compiled into a program with out-of-range `local_flow_id`s that
      only `pw_program_card_tables` would reject at write time. `compile_one_flow`
      now returns `PW_E_NO_RESOURCES` (with a per-flow diagnostic) when either
      the TX or RX card is at capacity.
    - **P2: duplicate YAML mapping keys are rejected** (was silent first-wins —
      a flow with two `id:`/`traffic:` lines dropped one without warning).
    - **P2: multiple top-level YAML documents are rejected** (was: the parser
      stopped at the first `DOCUMENT_END`, silently ignoring trailing docs).
    - **P2: unknown TOP-LEVEL config keys are rejected** (`flowss:`, `systm:` →
      parse error via a new allow-list check); the `config.h` doc is corrected
      to state that nested-mapping keys are still ignored (JSON schema is the
      authoritative allow-list) rather than over-claiming full rejection.
    - **P2: `l2.pcp` is range-checked 0..7** (802.1Q PCP is a 3-bit field; 8..255
      slipped through before).
    - **P2: background flows reject `measurements`** at validate (TX-only; loss/
      latency/jitter can't be measured — was silently unmeasured at runtime).
    - **P3: `pw_parse_mac` rejects trailing junk / extra octets** (`%n`-checked
      full consumption), matching the earlier `pw_parse_u64` hardening.
    - **Re-check (3 follow-ons from the above):** (P2) `pw_stats_aggregate()`
      now honors `rx_slot_valid` too — a background flow reports
      `latency_valid=false` and zero RX-derived counters even if the caller
      passes bogus RX stats (the library API matched to the daemon contract).
      (P2) the `flows` RPC (`build_flows`) reports `latency_valid:false` +
      `latency_method:"none"` + a new `background` boolean for background flows,
      so it agrees with `flow.stats`/`flow.hist`. (P3) the multi-document
      rejection now counts document-starts instead of `root != NULL`, so a
      stream whose *first* document is empty (`---\n---\nsystem:…`) is still
      rejected. Tests cover all three.
    - No P0. Build clean, sw test 461/461, e2e+proxyd 35, check-schema 20,
      sim_all green.
  - **libpacketwyrm backend/DMA boundary hardening (part-review #1).** Seven
    defensive fixes at public-API boundaries (the daemon's compiler already
    constrains normal inputs; these stop a corrupt/hand-built input from
    mis-programming the FPGA):
    - **P1: `pw_program_card_tables()` now validates the program up front.**
      Rejects (`PW_E_INVAL`) counts over the CSR-window capacities
      (`n_fc_cmps/udfs/rules`, `n_hash_entries`) and indices past their windows
      (map `flow_id ≥ FLOWID_MAP_DEPTH`, hash `index ≥ HASH_DEPTH`), plus
      non-zero-count/NULL-array pairs. Without this a wild index became a CSR
      offset that could alias a *different* in-BAR window (the per-write size
      check only catches offsets past the BAR end). Unit test asserts the
      rejections.
    - **P1: BAR row/lfid offsets computed in 64-bit.** `bar_flow_write` /
      `bar_flow_stats_read` / `bar_flow_hist_read` / `bar_port_stats_read`
      built `window + id*stride` in `uint32_t`, so a huge `row`/`lfid` could
      wrap to a small value that passed the range check and aliased another
      window. All windowed accessors now route through a new `csr_range_ok()`
      helper that computes in 64-bit **and** accounts for `csr_off` (the actual
      access is `csr_off + off`, which the old `base + len > size` checks
      ignored — P2, harmless at today's `csr_off = 0` but wrong for the probed
      `+0x10000` layout).
    - **P2: C2H (punt) channel-status errors are now observed.** `dma_slow_path_rx`
      reads `PWFPGA_XDMA_CH_STATUS`; on `STAT_ERR` it rate-limit-warns and clears
      the latched error (so a stalled punt is visible in the log instead of
      looking idle). It deliberately does **not** stop/re-arm — the
      continuously-armed ring's re-arm timing is fragile (documented history),
      so recovery stays a manual restart.
    - **P2: `pw_stats_aggregate()` rejects sizes that would wrap** (`n_flow_meta
      * 2`, `sizeof(*out) * n_flow_meta`) + NULL `flow_meta` guard, before the
      capacity checks — closes an OOB read/write on a corrupt count.
    - **P3: fake backend matches the real backend's input contract** —
      `fake_flow_write` rejects NULL `f`; `fake_slow_path_tx` rejects
      `frame==NULL && len>0` (no memcpy-from-NULL).
    - **P3: `pw_vfio_map_dma()` enforces its documented page-alignment**
      (`vaddr`/`len` vs `_SC_PAGESIZE`) and IOVA-range non-wrap, returning
      `PW_E_INVAL` instead of flattening a misaligned request to an opaque
      ioctl `PW_E_IO`.
    - **P1 (re-check): per-window index ceilings, not just the BAR.** The first
      pass fixed 32-bit wrap + `csr_off`, but a valid in-BAR offset could still
      alias the *adjacent* window (flow-table `row=64` → histogram window base;
      a large histogram `lfid` → stats window). Added `PWFPGA_FLOW_TABLE_ROWS`
      / `FLOW_HIST_SLOTS` / `FLOW_STATS_SLOTS` capacity macros (csr.h) and bound
      each windowed accessor to its own window; `pw_program_card_tables` rejects
      `n_flow_rows` over the flow-table capacity and clamps the
      invalidate-to-capacity loop so a misreported `num_local_flows` can't
      alias either. Unit test asserts the row-over-capacity rejection.
    - **P1 (re-check #2): the last flow row stays usable.** The first ceiling
      derived the row count from the flow-commit register and required the full
      256-B *stride* to fit before it → 63, wrongly rejecting the 64th row on a
      64-flow card. But the commit register sits in the unused tail of row 63's
      slot (row 63's 244-B write ends at 0x9FF4, before commit at 0x9FFC), so
      all 64 rows are valid. `PWFPGA_FLOW_TABLE_ROWS` is now derived from the
      next window (0xA000) = 64, and `bar_flow_write` bounds by the *actual*
      `sizeof(*f)` extent vs the commit register (keeps row 63, refuses row 64,
      and catches a future struct-growth overrun). BAR-backend test asserts
      row 63 accepted / row 64 rejected.
    - No P0 found; worker/main thread-safety in this layer (atomic host-plane
      counters, mutex'd fake FIFO, worker-owned BAR DMA state) held up.
  - **`ipc_listen_connect` unit test honors `$TMPDIR` (review #11).** The test
    hard-coded `/tmp/pw-ipc-test-<pid>.sock`; in a sandbox / CI runner where
    `/tmp` is not bindable for `AF_UNIX` (`bind()` → `PW_E_IO`) the test failed
    even though the IPC code is correct. It now binds under `$TMPDIR` (falling
    back to `/tmp`) and quietly skips if the resulting path would exceed
    `sun_path` (~108 B) — a portability guard, not a code change. `make -C sw
    test` no longer depends on `/tmp` being bindable. It also surfaces
    `errno`/`strerror` + the path on a listen/connect failure, and — when
    `bind()` is denied outright by the environment (`EPERM`/`EACCES`/`EROFS`,
    e.g. a seccomp-restricted sandbox) — skips gracefully like the TAP test
    does on missing `CAP_NET_ADMIN`, while any other errno still fails the
    assert so a real bind regression is caught. Review #11 otherwise found no
    P0/P1 (this was the sole finding, a P2 test-portability nit).
  - **Control-socket default path unified to `/run` (review #10).** The
    compile-time default (`PW_IPC_DEFAULT_PATH`), the `config.c` fallback, docs,
    README, and the example env config all wrote `/var/run/packetwyrm/packetwyrmd.sock`
    while the shipped systemd units use `/run/packetwyrm/packetwyrmd.sock`.
    `/var/run` is a symlink to `/run` so the two resolve identically, but the
    mismatch was confusing; everything now uses `/run/...` to match packaging.
    No behavior change. Review #10 otherwise found no P0/P1 (the remaining
    flagged items are the owner-accepted `pktwyrm --host` unverified-TLS lab
    tradeoff, already documented, and the documented kernel skeleton).
  - **Background-flow `flow_meta` fix + proxyd loopback default (review #9).**
    - **P1: a background (load) flow left its `flow_meta` zero-initialized.** The
      flow compiler filled `prog->flow_meta[i]` *after* the background flow's
      early return, but the daemon requires `cfg->flows[i]` ↔ `flow_meta[i]` to
      be 1:1 — so `flows`/`flow.stats` RPCs, `test.start`/`test.stop`, and the
      `config.load` quiesce all read flow_id 0 / card 0 / slot 0 for a background
      flow (wrong card/enabled, wrong stats slot, un-quiesceable). `flow_meta` is
      now populated before the early return (`latency_valid=false`, TX-only);
      unit test asserts the background flow's meta id/slot.
    - **P3: the shipped `packetwyrm-proxyd` unit binds `127.0.0.1:8443` by
      default.** It bound `0.0.0.0`, which correctly fail-closes without a
      `system.secret` — but the first-install seeded config has none, so proxyd
      failed to start out of the box. Loopback is a clean default; exposing it is
      a deliberate opt-in (set a secret + `--listen 0.0.0.0:8443`).
  - **Stats-counter data race + proxyd Content-Length + TLS-tradeoff docs
    (review #8).** Three items:
    - **P2: host-plane stats counters are now atomic.** The per-binding
      punt/inject counters were plain `uint64_t` incremented by the card worker
      thread while the main thread read them for the stats snapshot — a C data
      race (UB / torn 64-bit reads). They are now `_Atomic uint64_t` (the `x++`
      RMW and the stats read are well-defined); ordering is not relied on.
    - **P3: proxyd parses `Content-Length` strictly.** It used `strtoul` at any
      offset with no validation; it now matches only at a header-line start,
      requires a purely-numeric value (digits then CR/LF), rejects overflow, and
      rejects a duplicate `Content-Length` (a request-smuggling vector behind a
      reverse proxy).
    - **P1 (accepted tradeoff, documented): `pktwyrm --host` unverified TLS.**
      The remote channel is encrypted but not authenticated (self-signed,
      unverified), so a MITM could capture the secret. Kept as an accepted lab
      tradeoff (use over a trusted network / SSH tunnel / VPN) — the one-time
      warning now spells out the MITM risk, and `web-gui.md` documents it with
      the mitigations; cert/fingerprint pinning is tracked as a future addition.
  - **First-install config seed + proxyd relay timeout + kernel CI (review #7).**
    "No serious issues"; three P2/P3 + CI-gap items:
    - **P2: the shipped unit's config file is now seeded on first install.**
      `packetwyrmd.service` runs `-c /etc/packetwyrm/packetwyrm.yaml`, but
      `make install` only shipped `*.yaml.example`, so a fresh `systemctl start`
      failed on a missing config. `install` now seeds `packetwyrm.yaml` from
      `single-card.yaml` **only if absent** (0640; never clobbers operator
      edits) and the post-install note says to edit it.
    - **P3: the proxyd→daemon relay is now bounded by a timeout.** `daemon_relay`
      connected and read the daemon's reply with no timeout, so a busy/wedged
      (single-threaded) daemon could pin a proxyd worker — and eventually all of
      `PROXYD_MAX_THREADS` — indefinitely. It now sets a 10 s
      `SO_RCVTIMEO`/`SO_SNDTIMEO` on the daemon socket.
    - **CI gap: the kernel skeleton is now built in CI** (best-effort — installs
      the runner's `linux-headers`, builds if kbuild is present, skips gracefully
      otherwise) so a compile break (like the earlier `pci_dev` mistype) is caught.
  - **Lab-tool safety + concurrency contract + injection guards (fresh-context
    review #6).** No P0 blocker (all CI green); one P1 + several P2/P3:
    - **P1: `pktwyrm-tinet down` could kill an unrelated process.** `LabState`
      stored only the daemon PID and `pid_alive()` was a bare `os.kill(pid,0)`;
      a stale state file whose PID was recycled would let `down` (run as root)
      SIGTERM/SIGKILL a different process. The state now also records the daemon's
      `/proc/<pid>/stat` starttime, and up/down/conf verify identity
      (`daemon_alive_and_ours`: starttime + a packetwyrmd cmdline) before acting —
      a recycled PID is never signalled. Regression test added.
    - **P2: documented the backend concurrency contract** (`backend.h`): a card's
      ops run from both its worker thread (slow path) and the main thread
      (control RPCs); a backend with shared mutable state must lock internally.
      The fake backend now mutex-guards its slow-path FIFO (the one genuinely
      shared structure); the BAR backend's worker/main state is disjoint
      (documented) so it needs none.
    - **P3: `pktwyrm-tinet` validates lab-YAML values that reach FRR config.**
      router name (charset), `router_id`/neighbor (IP), `network` (CIDR) are now
      validated at load, so a value with a newline/control char can't inject FRR
      directives (shell was already `shlex`-quoted). Injection test added.
    - **P4: doc drift fixed** — `risks.md` claimed a headless `make synth` CI job
      (CI is Verilator sim + lint, no Vivado); `daemon.md` process model now marks
      the `epoll`/SPSC/stats-aggregator design as target vs the implemented
      main-thread `poll()` + per-card workers.
    - **P5: kernel skeleton** `struct pw_card.pci` retyped `pci_dev __iomem *` →
      `pci_dev *` (a PCI device pointer, not MMIO).
  - **Operational-safety hardening (fresh-context review #5).** No P0/P1 found
    (all CI targets pass); four P2/P3 operational items fixed:
    - **proxyd refuses `--no-tls` on a non-loopback bind.** With
      `--no-tls --listen 0.0.0.0:…` the access secret (in the JSON body) would
      cross the network in plaintext even when the daemon requires one. It now
      refuses unless `--insecure-no-auth` (or a loopback bind); `--no-tls` on
      127.0.0.1 (localhost / SSH tunnel) is still fine.
    - **`config.load` topology check compares the actual binding, not just ids.**
      `same_topology` only compared card/lif *ids* + counts, so a combined YAML
      that kept the ids but changed a PCI BDF, a port's `global_port`, or a lif's
      `name`/`vlan`/`global_port`/`mac` was accepted as "same topology" — the env
      part silently discarded, flows applied on the *old* topology, a false
      success. It now also compares pci/ports and lif name/vlan/global_port/mac.
    - **`scripts/check-schema.sh --strict`** (used by CI) fails instead of
      skipping when `python3`/`yaml`/`jsonschema` are missing, so a future CI
      change that drops the deps can't silently stop catching schema drift.
    - **`pktwyrm-tinet` no longer leaks the daemon log fd** — `_start_daemon`
      now opens it in a `with` block so the parent's copy is closed on both the
      success and error paths (the child keeps its inherited dup).
  - **Config-name consistency + JSON-schema catch-up (fresh-context review #4).**
    A fourth from-scratch review found:
    - **`pktwyrm-tinet` ignored a custom `logical_interfaces[].name`.** The daemon
      names the TAP after the lif's `name` (or synthesizes `tap-pw-p<gp>-v<vlan>`
      when absent); the lab tool always synthesized the name, so a custom-named
      lif made the tool wait for the wrong netdev and time out. It now mirrors the
      daemon (use `name` if set, else synthesize).
    - **The validator now rejects duplicate `logical_if` names and over-length
      names.** The name becomes the Linux TAP netdev name (IFNAMSIZ), so two lifs
      with the same name would collide and a name ≥ 16 chars would be silently
      truncated — the comment claimed name-dup was checked but only `id` was.
      Added both checks + a `validate_lif_name_rules` unit test.
    - **JSON schema caught up to the split env/test config + Phase 3 flow
      features.** The schema still required a single combined file
      (`system`+`cards`+`logical_interfaces`+`flows`, `udp` mandatory) and lacked
      `forwards`, `system.secret`, and the flow keys `tcp` / `ipv6` / `modifiers`
      / `classify` / `encap` / `rx_expect` / `background` / `frame_template` /
      l2 `ethertype`, so only 2 of the 20 example configs validated. Made it
      split-aware (no section strictly required; env-only / test-only / combined
      all valid) and added the missing properties + a `forward` def. **All 20
      `configs/examples/*.yaml` now validate**, and `scripts/check-schema.sh`
      (run in CI) was broadened from 2 files to every example, so schema drift is
      actually caught going forward.
  - **Packaging / CI-coverage / docs fixes (fresh-context review #3).** A third
    from-scratch review (Codex ran the CI targets + a staged install) found
    coverage gaps and a shipped-unit config bug:
    - **`config.save` would fail under the shipped systemd unit.**
      `packetwyrmd.service` has `ProtectSystem=strict` with `ReadWritePaths`
      that omitted `/etc/packetwyrm`, so the atomic env-file rewrite
      (`config.save`, GUI/CLI env edit) would hit a read-only `/etc` — a failure
      the non-systemd e2e can't see. Added `/etc/packetwyrm` to `ReadWritePaths`.
    - **FPGA lint now covers the Phase 3 production data-plane core**, not just
      the Phase 1 top. Added `scripts/lint-phase3.sh` (Verilator lint of
      `pwfpga_top_phase3`: data plane + DMA slow path + classifiers + GPIO/ICAP/
      SPI, with the taxi submodule) and wired it into `make lint` and the CI step
      (renamed to reflect phase1 + phase3-core; the vendor-heavy phase3 *board*
      wrapper stays a Vivado-synth check).
    - **CI now runs the `pktwyrm-tinet` unit tests and `scripts/check-schema.sh`**
      (added `python3` + `python3-yaml` + `python3-jsonschema` to the host job) —
      previously neither ran in CI, so tinet regressions and example-YAML vs
      JSON-schema drift could land unnoticed.
    - **Doc phase-drift corrected:** `project_phase3.tcl` header (said "Phase 2"),
      `fpga/as02mc04/README.md` ("make targets build the Phase 1 top" — the
      Makefile defaults to `PHASE=3`), and `docs/design/architecture.md` (listed
      cross-card latency as out-of-scope "no clock sync" though it's implemented
      via J5 GPIO time-sync).
    - Noted (not code, HW/design): `pktwyrm --host` TLS is unauthenticated
      (self-signed, lab tradeoff — CA/fingerprint pinning is a future option),
      and Phase 3 RTL changes still want a Vivado `report_cdc`/timing gate.
  - **proxyd request-parse memory safety + doc/tooling fixes (fresh-context
    review #2).** Another from-scratch review (Codex, empty context, ran the CI
    targets) found:
    - **proxyd HTTP request-line parse could read past the buffer.**
      `read_request()` filled a `PROXYD_REQ_MAX` buffer with no NUL terminator,
      then `serve()` ran `sscanf(buf, "%7s %255s", …)` on it as a C string — a
      malformed request with no whitespace/NUL in the received bytes could scan
      past the received data into adjacent heap (DoS / info-exposure on a
      network-facing process). The buffer is now `PROXYD_REQ_MAX + 1` and
      NUL-terminated at the received length before parsing.
    - **`pktwyrm-tinet up` no longer leaks containers on a mid-bringup failure.**
      If `tinet conf` failed after `tinet up` succeeded, the netns/containers
      leaked (no state file is written on that path, so `down` couldn't clean
      them). `cmd_up` now best-effort `tinet down`s on the exception path.
    - **README / `daemon.md` / `csr-map.md` brought in line with the DMA slow
      path.** They still described the slow path as the BAR-polled punt/inject
      windows, implied a BAR-open auto-fallback to the fake backend (it needs
      `-F`), and listed cross-card latency as *rejected* (it's supported via J5
      time-sync). Updated to: PCIe-DMA slow path (`pw_dma_slowpath`, the legacy
      CSR windows are non-DMA-bitstream only); fake backend only with `-F`;
      cross-card latency supported.
  - **CI-breaking FPGA lint fix + input hardening (fresh-context review).** A
    from-scratch review (Codex, empty context) that actually RAN the CI targets
    caught three items the prior static rounds missed:
    - **FPGA `make lint` was FAILING on main (CI red).** The DMA slow-path work
      rewired `pcie_axi_lite_bridge` to the XDMA **AXI-Stream** ports
      (`m_axis_h2c_*_0` / `s_axis_c2h_*_0`) but the Verilator lint stub
      `pcie_gen3_stub.sv` still declared the old **MM master** ports (`m_axi_*`)
      → 10 `PINNOTFOUND` errors; and `pwfpga_top_phase1` didn't connect the
      bridge's new DMA stream ports → `PINMISSING`. Re-synced the lint stub to
      the AXI-Stream IP (dropped `m_axi_*`, added the H2C/C2H AXIS ports) and
      tied those ports off in the phase-1 top. `make -C fpga/as02mc04 lint` is
      green again (the `rtl-sim` CI job runs it).
    - **Unsigned config parser accepted negatives / overflow.** `pw_parse_u64`
      (base for u32/u16/u8) called `strtoull` without rejecting a leading `+/-`
      or checking `ERANGE`, so `rate_bps: -1` or an overflowing literal became a
      huge value (an unbounded rate/count). It now rejects a sign, an empty /
      underscores-only string, no-digit / trailing junk, and `ERANGE`.
    - **`pktwyrm-tinet` shell-quotes YAML-derived values.** The lab emitter builds
      shell fragments run as **root** (`tinet … | sh`); router/TAP names, addrs
      and MTU are now `shlex.quote`d so a crafted lab YAML can't inject commands.
      New unit tests for the quoting; the golden was regenerated.
  - **`config.save` mode-apply is now fatal (9th full-codebase review).** The
    tmp-file `fchmod` (which carries the env file's mode — the file holds
    `system.secret`) ignored its return; a failure would leave a wrong-mode
    file. It now aborts the save (`close`+`unlink`+error) on `fchmod` failure;
    `fchown` (owner preservation) stays best-effort. (The 9th review otherwise
    found **no High/Medium issues** — this was the sole remaining Low item.)
  - **proxyd accept-timeout check (8th full-codebase review).** The gateway's
    per-connection `SO_RCVTIMEO`/`SO_SNDTIMEO` `setsockopt` returns were ignored;
    the worker now drops the connection (closes, exits the thread) if the DoS-
    guard timeout can't be armed — symmetric with the daemon's `set_conn_timeout`.
    (The 8th review otherwise found **no High/Medium issues** — this was the sole
    remaining Low hardening item.)
  - **IPC layer robustness (7th full-codebase review).** Three items in the Unix
    control-socket layer (`ipc.c`); SW-only, covered by unit + e2e (no data-path
    or validated-socket-behavior change, so no HW re-run):
    - **Over-length socket paths are rejected, not silently truncated.**
      `sockaddr_un.sun_path` is ~108 B while `system.control_socket` is 128 B, so
      a configured path could fit the config struct but overflow the socket API —
      binding/connecting to a *different* (prefix) path. A shared
      `fill_sockaddr_un` helper now rejects `path >= sizeof(sun_path)` with
      `PW_E_OUT_OF_RANGE` in both `pw_ipc_listen` and `pw_ipc_connect`; new unit
      test `ipc_path_too_long`.
    - **`chmod` on the socket is now fatal on failure.** The mode is the access
      ACL when no secret is set, so a silent `chmod` failure could leave the
      socket at the umask default; `pw_ipc_listen` now `close`+`unlink`+errors
      instead of `(void)chmod`.
    - **Stale IPC comments corrected** (`ipc.h`, `ipc.c`, the main.c socket
      comment) — they still described the old `0666` / "future daemon group"
      model instead of the shipped `0660 root:packetwyrm` (prod) / `0666` (-F).
  - **Socket-group ACL + proxyd packaging fix (6th full-codebase review) —
    HW-validated.** The previous round's 0660 control socket (root:root) broke
    the shipped `packetwyrm-proxyd` gateway, which runs unprivileged — a
    regression the review caught:
    - **The daemon now group-owns the production socket `root:packetwyrm`** (0660)
      so the unprivileged proxyd (User/Group=`packetwyrm`) reaches it via group
      membership; a local non-root, non-`packetwyrm` user still cannot. Done with
      a best-effort `chown` after listen (via `getgrnam`); if the group isn't
      installed the socket stays root-only with a warning. Dev/CI (`-F`) keeps
      `0666`.
    - **`packaging/packetwyrm.sysusers` now creates the `packetwyrm` USER**, not
      just a group (`g` → `u`). The proxyd unit runs `User=packetwyrm`, so a
      group-only entry failed the unit with "User packetwyrm not found" on a
      clean install. Verified with `systemd-sysusers` (creates user+group) on the
      rig; the daemon then chowns the socket to `root:packetwyrm` (confirmed
      `srw-rw---- root packetwyrm`).
    - **Docs/comments updated** for the 0660 model (`web-gui.md`,
      `rpc-protocol.md`, the proxyd unit comment) — they claimed `0666`.
    - **e2e packaging check:** the proxyd unit's `User=` must be created as a user
      in the sysusers file (guards the group-only regression).
  - **Daemon honesty & socket-privilege hardening (5th full-codebase review) —
    HW-validated.** Four items (2 Medium, 2 Low; no new High). Re-validated on
    07:00.0 (daemon restarted `-F`-less on the new binary — control socket now
    `srw-rw----` 0660 root:root, no false fatal, cRPD dual-stack control plane
    reconverged: v4/v6 ping 0 % loss, OSPFv2/v3 Full, IS-IS L1+L2 Up, BGP v4+v6
    Established):
    - **`config.load` no longer claims success when the rollback itself fails.**
      On a staging failure the daemon re-programs the previous config; that
      restore's return was discarded and the reply was always "previous config
      still running". Now, if the restore ALSO fails (real card drop / BAR fault /
      window mismatch), it returns "stage failed … AND rollback failed …; device
      may be OUT OF SYNC — re-arm (test.arm) or restart". e2e regression: a new
      fake-backend sticky fault mode (`PW_FAKE_FAIL_FLAG_STICKY`) fails both the
      staging and the rollback commit; the existing rising-edge `PW_FAKE_FAIL_FLAG`
      now fails only staging (rollback succeeds) so both paths are covered.
    - **Production control socket is 0660 (root-only), not world-writable.** The
      daemon runs as root, so a client that can write the socket gets
      root-equivalent device ops (flow control, config.save, flash.write). It is
      now created `0660` unless `-F` (dev/CI keeps `0666` so non-root tests work),
      on top of the `system.secret` check.
    - **`setsockopt` timeout failures are no longer ignored** — the accept path
      uses a `set_conn_timeout` helper and drops the connection (with a warning)
      if the DoS-guard timeout can't be armed, rather than proceeding unbounded.
    - **(noted) `TIMING-9` (Unknown CDC Logic)** in `fpga-known-warnings.md`
      still needs a `report_cdc -details` pass at the next bitstream sign-off —
      an investigation that requires a Vivado run (deferred, documented).
  - **Daemon availability hardening (4th full-codebase review) — HW-validated.**
    Five items where the single-threaded daemon could hang or come up
    unmanageable. Re-validated on 07:00.0 (daemon restarted on the new binary
    without `-F`, no false fatal on the real card + TAPs, cRPD dual-stack control
    plane reconverged — v4/v6 ping 0 % loss, OSPFv2/v3 Full, IS-IS L1+L2 Up, BGP
    v4+v6 Established):
    - **A stalled local IPC client can no longer wedge the main loop.** The
      control socket is 0666 and the daemon is single-threaded, so a client that
      sent a 4-byte length header and then stalled blocked the whole loop (servo,
      metrics, every RPC) forever — a pre-auth local DoS. Accepted control-socket
      (and Prometheus) connections now get a 5 s `SO_RCVTIMEO`/`SO_SNDTIMEO`, so a
      stalled peer times out and the connection closes. e2e regression: a client
      that announces a body and never sends it, after which a normal RPC still
      succeeds.
    - **Initial FPGA programming failure is fatal without `-F`.** Startup used to
      only warn if `program_backends` failed (BAR error / card drop / window
      mismatch) — leaving the daemon alive with an out-of-sync device. Now fatal
      unless `--allow-fake` (dev/CI keeps the warning).
    - **Control-socket bind/listen failure is fatal.** It was a warning, leaving
      a daemon that looks healthy under systemd but is unmanageable (no
      config.load / flow control / stats / proxyd). Now a fatal startup failure.
      e2e regression: a control_socket path under a regular file (ENOTDIR) exits
      nonzero with a diagnostic.
    - **`ipc.h` auth comment corrected** — it claimed `0660 root:packetwyrm`
      while the daemon creates the socket `0666`; now describes the actual
      `system.secret` model + 0666 default.
    - **RTL standalone defaults aligned:** `pw_field_classifier` /
      `pw_slice_match` `HDR_BYTES` default 160 → 176 to match the production
      `pw_data_plane_axis` (the top always overrides; this only affects
      standalone instantiation / future reuse).
  - **Daemon failure-mode hardening (3rd full-codebase review) — HW-validated.**
    Four items where the daemon could come up "alive but dead" or diverge from
    the documented contract. Re-validated on 07:00.0 (restarted the daemon on the
    new binary, no false fatal on the real card + TAPs; cRPD dual-stack control
    plane reconverged — v4/v6 ping 0 % loss, OSPFv2/v3 Full, IS-IS L1+L2 Up, BGP
    v4+v6 Established):
    - **`config.load` rollback now restores the EXACT prior flow-enable state.**
      The quiesce step (stop running flows before staging the new config) wrote
      the disable into the daemon's authoritative staged rows, so a failed stage
      rolled back to *all-flows-disabled* despite the "previous config still
      running" message. `set_flow_enable` gained a `persist` flag; the quiesce
      writes the disable to the FPGA only (`persist=false`), leaving the staged
      program untouched so rollback re-programs the real prior state. Guarded by
      an `e2e_smoke` regression test: a fake-backend fault hook
      (`PW_FAKE_FAIL_FLAG` + a DP_RESET-armed commit) fails the reload's staging
      commit, and the test asserts the running flow stays `enabled` after the
      rollback (it reads back `enabled:false` if the quiesce regresses to
      mutating the staged rows — verified against the reintroduced bug).
    - **A real card that fails to open is now a startup failure (no `-F`).**
      `open_all_backends` returns a failure count; without `--allow-fake` the
      daemon exits instead of running with an unprogrammed data path (socket up,
      FPGA doing nothing). CI/e2e keep using `-F`. Matches `daemon.md`.
    - **A configured `logical_if` that can't get a working TAP is fatal (no
      `-F`).** `setup_taps` now propagates TAP open / MAC / MTU / up / bind
      failures (previously the ioctl returns were ignored) — a missing/down TAP
      blackholes the control plane. `-F` tolerates it for non-root dev/CI.
    - **`config.save` fsyncs the parent directory after the atomic rename**, so
      the new directory entry (for the file holding `system.secret`) is durable
      across a crash/power loss, not just the file contents.
  - **Operational / packaging hardening (2nd full-codebase review).** Five
    non-datapath items from a follow-up review:
    - **systemd unit no longer strips the capabilities the hardware backend
      needs.** `packetwyrmd.service` clamped `CapabilityBoundingSet=CAP_NET_ADMIN`
      while running as root — dropping `CAP_SYS_RAWIO`/`CAP_SYS_ADMIN` etc., so
      `systemctl start` could fail to mmap the BAR / prep PCI even though a manual
      `sudo packetwyrmd` worked. Removed the clamp (root keeps the full set) with
      a comment on why, and getting-started now tells operators to verify the
      service reached the card via `journalctl`.
    - **Prometheus exporter binds `127.0.0.1` by default.** `-p` now takes
      `[ADDR:]PORT` (default `127.0.0.1`); the unauthenticated `/metrics` endpoint
      is loopback-only unless the operator explicitly opts into `-p 0.0.0.0:9100`.
      The shipped unit's `-p 9100` is now loopback. (Was `INADDR_ANY` — LAN-public
      by default, inconsistent with how proxyd gates remote access.)
    - **Generator vs control-plane jumbo made explicit.** Documented that the
      traffic generator's `frame_len` cap (1518) is deliberate and separate from
      the MTU-9000 control-plane/slow-path jumbo — the RTL generator's length
      fields are 12-bit, so generator jumbo would need an RTL widen + rebuild
      (config.c + yaml-schema.md). Fixed the JSON schema `frame_len` minimum
      64 → 60 to match the parser's pre-FCS floor.
    - **Legacy CSR punt/inject windows in `csr.h` marked LEGACY (non-DMA
      bitstream only)** so they're not mistaken for a production fallback (the
      DMA bitstream uses `pw_dma_slowpath` exclusively).
    - **Removed stale "Unauthenticated for Phase 0" wording in `daemon.md`**
      (superseded by the `system.secret` access-control model).
  - **All SW binaries now embed the build-time git revision in their version
    string.** `pw_version_string()` — the single funnel for `pktwyrm version`,
    the daemon `version` RPC / `packetwyrm_build_info` metric, the proxyd
    `/proxyd/version` endpoint and the Web GUI versions panel — now returns
    e.g. `0.1.0 (5c5e9abb1f0a+dirty)`. The Makefile computes the short SHA (+
    `+dirty` when tracked files differ from HEAD, `unknown` outside a git tree)
    and injects it via `-DPW_GIT_REV` into `version.o`, which is rebuilt every
    `make` so the stamp stays current. Mirrors the FPGA bitstream's per-build
    `build_id`/`git_hash` so a running SW binary can be traced to its source.
  - **PCIe-DMA slow path (`pw_dma_slowpath`) integrated into the Phase 3 core
    — RTL + sim (host driver pending).** The CSR-window inject/punt slow path
    (512 B inject / 2048 B punt, ~200 ms MMIO-per-word) is replaced by a
    PCIe-DMA engine so control-plane routing (cRPD IS-IS, MTU-padded hellos,
    1500 B data, jumbo) works across the DUT. Approach **A2**: the Xilinx XDMA IP
    is reconfigured for **AXI-Stream** H2C/C2H (`xdma_axi_intf_mm=AXI_Stream`),
    keeping the AXI-Lite-master CSR **register map** unchanged (its offset within
    BAR0 moves to `0x10000` — BAR0 grows to 128 KB and the host adds that offset
    when `HAS_DMA`; see the design doc §5a-bis). `pw_dma_slowpath` bridges the
    256 b @ `axi_clk` XDMA streams to the 64 b @ `dp_clk` data-plane inject/punt
    AXIS (async CDC + width conversion via the taxi async-FIFO adapter, plus an
    8-byte in-band metadata header: inject carries egress port, punt carries
    `logical_if_id` + ingress). It is wired inside `pwfpga_top_phase3` (new
    `axi_clk`/`axi_rst`/H2C/C2H ports driven from `pcie_axi_lite_bridge`), driving
    the inject AXIS and sinking the punt AXIS; the CSR-window `pw_punt_rx_window`
    is removed and the `pw_inject_tx_window` decommissioned. `PW_PHASE3_CAPABILITIES`
    now advertises `CAP_HAS_DMA` in place of the retired `CAP_HAS_PUNT`
    (`0x0000_002D`). Verified in Verilator: the standalone `sim_dma` bridge tb and
    the integrated `sim_top` (ARP punt now observed on the C2H stream with the
    correct in-band `lif_id`/`ingress`) both pass; full `sim_all` (40 TBs) green.
    **Gated build passed** (build_id `0x6a47e2bc`, LUT 94.84 %, all clocks WNS>0),
    **flashed to 07:00.0 and HW-validated (2026-07-04):** the full cRPD 2-node
    control plane now works across the DUT over the DMA slow path — **dual-stack:
    IPv4 (ARP, ICMP ping 0 % loss ~2.2 ms, BGP, OSPFv2 Full, IS-IS L1+L2) AND IPv6
    (ND, ICMPv6 ping, BGP-over-IPv6 Established, OSPFv3 Full, IS-IS IPv6)**, with
    both routers learning each other's v4+v6 loopbacks via OSPF/OSPFv3 and IS-IS.
    IS-IS and >512 B frames, blocked on the old CSR window, now traverse. The
    IPv6 control plane is gated on `ipv6_nd: true` (punts ICMPv6 ND); the flow
    compiler then also emits the IPv6 punt variants of OSPFv3 / BGP-over-IPv6,
    sharing comparators with the IPv4 rules (11/12 field comparators). The P2 host
    DMA driver lives in `sw/libpacketwyrm` (`csr.h` XDMA reg map + 32-B SG
    descriptor; `vfio` `MAP_DMA`/`UNMAP` + `map_region` for BAR1; `backend_bar.c`
    DMA backend, capability-gated so `pw_host_plane` is unchanged). HW bring-up
    corrected the design's assumptions (all reflected in the code): the IP exposes
    **two 64 KB BARs** (BAR0=CSR@0 unchanged, BAR1=XDMA regs — not a 128 KB split);
    the single-descriptor completed-count **resets on RUN** (H2C inject waits for
    count != 0); the **C2H length is not in `desc.bytes`** (recovered from the
    frame's L2/L3 headers); **C2H uses a continuously-running circular descriptor
    ring** (per-frame stop/re-arm wedges the engine); the daemon punt-reap poll cap
    was cut 100 ms→1 ms; and cRPD binds the TAP as `interface net0` (not `net0.0`,
    + TUNSETCARRIER to mark the tun carrier up). See `docs/design/dma-slow-path.md`
    §5c and `configs/examples/lab-crpd-2node/`.
  - **Jumbo (MTU 9000) across the DUT — HW-validated (build_id 0x6a481d26).** Raised
    the data path's frame-size caps together — MAC BASE-R `cfg_*_max_pkt_len`
    1518→9600, MAC↔dp CDC FIFO 2048→16384 B, data-plane forward/punt SAF
    `SAF_DEPTH_BEATS` 512→2048, `pw_dma_slowpath` async-FIFO 2048→16384 B (the taxi
    DEPTH is in bytes), and host `PW_HOST_FRAME_MAX` 2048→9600. Validated: v4 pings
    to 8900 B + a v6 8000 B ping at 0 % loss with the full dual-stack control plane
    (OSPFv2/v3 Full, IS-IS L1+L2 Up, BGP v4+v6 Established) still up. Gated build
    WNS +0.084 all clocks, LUT 94.79 %, BRAM 53 %.
  - **Punt in-band header carries the frame length (`byte_len`) — HW-validated
    (build_id 0x6a48854f).** `pw_dma_slowpath` now runs a small dp-domain
    store-and-forward on the punt path that counts each frame's bytes and writes
    them into the in-band header (bytes 5-6, LE) ahead of the frame; the host
    reads the length directly instead of recovering it from the frame's L2/L3
    headers (that parse is kept only as a `byte_len==0` fallback). This generalises
    punt to arbitrary ethertypes/VLAN/QinQ. Validated on 07:00.0: the debug log
    read `len=8062` straight from the header on a jumbo punt; full dual-stack
    control plane + v4/v6 jumbo pings (2000–8900 B) all 0 % loss. Gated build WNS
    +0.165 all clocks, LUT 94.81 %, BRAM 54.31 %.
  - **DMA slow-path robustness follow-up (full-codebase review) — HW-validated.**
    Five hardening items from a codebase review, re-validated on 07:00.0 (build
    0x6a48854f unchanged; cRPD dual-stack control plane reconverged after a daemon
    restart on the new binary: v4/v6 ping 0 % loss, OSPFv2/v3 Full, IS-IS L1+L2
    Up, BGP v4+v6 Established; 317 punt frames, `overrun=0`, no errors):
    - **VFIO DMA IOVA no longer aliases the userspace VA.** `pw_vfio_map_dma` now
      bump-allocates device IOVAs from a dedicated base (4 GiB) instead of reusing
      `(uintptr_t)vaddr` — a process VA is not guaranteed to be a valid IOVA within
      the IOMMU aperture. Decouples IOVA from VA for portability.
    - **H2C completion wait is bounded by a monotonic deadline + reads channel
      status.** The inject completion poll was a fixed 1M-iteration spin that never
      looked at `CH_STATUS`; it now aborts on a channel error bit
      (`PWFPGA_XDMA_STAT_ERR`) or a 200 ms deadline, logs the status, and clears
      the latched error via `STATUS_RC` so a wedged engine can't spin forever or
      hide its cause.
    - **C2H ring overrun is now observable.** When the host falls behind the 16-desc
      ring and drops punt frames, `dma_state.c2h_overrun` counts them and a
      rate-limited warning (once per 16 dropped) hits the daemon log — previously
      the loss was silent (it surfaces as BGP/OSPF/ND flaps).
    - **RTL punt SAF guards against an oversize frame** (`pw_dma_slowpath.sv`): a
      frame exceeding `PSAF_BEATS` (10240 B) now enters a `PS_DROP` state that
      swallows it to `tlast` without emitting, so `psaf_wr` can never index past
      the BRAM. Unreachable at the current 9599 B MAC ceiling — defensive for a
      future cap change. Verified by a new `sim_dma` oversize-drop/no-desync case.
      (RTL source + sim only; ships on the next bitstream.)
    - **Docs: the pre-silicon §5a-bis BAR0+0x10000 premise is marked SUPERSEDED**
      (real silicon uses two 64 KB BARs, CSR at BAR0:0 — see §5c point 1).
  - **Punt DMA buffer raised to cover the full configured frame ceiling
    (`PW_DMA_FRAME_CAP` 9216 → 16384).** Review follow-up: the MAC accepts up to
    9599 B (`cfg_*_max_pkt_len`) and `pw_dma_slowpath`'s punt SAF buffers up to
    PSAF_BEATS×8 = 10240 B, but the host C2H descriptor buffers were only 9216 B,
    so a punt of `{9209..9599 B frame + 8 B header}` could truncate on C2H. The
    buffer now matches the RTL async-FIFO DEPTH (16384) and clears both ceilings
    (host-side only — no reflash; the MTU-9000 traffic HW-validated earlier is
    ≤~9018 B, so this hardens the configured-max edge). Also fixed the stale
    `PW_HOST_FRAME_MAX` and `pw_dma_slowpath.sv` header comments (the punt header
    carries `byte_len` too), and added a `sim_dma` case that punts a 100-B frame
    (partial `tkeep` + C2H backpressure) verifying `byte_len` and payload integrity.
  - **Unmatched frames split out of `drops`; LED no longer red on no-match
    (RTL + SW).** A classifier **no-match** is no longer counted as a drop or
    treated as an error. Per-port `drops` (`rx_bad_frame`) now counts **real
    drops only** — a store-and-forward forward-buffer overflow. Frames that were
    received (and counted in `rx_frames`) but matched no flow/forward/punt rule
    are counted separately in the new `rx_unmatched` counter — informational,
    e.g. the host TAP's own IPv6 ND/MLD looped back to the port. The front-panel
    error LED (`err_sticky`) now latches on per-flow `lost` + `rx_fcs_error` +
    real SAF-overflow `drops` **only**; `rx_unmatched` is deliberately excluded,
    so benign stray traffic no longer turns the LED red. A per-port capture of
    the most recent unmatched frame's identity (`last_unmatched_ctx` =
    `{l3_proto, ethertype, is_arp, action, hit, is_ipv6, is_ipv4, is_test}` +
    `last_unmatched_flowid`) lets a rare miss be attributed at a glance: a real
    test-frame miss carries `is_test` + a known `flow_id`; stray/garbage traffic
    does not. Surfaced through `ports.stats` (`drops`/`rx_unmatched`/
    `last_unmatched`) and the GUI health panel (real drops as an error cause,
    unmatched as an informational note + a new `unmatched` port-table column).
    Per-port snapshot block: `rx_unmatched`@byte76, `last_unmatched_ctx`@80,
    `last_unmatched_flowid`@84; `struct pw_port_stats` updated to match (the
    interim `drop_nomatch`/`drop_saf`/`last_drop` fields are removed —
    unreleased). RTL change — timing gated. (Supersedes the interim per-port
    DROP-classification entry; the diagnostic pinned the phantom-drop cause to
    host-TAP ICMPv6, which this reclassifies as `rx_unmatched`, not a drop.)
  - **Host-plane TAP status + statistics (`tap.stats` RPC + `pktwyrm tap` + GUI
    panel).** SW-only. Reports, per logical-interface TAP netdev, its kernel name
    (e.g. `tap-pw-p0-v100`), `logical_if_id`, MAC/VLAN/MTU, admin/oper up state,
    the host-assigned IP addresses (incl. the auto link-local IPv6 whose ND/MLD
    shows up on the loopback as `rx_unmatched`), the Linux netdev rx/tx/dropped
    counters, and the PacketWyrm host-plane bridge counters (`to_tap`/`from_tap`
    ok+dropped). New `pw_tap_query()` in libpacketwyrm (getifaddrs-based) feeds
    the daemon's `build_tap_stats`; surfaced in the GUI **Host-plane TAPs**
    dashboard panel and `pktwyrm tap [--json]`. Makes the punt/inject TAPs and
    their traffic visible so unmatched-frame sources are attributable.
  - **frame_len minimum lowered 64 → 60 (the true 64-byte wire frame).**
    `frame_len` is the pre-FCS L2 length, so the smallest legal Ethernet frame
    (64 B on the wire *including* FCS) is 60 B pre-FCS — the old floor of 64
    forced a 68 B wire frame. With `frame_len: 60` + a raw `frame_template`, the
    generator now emits a true 64-byte wire frame: HW-measured **14.88 Mpps
    (10.0 Gbps, loss=0)** on build_id 0x6a46138b — the canonical 64 B line-rate
    point (`frame_len: 64` remains valid and is also full line rate at 68 B/frame
    = 14.20 Mpps). Validator range is now [60,1518]. SW-only, no bitstream change.
  - **Generator frame templates — raw payload + true 64-byte frames (RTL).**
    A new per-flow `frame_template` (`traffic.frame_template: test|raw|ip|eth`)
    selects which layers `pw_flow_gen_multi` emits. `test` (default) is the
    full Eth/IP/L4 + 32-byte PacketWyrm test header, unchanged. The three raw
    templates carry no test header, dropping the 32-byte payload floor so a
    **true 64-byte minimum frame** is emitted instead of clamping to 74 B:
    `raw` (full Eth/IP/L4 headers, raw zero payload), `ip` (Eth[+VLAN]+IP+
    payload), `eth` (Eth[+VLAN]+ethertype+payload, `l2.ethertype` override).
    Raw templates require `classify: header` and forbid measurements/encap
    (validator-enforced): the RX checker keys on the test-header magic, so raw
    frames count `rx_frames` only (no seq/loss/latency, no LED trip; loss is the
    tx-vs-rx count) and the compiler zeroes the absent-layer hash-key words so
    header classification matches the zero-payload frame. Raw frames are marked
    non-stampable (`m_tstampable=0` → `tuser=0`) so egress `pw_ts_insert` leaves
    them untouched. Wire row extended to 244 B (`frame_template` @240,
    `l2_ethertype` @242), drift-locked by the C `_Static_assert`s + the
    gen_bar_vectors/tb_wire_vectors golden image.
  - **Small-frame line rate — generator pipeline priming (RTL).** A single
    small-frame flow was capped below line rate (HW: 64 B `burst_size: 1` →
    12.0 Mpps) by a per-frame pipeline bubble: with a 1-frame bucket, each
    frame's token deduction empties the bucket, drops the slot's eligibility, and
    drains the generator's ~5-stage pick/precompute pipeline (~5 idle cycles/
    frame). Fix: keep the currently-emitting slot speculatively "eligible" through
    its own emit (`eligible[s] |= active && s==sel`) so the round-robin pick and
    precompute pipeline stay PRIMED — the next frame launches ~1 cycle after the
    current ends (bubble 1, not ~5). Rate limiting + strict cap=1 pacing are
    preserved by moving the real token check to the launch decision (gated on a
    registered per-slot ready flag); fairness holds (the active slot is the
    round-robin last choice). A single 64 B flow now reaches **14.2 Mpps / line
    rate at `burst_size: 1`** (HW-validated on build_id 0x6a46138b, loss=0), with
    no loss of single-frame pacing. Post-route WNS +0.148 ns (all clocks; the
    launch-decision restructure to a registered ready flag also lifted the
    critical path above the prior +0.068 baseline). Multi-flow already saturated.
  - **LED-state readback, on-chip SYSMON telemetry, per-port pps/bps (RTL).**
    The front-panel LED's `err_sticky` is now software-readable: GLOBAL_STATUS
    exposes it at bit 3 (+ activity at bit 5), wired from the data plane (same
    clock domain, no CDC). New `pw_sysmon` DRP reader + a SYSMONE4 instance in
    the board top expose die temperature + VCCINT/VCCAUX at REG_SYSMON_TEMP/
    SUPPLY. The daemon's `cards` RPC now reports `err_sticky`/`activity` and
    `temp_c`/`vccint_v`/`vccaux_v`; a new `ports.stats` RPC returns per-port MAC
    counters (frames/bytes/FCS/link) and `flow.stats`/`ports.stats` include the
    FPGA timestamp so clients derive exact pps/bps from counter deltas. The GUI
    Health panel now shows the *real* LED state (not just an inference),
    Versions shows temperature/voltages, the Ports table shows per-port pps/bps,
    and flow stats add rx bps. (Requires a bitstream rebuild; older images omit
    SYSMON/err_sticky and the GUI falls back to inferred health.) Also:
    Control-tab Start/Stop-all now refreshes the per-flow state.
  - **Web GUI review round 3 (correctness).** `set_flow_enable` now writes a `set_flow_enable` now writes a
    copy to the backend and only updates the staged row (reported as `enabled`)
    on write+commit success, so flows/flow.stats can't show a state the FPGA
    doesn't have. `config.save` reports `restart_required` for *any* change (it
    writes the file but never live-applies, so a secret/system change needs a
    restart too — not just topology) plus a separate `topology_change` bool;
    the GUI message reflects both. `config.get_test` preserves a flow's rate
    mode (`rate_mode`+`rate`, bps or pps) so Load current → Apply round-trips a
    rate_pps flow instead of emitting invalid `rate_bps: 0`. GUI: latency cells
    show "—" for flows without valid latency (no NaN), and the histogram bucket
    bounds use `2**i` (no 32-bit `<<` overflow past bucket 31).
  - **Web GUI dashboard depth + hardening (review round).** Dashboard gained a
    Versions panel (daemon / proxyd / per-card FPGA device/version/build/git via
    new `cards` fields + `GET /proxyd/version`), a derived Health/LED panel per
    card (mirrors the front-panel R/G LED from data-plane stats, lists the
    causing counters), Aggregate counters (total / per rx-card / per rx-port
    with frames/s rates), per-flow Started/Stopped state + a state-aware toggle
    (new `enabled` field on `flows` / `flow.stats`), tx/rx frame rates, red
    highlighting of non-zero lost/dup/reorder, SFP values capped to 3 decimals,
    and a latency histogram labeled in ns/µs/ms. Security/robustness fixes:
    `config.get_raw` now redacts the secret **structurally** (only the
    `secret:` line, no blanket value replacement — no infinite loop, no
    collateral clobbering); `config.save` recognizes the redaction sentinel and
    **preserves the running secret** (saving the redacted view can't lock you
    out) and preserves the file's mode/owner; `packetwyrm-proxyd` sets
    send/recv timeouts on client sockets so a slow client can't tie up the
    thread pool.
  - **Web GUI + remote access via `packetwyrm-proxyd`.** A new separate gateway
    process terminates HTTPS, serves an embedded single-page Web GUI (`GET /`),
    and relays `POST /api/rpc` verbatim onto the daemon's Unix control socket.
    It is a stateless relay: it shares no state with `packetwyrmd` and holds no
    secret (the client's `secret` is forwarded and the daemon stays the sole
    auth authority), so TLS/HTTP work never blocks the daemon's control/servo
    loop. TLS uses an auto-generated in-memory self-signed cert by default
    (fingerprint printed) or `--tls-cert/--tls-key`; `--no-tls` for
    localhost/tunnel. It refuses a non-loopback bind when the daemon has no
    secret (unless `--insecure-no-auth`), and ships an unprivileged systemd
    unit. The GUI covers a live dashboard (cards/ports/SFP/flow stats +
    latency histogram), point-and-click flow/forward editors (full flow schema
    incl. collapsible match / modifiers / encap sections) that emit config YAML
    and apply it via `config.load`, test/flow control, and an environment
    editor. New daemon RPCs `config.get_raw` (env file text, secret redacted),
    `config.get_test` (the active flows/forwards as both YAML text and
    structured form-model JSON, so the GUI's "Load current" populates both the
    point-and-click form — match/modifiers/encap included — and the raw editor,
    round-tripping existing flows losslessly), and `config.save`
    (validate + atomic write of the env file, reports `restart_required`).
    `pktwyrm --host HOST[:PORT]` sends every RPC through
    the gateway over HTTPS (default port 8443); `pktwyrm rpc` now injects the
    secret too. See `docs/design/web-gui.md`.
  - **Environment/test config split + control-socket secret.** The config now
    divides into an environment part (rarely changed: `system`, `cards`,
    `logical_interfaces`, and a new `secret`) and a test part (changed often:
    `flows`, `forwards`). `packetwyrmd -e ENV [-t TEST]` (env default
    `/etc/packetwyrm/packetwyrm.yaml`; `-c` is an alias); `pktwyrm load` ships
    flows/forwards only and the daemon merges them onto its running environment
    (`config.load`). A combined single file still works. When `system.secret` is
    set, the daemon requires a matching `secret` on every control-socket request
    (constant-time compare, else `unauthorized`); `pktwyrm` supplies it from
    `--secret` / `$PACKETWYRM_SECRET` / the env config (`--env`), so **read
    permission on the env config file is the access gate**. No secret = auth off.
    New lib: `pw_config_parse_*_ex` (PW_CFG_TEST_ONLY), `pw_config_clone_env`.
    Build fix: `-MMD` header-dependency tracking (a header change now rebuilds
    dependent objects instead of leaving a stale, mismatched-layout `.o`).
  - **Front-panel R/G health LED.** The previously-unconnected bicolor status LED
    (led_r=A13 / led_g=A12, active-low) now shows data-plane health: **red** =
    sticky error since the last `stats.clear` (a checker sequence-loss event, or
    a nonzero RX FCS/runt or port-drop count); **green blinking** = up + clean +
    traffic flowing; **green solid** = up + clean + idle; **off** = PCIe down /
    not configured (red overrides green). SFP link state is intentionally NOT
    shown here (the per-cage SFP LEDs already do that). The data plane exports two
    aggregate levels (err_sticky, activity — a retriggerable one-shot); the board
    top 2FF-synchronises them into the 100 MHz LED domain and drives a ~3 Hz
    blink. New checker `lost_event_o` pulse feeds the sticky-error latch.
  - **SFP+ module identifier + DOM read (`pw_sfp`).** New per-SFP I2C management
    bus (CSR `REG_SFP_I2C` 0x0150, open-drain SCL/SDA per cage via board-top
    IOBUFs on C13/C14 and D10/D11) lets software bit-bang the module EEPROM. New
    `libpacketwyrm/sfp.{c,h}` reads + decodes SFF-8024/8472: identifier, vendor,
    part, revision, serial, date code, nominal bit rate (0xA0 @ i2c 0x50), and —
    for DDM-capable optical modules — live DOM (temperature, Vcc, TX bias, TX/RX
    optical power, 0xA2 @ 0x51). New `pw_sfp <bdf> [port|both] [raw]` tool prints
    it (with dBm). A passive DAC reports the identifier but no DOM. Pad inputs are
    2FF-synchronised + false-pathed; the I2C lines idle high via PULLUP.
    `pw_sfp_write()` + `pw_sfp <bdf> <port> write <0x50|0x51> <offset> <hexbytes>
    [commit]` also write the module EEPROM (single-byte writes with ACK-poll for
    the write cycle; no RTL change -- same bit-bang CSR). Guarded: a dry run
    (current vs new) unless `commit` is given, then it writes + reads back to
    verify. WARNING: writing the base ID page can re-code / brick a module;
    intended for deliberate lab use on modules you own. `pw_sfp <bdf> <port>
    unlock <password_hex>` enters the SFF-8472 write password (A2 0x7B) to unlock
    protected-region writes (`pw_sfp_unlock` / `pw_sfp_try_write_password` in the
    lib), and `pw_sfp <bdf> <port> findpw [start] [end] [stride]` searches for a
    working write password (range-bounded + resumable, with rate/ETA -- a full
    2^32 sweep is impractical over bit-bang I2C, ~weeks). HW-validated: password
    0x0 unlocks the dev-card Finisar modules; a base-ID write then verifies and
    is restored.
  - **`sfp.info` RPC + `pktwyrm sfp`.** The daemon exposes SFP identifier + DOM
    over JSON-RPC (`sfp.info`, optional `card`/`port` filter), reading each open
    card's module via `pw_sfp_probe`. `pktwyrm sfp [--card N] [--port P] [--json]`
    pretty-prints it (vendor/part/serial/bit-rate + DOM temp/Vcc/bias/TX+RX in
    dBm). HW-validated on the dev card (both Finisar 10G-LR read via the daemon).

### Fixed
  - **Deep-encap UDF classifier matching.** A UDF slice comparator reads inner
    byte `base_i(eff) + offset` out of the captured window, but the window was
    truncated to the low `SLICE_WIN`(48) bytes, so for `eff + offset ≥ 48` (deep
    encap, e.g. v6-in-v6) it read 0 and could never match the inner frame (only
    shallow UDFs like the IS-IS punt worked). The classifier now gets the full
    `HDR_BYTES`(176) window, so a UDF reaches the inner frame at any single-encap
    depth. Widens only the two `pw_slice_match` byte-muxes (classifier latency-2
    path); the dp_clk-critical parser is untouched. (No config emits a deep-encap
    UDF today, so this was a latent limitation, but it restores the documented
    "offset relative to the inner frame, encap-agnostic" UDF contract.)

### Added
  - **Per-flow cross-card latency correction (Stage 2).** The single global
    `lat_correction` CSR (0x0144/0x0148) is replaced by a per-flow window
    (`0x0180 + slot*8`, atomic LO-stage/HI-commit) feeding a data-plane
    `lat_corr_table[NUM_FLOWS]`. The RX checker now corrects each flow's slot
    independently (`lat = (rx_wire_ts + corr[slot]) - tx_ts`), so a single RX
    card may mix same-card flows (corr 0) with cross-card flows from different TX
    cards (each its own offset) — the Stage-1 global-per-card validator
    constraint is removed. To hold dp_clk timing the per-flow table mux is
    registered one extra cycle (+5) before the checker, off the latency-calc cone
    (the SAF/drop/punt path stays at +4). Daemon servo + prime write per-slot
    corrections (`pw_gpio_sync_write_correction(be, slot, corr)`).
  - **Cross-card latency HW correction (`lat_correction` CSR).** The RX checker
    now takes a signed 64-bit correction (CSR `0x0144/0x0148`, broadcast to every
    port's checker) and computes `lat = (rx_wire_ts + lat_correction) − tx_ts`, so
    cross-card latency is corrected **per sample in hardware** — min/max/sum and
    the histogram all accumulate the true one-way value. This supersedes the
    earlier SW read-time single-offset correction, which left max/avg smeared by
    the ~1.6 ppm clock skew over a long accumulation (and forced avg-omit +
    histogram-unsupported for cross-card). Same-card flows use `lat_correction = 0`
    → bit-identical to before. The free-running counter is still never disciplined
    (Gray-CDC safe); only this computation is. Daemon servo + `flow.stats` cleanup
    land alongside. Robustness: the CSR commits atomically (LO stages a shadow,
    HI commits the 64-bit pair in one cycle -- no torn transient); the daemon
    primes the correction + `stats.clear`s on (re)program so the startup window
    can't pollute min/max/hist; the validator enforces the stage-1
    global-per-card limit (a cross-card RX card may not also receive a same-card
    flow, nor cross-card traffic from >1 TX card); the servo reads an
    EDGE-COHERENT offset (`pw_gpio_sync_offset_coherent` brackets the two-card
    read with seq re-reads, rejecting a sample where a sync edge landed mid-read
    -- which would otherwise write a ~1-period-wrong offset), skipping the write
    on an incoherent read; `flows`/`flow.stats` report `latency_method` with
    `latency_valid: true` for cross-card; and `pw_stats_aggregate` now surfaces
    cross-card latency too (`latency_valid: true` + a `cross_card` flag) instead
    of zeroing it. The servo period is tunable via `packetwyrmd -S SERVO_MS`
    (default 10 ms): the residual from the ~1.6 ppm clock skew between updates is
    `skew x period` (~16 ns at 10 ms, ~1.6 ns at 1 ms), so a tighter period
    sharpens cross-card max/jitter with no bitstream change (the J5 edge refreshes
    every ~210 us, the floor below which it's moot). `flow.stats` `offset_ticks`
    surfaces the live (edge-coherent) offset the servo is applying.
  - **Cross-card one-way latency in packetwyrmd/pktwyrm.** A flow whose TX and RX
    ports are on different cards now reports latency (previously rejected as
    "cross-card flow does not support latency/jitter"). The daemon brings up the
    J5 GPIO time-sync on load (one master, others slave); new `pktwyrm latency`
    prints per-flow one-way latency (same-card exact / cross-card corrected).
    HW-validated: cross-card min ~30 ticks (~192 ns), matching the single-card
    wire-to-wire figure. Library helpers `pw_gpio_sync_*`
    (libpacketwyrm/gpio_sync). Needs the J5 headers wired. **Correction now
    happens per sample in hardware** (see the `lat_correction` entry above) --
    this superseded the initial read-time offset scheme, which left avg/max
    smeared and the histogram cross-card-unsupported.
  - **RX ingress wire-stamp.** Received frames are now timestamped in the MAC RX
    clock domain at SOF (a second `pw_ts_gray_cdc` per port, dp_clk→`sfp_rx_clk`),
    carried through the RX async FIFO as widened `tuser` (`pw_mac_axis_cdc`
    `RX_USER_W` 1→65 = `{rx_wire_ts, fcs_err}`) and through `pw_parser_axis`
    aligned with the key. The RX checker now computes latency as
    `rx_wire_ts − tx_wire_ts` (both SOF-referenced) = true **wire-to-wire**, free
    of the store-and-forward FIFO + parser + classifier pipeline delay and
    frame-size independent. The same stamp is the servo-facing RX event time in
    the punt metadata (previously a post-FIFO dp_clk sample). Single-card payoff
    is modest (loopback jitter already ~0); the real value is cross-card one-way
    latency once two cards share a time base via the J5 GPIO sync.
  - **Stateless TCP segment generation.** A flow selects `tcp:` instead of
    `udp:` (mutually exclusive) to emit fixed-form TCP segments — a 20-byte TCP
    header (data-offset 5, configurable `flags` byte defaulting to 0x02 SYN,
    window 0xFFFF, seq = test sequence, ack/urgent 0) with a correct L4 checksum
    for both IPv4 and IPv6, the 32-byte test header carried in the TCP payload so
    loss/latency/sequence measurement is identical to UDP. This is a generator,
    NOT a connection engine (no handshake / ACK tracking / retransmit / window).
    The per-proto minimum legal frame (IPv4/TCP ≥ 86 B, IPv6/TCP ≥ 106 B) clamps
    a smaller `frame_len` up. RX test-header classification covers TCP up to the
    parser capture depth (the deepest v6-encap TCP test header is not RX-classified
    at the current 160-byte depth; TX generation is unaffected).
  - **IPv6 source/destination classifier matching.** Forward rules accept
    `ipv6_dst` / `ipv6_src` (address or `addr/prefix`) compiled to masked field
    comparators (all four IPv6-src words are now selectable; `/64` costs 2 of the
    12 per-card comparators + 1 `is_ipv6` guard, `/128` costs 4 + 1; the compiler
    dedups and returns `PW_E_NO_RESOURCES` with a diagnostic when over-subscribed).
    `classify: header` flows accept `match: { ipv6_dst_prefix / ipv6_src_prefix }`
    to narrow the hash key (the key mask is per-card global).
  - **Full 128-bit IPv6 address modifiers.** `src_ipv6` / `dst_ipv6` modifiers
    accept a full IPv6-literal mask (rotate the whole 128-bit address); a bare
    ≤32-bit hex still rotates the low 32 bits (back-compatible). Each 32-bit lane
    is field+lane-salted so a full-mask rotation emits four distinct words and
    src ≠ dst (de-duplicated deterministic streams, ~2³² period). Increment mode
    and all existing v4/port/MAC/VLAN modifiers are byte-identical to before.
  - (Stateless line-rate TCP segment generation is implemented on the
    `phase3-tcp-gen` branch but deferred from this build: A+B+C together exceed
    the xcku3p routing budget (~93% LUT), so TCP ships after a dedicated
    LUT-reduction pass.)

### Fixed
  - **`DP_RESET` now also resets the MAC-TX CDC, to recover a presumed TX-FIFO
    wedge in-system.** The data-plane soft reset only quiesced dp_clk-domain
    state (gen / SAF / arbiters); the per-port MAC-TX CDC FIFO + `pw_ts_insert`
    live in the MAC tx_clk domain and were outside it. An observed egress hang
    (every flow `tx=0`, inject `INJECT_STATUS_BUSY` stuck, link still up) cleared
    only on an ICAP reboot / power cycle — consistent with a stuck TX-FIFO state.
    The `DP_RESET` pulse is now stretched in dp_clk and CDC'd into each MAC
    tx_clk to flush the TX FIFO (both sides) and reset `pw_ts_insert`. This
    re-initialises the TX-CDC state while the TX clock is running; it does not
    cover the MAC/PCS/GT, the RX CDC, or a stopped TX clock (still a reboot).
  - **Sub-minimum frame lengths no longer stall a flow.** The generator clamps a
    too-short frame up to the minimum legal size (incl. VLAN/encap/IP family);
    the SW now computes that same minimum and applies it to the token-bucket cap
    **and** the rate_pps byte basis, so a flow configured below the minimum (e.g.
    64 B) transmits at the right rate instead of starving (cap < cost).
  - **Reloads no longer leave stale classifier / flow / hash / map entries.**
    `pw_program_card_tables` now writes every table to its full capacity on each
    load: configured entries enabled, all remaining slots invalidated (flow rows
    zeroed, rules `enable=0`, hash buckets + flow-id-map entries `valid=0`).
    Previously a reload that *shrank* the config left the deleted flows / punt /
    forward / TEST_RX entries live, since the RTL commit only copies
    shadow→live without touching un-written slots. HW-validated on the loopback
    (4-flow multiflow, lost_est=0, correct per-slot classification).
  - **Slow-path inject window bounds-checks its inputs** (`pw_inject_tx_window`):
    `byte_len` is clamped to the 512 B buffer and out-of-range DATA word writes
    are dropped, so a malformed host inject can't alias onto a valid beat or emit
    a frame longer than the buffer. (RTL; ships in the next bitstream.)
  - **TX-arbiter source-select width** (`pw_data_plane_axis` `SELW`) widened to
    `$clog2(PW_PORTS + 2)` to cover the host-inject source index (`PW_PORTS+1`);
    the old `+1` was correct only by luck at `PW_PORTS=2`. (RTL; future-proofs
    `PW_PORTS≥3`.)
  - **config.load now rolls back on a staging failure** instead of swapping the
    daemon's view to a config the FPGA may not actually hold. If programming a
    card hard-fails (BAR error / card drop), the daemon re-programs the previous
    config, keeps it running, and rejects the load with an error — matching the
    documented behavior (`docs/design/daemon.md`). A half-applied config (daemon
    view != FPGA) was the worst failure mode for a tester.

### Changed
  - **dp_clk timing + LUT optimization (WNS -0.001 → +0.132 ns; LUT 89.2% →
    87.9%).** Two targeted changes recovered the razor-thin timing the
    variable-frame-length work left:
    * `pw_hash_classifier` pipelined 2→3 cycles — a masked-key register splits
      the dp_clk-critical `parser-key → assemble → mask → XOR-fold → multiply →
      BRAM-address` path (the actual WNS path). The data plane delays the field
      classifier + flow-id map results and the decision/`rx_kv_d` chain by one
      cycle so all three classification paths stay aligned at the precedence mux.
    * `pw_spi_flash` TX/RX buffers moved from two 512-byte register arrays
      (~10K LUT of byte-indexed muxes) to 32-bit-word block RAM; MOSI is a direct
      bit-select of the current word (the 1-cycle BRAM latency is absorbed by the
      SCK divider) and RX accumulates words. The CSR read is now a 1-cycle
      pending read (`spi_pend`, like the histogram/punt windows).
    HW-validated on the xcku3p loopback: map + hash-hit (24-flow header-classify)
    loopbacks loss=0, SPI JEDEC-ID read + 512 B live write/verify OK, link stable
    (blk_lock_loss=0). All Verilator tbs green.

### Added
  - **TCP SYN generator (`pw_tcp_syn`) over the slow-path inject.** Reuses the
    existing `slow_path_tx` arbitrary-frame path: the host composes a complete
    Ethernet/IPv4/TCP-SYN frame with the IPv4 + TCP checksums computed in
    software and the FPGA emits it verbatim — no RTL/bitstream change. Per-packet
    randomized src ip / src port / sequence (SYN-flood realism). HW-validated:
    frames egress and arrive on the loopback (fcs=0, correct size); the SW IPv4
    and TCP checksums fold to 0xFFFF (a DUT will accept them). This is the slow
    path (one frame per CSR sequence, tens of k pps — fine for protocol/
    functional SYN testing and low-rate floods); a *line-rate* TCP generator
    would need the streaming generator (`pw_flow_gen_multi`) to emit a TCP header
    + checksum, a separate RTL change.

### Fixed
  - **Punt rules narrowed; fake backend no longer a silent default.** BGP punt
    now matches **TCP port 179 only** (one rule per direction — listener dst:179,
    initiator src:179) instead of all TCP, so generated TCP test traffic (e.g. a
    SYN flood on other ports) is not swallowed by the slow path. IS-IS punt now
    matches the 802.3/LLC DSAP/SSAP (0xFEFE) via a UDF instead of a catch-all
    that punted **every** frame on the ingress (fails safe: under-matches rather
    than over-matches if the parser's L3 base differs for length-encoded frames).
    Pure compiler change (existing bitstream's L4-port comparators + UDFs);
    HW-confirmed it programs cleanly with the data plane at loss=0. The daemon
    no longer falls back to the no-op **fake backend by default** — a BAR-open
    failure is now an error unless `--allow-fake`/`-F` is passed (dev/CI), so a
    real deployment can't look healthy while silently dropping all CSR writes.
  - **Code-review hardening (config/validation/daemon).** `rate_pps` is now
    realized (compiler computes pps × frame bytes → token rate; a pps-only flow
    transmitted 0 frames before — HW-validated tx>0, loss=0). The config parser
    now validates traffic: exactly one of `rate_bps`/`rate_pps`, frame-length
    range [64,1518], `frame_len_min ≤ frame_len_max`, `frame_len_step ≥ 1`, and
    `frame_len` vs the `frame_len_min/max/step` triple are mutually exclusive
    (schema gained the matching `oneOf`; max tightened 9216→1518 to the FIFO/RTL
    limit). `program_backends` returns the worst hard status (card drop / BAR
    error), and `config.load` reports it (`ok=false` + `program_error`) instead
    of always succeeding. RPC `config.load` response key fixed
    `n_classifier_rules`→`n_classifier_rows` (matches the CLI + docs; the CLI
    printed 0 rows). `pw_rfc2544` now aborts on any CSR op failure (naming the
    failing access) and validates `trial_ms`.

### Added
  - **Variable frame length in the generator + RFC 2544 driver** — the test
    generator (`pw_flow_gen_multi`) now honors `frame_len_min/max/step`: each
    slot emits a total L2 frame length that is fixed (`min==max`, RFC 2544) or
    sweeps `min→max` by `step` (IMIX). Previously these fields were plumbed
    through the config/window but ignored — every flow emitted a fixed 74 B
    frame regardless of `frame_len`. The L4 payload pad is generated on the fly
    (the 176 B header buffer is unchanged; the FSM streams zero pad out to the
    frame length), and the IPv4/IPv6/UDP length fields + length-dependent
    checksum terms track the per-frame size. New `pw_rfc2544` tool automates the
    RFC 2544 methodology (throughput binary-search to zero sequence loss,
    latency at throughput, loss@line-rate) across the standard frame sizes on
    the loopback/DUT. Also bumped the MAC↔dp_clk frame FIFO (`pw_mac_axis_cdc`
    DEPTH 1024→2048 B): the taxi FRAME_FIFO drops oversize frames, so the 1 KB
    buffer silently capped frame size at ~1 KB — invisible while the generator
    only ever emitted 74 B. Validated: `tb_flow_gen_multi` sweeps {128,192,256}
    with matching IPv4 total_len + valid header checksum; full Verilator suite
    green; on HW the loopback shows real per-size results — latency scaling
    493/698/1107 ns for 128/256/512 B at ~line rate, loss=0 (1280/1518 B need
    the 2048 B FIFO). (64 B is below the 74 B test-frame floor — eth+IPv4+UDP+
    32 B test header — so it reports n/a.)
  - **Punt RX wire-timestamp (servo-facing PTP hook)** — punted frames now carry
    a 64-bit RX timestamp: the free-running counter latched at the frame's SOF in
    the data plane, threaded through the SAF in the punt metadata and exposed at
    `PWFPGA_REG_PUNT_RX_TS_LOW`/`_HIGH` (0x1010/0x1014; `PWFPGA_PUNT_DATA` moved
    to 0x1020). `slow_path_rx()` gained an `out_rx_ts` argument (read before the
    POP releases the slot). This is the RX-event capture a software PTP servo
    needs (e.g. Sync arrival time); the TX (inject) egress timestamp + the full
    two-clock servo loop follow (the latter gated on a second card). Validated:
    `tb_punt_window` RX_TS readback + `pw_phase3_punt` reports a monotonic
    `rx_ts` per punted frame.
  - **Inject TX wire-timestamp (servo-facing PTP TX hook)** — the inject window
    (`pw_inject_tx_window`) latches the free-running counter at the injected
    frame's first egress beat and exposes it at `PWFPGA_REG_INJECT_TX_TS_LOW`/
    `_HIGH` (0x0D08/0x0D0C). With the punt RX timestamp this gives a servo both
    event times (e.g. Delay_Req departure). Validated single-card: `pw_phase3_
    inject` injects a frame, reads its `tx_ts`, loops it back, and confirms the
    punt `rx_ts > tx_ts` (the loopback latency). Completes #60's TX/RX wire-
    timestamp exposure; the full two-clock servo loop remains gated on a 2nd card.
  - **Hash exact classifier — high-count payload-agnostic flows, wide masked
    key** (`pw_hash_classifier`; CSR window `PWFPGA_WIN_FC_HASH` @ 0x3000, mask
    window `PWFPGA_WIN_HASH_MASK` @ 0x2F00, seed reg `PWFPGA_REG_HASH_SEED`).
    Classifies a frame by an EXACT, MASKED match on a WIDE header key — 11
    field-aligned 32-bit words covering the full IPv4/IPv6 **5-tuple** (src+dst
    IP, src+dst port, proto) **+ VLAN + ethertype** — scaling payload-agnostic
    classification to the checker's `NUM_FLOWS` (vs the field comparators' ~`NCMP`
    cap) and without the test-header `flow_id`, so the payload stays free.
    Direct-indexed BRAM hash table (1 read + 1 full-key verify, NOT an N-way
    parallel match, so it routes): the key XOR-folds to 32 bits, a Dietzfelbinger
    multiply-shift (seed) chooses the bucket, and the stored full key is compared
    for an exact hit (the hash only picks the bucket — no misclassification). A
    **global key mask** (ANDed into both the hash input and the verify) selects
    which bits participate: masking out a field/bits lets a generator **modifier
    randomize** them while the flow still classifies. The compiler routes
    `classify: header` flows here, builds the global mask (key everything, then
    relax the bits any flow randomizes via modifiers or narrows via match masks),
    and searches a hash **seed** that places the masked keys collision-free; the
    field+UDF classifier then carries only punt/forward. Data-plane precedence:
    flow-id **map > hash classifier > field classifier**. Bit-identical HW/SW
    hash + key build. Completes Phase 5 of `docs/design/generic-classifier.md`.
    Examples: `phase3-header-classify.yaml` (24-flow exact scale test),
    `phase3-header-random.yaml` (randomized src port, masked out of the key).
  - **Classifier redesign — unified field+UDF comparator engine; legacy
    classifier retired** (`pw_field_classifier` + `pw_slice_match`; CSR windows
    `PWFPGA_WIN_FC_CMP`/`_UDF`/`_RULE` @ 0x2000). Replaces the parallel
    `pw_classifier` (an N×~600-bit masked-key compare that hit the xcku3p route
    wall at ~16 entries) AND the interim slice classifier with one engine:
    `NCMP` (12) **field comparators** each `{src,mask,value}` over a 32-bit lane
    selected from the parser's canonical fields (mux-free — the parser already
    extracts + position-normalizes them, so a 128-bit IPv6 addr is 4 comparators
    over its lanes); `NUDF` (2) **UDF comparators** `{offset,mask,value}` over the
    raw inner-frame window (for DSCP/TTL/flow-label/TCP-flags/arbitrary bytes);
    and `NRULE` (32) **rules** that AND a `care` subset of the comparator bits
    into `{action,egress,lfid,lif}`. The per-rule compare is only NCMP+NUDF bits,
    so it routes far past the legacy ~16 wall — and **retiring the legacy 600-bit
    classifier frees the RX-region routing budget** so the engine + the 32-flow
    data plane fit together on the xcku3p (the interim slice classifier could not
    route at 32 flows alongside the legacy one). Handles every action the legacy
    did (TEST_RX / PUNT / MIRROR / FORWARD / DROP); the compiler lowers
    header-defined test flows (`classify: header`) + punt + forward rules to
    comparators + rules, while structured high-count TEST_RX still rides the
    flow-id map. **Payload-agnostic**: a flow classified by header carries no
    dependency on the test `flow_id`, so its payload is free. The parser exposes
    the header byte-window (`window_o`) + inner-L3 base (`base_o`) aligned with
    `key_valid_o` (encap-aware UDF offsets). The RX checker now counts
    **non-test** frames too (rx_frames only; loss = tx-vs-rx count), so
    arbitrary-payload or external DUT traffic is countable, while structured test
    frames keep full seq/latency/jitter. (The standalone `pw_phase3_{punt,
    forward,modgen,inject,ipv6gen}` tools still target the legacy classifier and
    need migration to the field-classifier programming.)
  - **TEST_RX flow-id map — scalable flow classification** (`pw_flowid_map`,
    `PWFPGA_WIN_FLOWID_MAP` @ 0x0400). A test frame's parsed `test_flow_id`
    directly indexes a BRAM table → its checker slot (gated by the parser's
    magic/`is_test`), so TEST_RX flows no longer need a per-flow classifier
    rule. This removes the route-congestion wall that capped the parallel
    classifier at ~16 entries on the xcku3p — test-flow count is now bounded by
    the checker/generator (`NUM_FLOWS`), not classifier routability. The
    parallel classifier (`pw_classifier`, 16) now carries only the few non-test
    rules (PUNT/FORWARD/DROP) and routes comfortably. The compiler emits a map
    entry per TEST_RX flow (`flow_id → local slot`) instead of a classifier
    rule; the data plane overrides the classifier result for map-matched test
    frames. Keying on the stable `flow_id` also makes header-field modifiers
    (udp_dst/ip rotation) irrelevant to RX classification. First piece of the
    generic slice-based classifier (`docs/design/generic-classifier.md`);
    `pw_slice_match` (the programmable offset/mask/value extractor for the
    flexible front-end) is also landed + unit-tested.
  - **Classifier IPv6 dst-address match** — a TEST_RX rule for an IPv6 flow now
    matches the inner IPv6 **destination** address exactly, in addition to
    udp_dst + l3_proto + magic + flow_id. The 40-byte `pwfpga_match_key` has no
    room for a 128-bit address, so the dst key + mask live in the classifier
    row tail (bytes 96..127 — the entry was 96 B of a 128 B stride, so no row
    growth); `pw_classifier_window` decodes them (network byte order, matching
    `pw_parser_axis`). The match is exact (`==`), so the compiler skips it when
    a dst modifier rotates the address (shared `dst_ipv4` field, low 32 bits of
    v6) — udp_dst+magic+flow_id still identify the flow there. The `pw_classifier`
    match logic + parser extraction already existed; this wires the host path.
  - **Per-flow IPDV jitter** — `pw_test_rx_checker` now tracks each flow's
    previous-sample latency and accumulates `|latency[n] - latency[n-1]|` into
    per-flow jitter min / max / sum (RFC-3393 instantaneous packet delay
    variation; the first sample only seeds `prev_latency`). Surfaces in the flow
    stats block at jitter_min@104 / jitter_max@108 / jitter_sum@112 and is
    printed by `pw_phase3_loopback` (with a derived average over n-1 deltas).
    min/max (and the internal `prev_latency`) are 32-bit — a single inter-arrival
    delta never approaches 2^32 ns, and the snapshot fields are u32 anyway — while
    `sum` stays 64-bit (it accumulates over the whole run); this reclaims the
    dp_clk LUT headroom that a fully-64-bit jitter path had pushed to ~90%.
  - **Per-port link health + FCS errors** — `pw_data_plane_axis` 2-FF
    synchronizes the async MAC/PCS `link_up` / `block_lock` status into `dp_clk`
    and edge-counts link-up / link-down transitions and block-lock losses
    (`link_up_count@64` / `link_down_count@68` / `block_lock_loss@72`, sticky
    across `stats_clear`); RX `tuser`-on-`tlast` errored frames are counted into
    `rx_fcs_error@16`. A `set_false_path` constrains the status synchronizer.
  - **Per-flow TX counters (true loss = tx − rx)** — the generator keeps a
    clearable per-slot TX frame counter that merges into the flow stats block's
    `tx_frames`; `pw_phase3_loopback` prints `tx / rx / loss(tx−rx)`. (The
    snapshot reads tx and rx non-atomically, so a single frame in flight shows
    as loss(tx−rx)=±1; `lost_packets_estimated` is the authoritative loss.)
  - **Per-port Tx/Rx frame + byte counters** — `pw_data_plane_axis` now counts
    every frame/byte at each port's ingress (rx_frames/rx_bytes) and egress
    (tx_frames/tx_bytes), 48-bit (zero-extended to the 64-bit snapshot fields),
    filling the previously-zeroed `pw_port_stats` slots. The SAF forward-buffer
    overflow (previously a silent drop) folds into `port_drops`, and a stats
    clear now re-baselines the port counters + `port_drops`. `pw_phase3_loopback`
    prints them. NUM_FLOWS dropped 32→24 for the LUT headroom (80.7%, dp_clk
    +0.038 met). HW-validated: per-port counters track the loopback (p0 tx ==
    p1 rx), encap matrix still loss=0.
  - **Encapsulated packet generation + RX decap (IPIP / GRE / EtherIP)** — a flow
    can set `encap: { type, outer: {ipv4|ipv6} }` to wrap its inner IP/UDP/test
    frame in a tunnel: IPIP (outer-IP proto 4/41), GRE (proto 47 + 4-byte GRE),
    or EtherIP (proto 97 + 2-byte EtherIP + inner Ethernet, whose MAC is set by
    an optional `encap.inner_l2` block or defaults to the flow MAC). The outer family is
    independent of the inner — every v4/v6 inner × v4/v6 outer combination is
    supported. The generator builds the full stack and the outer IPv4 header
    checksum; egress timestamping rewrites the inner test header's tx_timestamp
    and fixes up the inner UDP checksum at its (encap-dependent) deep offset; the
    RX parser auto-decapsulates recognized tunnels and classifies on the inner
    test flow. `rx_expect: inner|tunneled` records whether the DUT decapsulated
    the return traffic. Full stack: config/wire/compiler, RTL (generator,
    `pw_ts_insert`, `pw_parser_axis`, flow table/row), sims (`sim_fge` byte-level
    + gen→decap round-trip, `sim_tsi` deep-offset cases, `sim_ftb`), and docs.
    **Validated on HW** (KU3P, SFP+ DAC loopback): all four combos — IPIP v4/v4,
    IPIP v6/v6, GRE v4-in-v6, EtherIP v4/v4 — run loss=0 at line rate, latency
    70–82 ns, 0 drops (`configs/examples/phase3-encap{,-matrix}.yaml` via
    `pw_phase3_loopback`).
  - **BRAM-backed flow table** (`pw_flow_table_bram`) — to fit the encap-widened
    data plane on the fabric: the 32-wide registered flow-row array + its fan-out
    + the per-generator 32:1 row mux (the routing wall, ~92% LUT) were replaced
    with a block-RAM table (decoded once via a commit walk into a per-generator
    BRAM copy) + a compact per-slot scheduling FF array; the dead legacy
    `gen_*_o` selection was removed. LUT 92%→87%, FF 78%→66%, +34 RAMB36. The
    parser was split 2→3 stages (L2+decap-descent / inner L3-L4 / test extract)
    and the quasi-static shadow→live commit paths multicycled, to recover dp_clk
    margin. Host CSR/wire format unchanged.
  - **Background (load) flows** — a flow can set `background: true` to generate
    TX-only traffic with no RX classifier rule and no measurement. Background
    flows don't consume a classifier entry, so a config can run more generator
    flows than the classifier capacity (e.g. 32 gen slots / 16 measured). SW
    only (the compiler emits the TX flow row but skips the TEST_RX rule).
  - **Bitwise (TCAM-style) classifier matching on dst port + dst IPv4** — the
    classifier compares `(key & mask) == (rule_key & mask)` for `l4_dst`/
    `udp_dst` and `ipv4_dst`, so a rule can match only part of a field. Enables
    using a generator modifier on a *classified* field (the rule matches the
    fixed bits; the compiler auto-relaxes the mask to exclude the rotated bits)
    and classifying arbitrary-payload traffic by header bits via a YAML
    `match: { udp_dst, ipv4_dst }` block. All-ones mask = exact (back-compatible
    with the prior boolean match); 0 = wildcard. The wire format is unchanged
    (the per-entry mask already carried the bytes; the RTL stopped OR-reducing
    them to a boolean). `sim` gains a partial-port match/non-match scenario;
    unit test covers the compiler mask emission + auto-relax + background.
  - **MAC / VLAN field modifiers** — extends the generator's field-modifier
    scheme to `src_mac` / `dst_mac` (48-bit mask) and `vlan` (low 12 bits),
    same `mode` (static/increment/random) + `mask` syntax as the address/port
    modifiers. These only rewrite the Ethernet header (not in any checksum),
    so they sit off the dp_clk checksum-critical path. Wire row gained the
    MAC/VLAN modifier fields at bytes 140..156 (256 B stride unchanged);
    `pw_field_mod.mask` widened to 64-bit to carry the 48-bit MAC mask.
    `sim_fgm` checks src-MAC and VLAN-ID rotation; unit test covers the
    config → wire mapping (MSB-first MAC mask, 12-bit VLAN mask).
  - **IPv4/IPv6 generator feature parity** — IPv6 flows gained the features
    previously IPv4-only: (1) **address field modifiers** — `src_ipv6` /
    `dst_ipv6` (YAML, same syntax as the v4 keys) rotate the low 32 bits of
    the address (host / interface-ID) per frame for DUT hashing / ECMP
    testing; the modified address is folded into the IPv6 UDP checksum in
    hardware. The wire reuses the existing address-modifier slots (a flow is
    one family), applied to the active family. (2) **DSCP / traffic class**
    and **TTL / hop limit** are now emitted from config for *both* families
    (`ipv4.dscp` -> IPv4 TOS, `ipv6.dscp` -> IPv6 traffic class; `ttl` /
    `hop_limit` -> the respective header field) — previously both were
    silently hardcoded (TOS=0, TTL=64), so the IPv4 `dscp` config was a
    latent no-op; the IPv4 header checksum now includes TOS + TTL. Defaults
    (dscp 0, ttl/hop_limit 64) keep existing configs byte-identical.
    `sim_fgm` checks both families' DSCP, TTL/hop-limit, and the IPv6
    address modifier (rotates low bits, keeps high bits, checksum valid).

- **Phase 3 data plane on silicon (AS02MC04 / KU3P)** — the 64-bit
  streaming data plane runs on hardware at line rate, loss=0:
  - Rewrote the unroutable wide `pw_frame_t` bus into a 64-bit AXIS
    streaming plane (`pw_parser_axis`, `pw_flow_gen_multi`,
    `pw_frame_saf`, `pw_data_plane_axis`); closes timing at 156.25 MHz.
  - Scaled to **32 flows / 16 classifier rows / 16 latency bins**;
    bidirectional + 16 concurrent flows validated at loss=0.
  - **Store-and-forward FORWARD validated on silicon** — a classifier
    `FORWARD_PORT` rule routes ingress frames through `pw_frame_saf` to
    the egress port; HW test (`pw_phase3_forward`) crossed the DAC twice
    at line rate with loss=0.
  - **FORWARD egress port now host-selectable** — added
    `egress_local_port` (byte 92) to the classifier wire struct and
    decoded it in `pw_classifier_window`; the data plane already routed
    by the classifier result's `egress_port` (previously hardwired to
    0). `pw_phase3_forward [fwd_egress]` validates routing to either
    port; `sim_vec` covers the new wire byte.
  - **FORWARD rules from config** — a top-level `forwards:` YAML section
    (ingress/egress port + optional ethertype/ip_proto/udp_dst/vlan
    match) compiles to classifier `FORWARD_PORT` rows; ingress/egress
    must be on the same card. Example `configs/examples/phase3-forward.yaml`;
    schema in `docs/design/yaml-schema.md`.
  - **Timing margin recovered** — pipelined `pw_parser_axis` key extract
    into two stages; WNS +0.003 → +0.020 ns at 156.25 MHz, HW-revalidated
    at loss=0.
  - **IPv6 test-flow generation** — the generator now emits IPv6/UDP
    frames (ethertype 0x86DD, 40-byte header) with a correct, non-zero
    UDP checksum (IPv6 mandates it). The generator computes a *partial*
    checksum (IPv6 pseudo-header + UDP + payload, **minus** the
    tx_timestamp) and `pw_ts_insert` folds the egress departure stamp into
    it at the MAC, yielding the final valid checksum on the wire — so IPv6
    flows get the same DUT-accurate egress timestamping as IPv4 (see
    below). Selected per flow via a YAML `ipv6: {src,dst,hop_limit}` block
    (mutually exclusive with `ipv4:`); the flow-table row stride grew
    128→256 B to carry the 16-byte addresses. The test header is unchanged
    so RX loss/latency is identical. Example
    `configs/examples/phase3-ipv6.yaml`; `sim_fgm` checks the IPv6 partial
    checksum, `sim_tsi` checks the egress finalization + a forwarded
    IPv6/UDP frame left untouched; HW tool `pw_phase3_ipv6gen`. (Field
    modifiers remain IPv4-only in v1; IPv6-address modifiers are a
    follow-up.)
  - **IPv6 egress hardware timestamping + UDP-checksum fixup** —
    `pw_ts_insert` now detects the L3 family and overwrites tx_timestamp at
    the correct IPv6 offset (byte 82, +4 VLAN), and finalizes the IPv6 UDP
    checksum by adding the four departure-stamp words to the generator's
    partial sum (RFC 768 `0→0xFFFF`). One-pass, no buffering: the csum
    field (@60) precedes tx_ts, so only the new (SOF-latched) stamp is
    needed. Gated by a "generator test frame" marker the egress arbiter
    raises (`sel_gen`), carried as AXIS `tuser` through the MAC-TX CDC, so
    forwarded / injected IPv6/UDP traffic is never rewritten; the marker is
    consumed in the stamper (MAC sees `m_tuser=0`).
  - **Timing: registered flow-table decode + generator checksum
    precompute** — recovering the margin the 256-byte rows + IPv6 checksum
    cost, without cutting flows/scale. (1) `pw_flow_window` registers the
    decoded `flow_rows_o`; with 256-byte rows the decode fan-out into the
    generators was a dominant `dp_clk` path (commit lands one cycle later,
    harmless). (2) `pw_flow_gen_multi` precomputes the modifier-applied
    header fields + IPv4/IPv6 checksums one stage ahead, registered
    alongside the round-robin `pick` (same 1-cycle staleness, so they align
    with the built row), so the frame-build cycle only lays out bytes
    instead of running mod32/scramble + the checksum adders. Made possible
    by excluding the live tx_timestamp from the IPv6 checksum (it is folded
    in at egress), which makes the whole checksum pick-stable. (3) The IPv6
    UDP checksum is summed as a single multi-term expression rather than
    sequential `+=`, so synthesis maps it to a balanced adder tree instead
    of a deep carry chain — this cone was the dp_clk-critical path.
  - **Generator field modifiers + correct IPv4 checksum** — per-field
    modifiers (`static` / `increment` / `random` with a bitmask) on
    `src_ipv4` / `dst_ipv4` / `udp_src` / `udp_dst` rotate the masked bits
    per emitted frame (driven by the slot's sequence number, no extra
    per-slot state), so one generator slot looks like many flows to the
    DUT. The test header (magic/flow_id/seq/ts) is never modified, so RX
    loss/latency measurement is unaffected. `build()` now emits a correct
    IPv4 header checksum (was 0), recomputed from the modified addresses.
    Configured via a `modifiers:` block per flow (`forwards`-style); see
    `configs/examples/phase3-modifiers.yaml` and `docs/design/yaml-schema.md`.
    Sim (`sim_fgm`) verifies the dst-IP rotation (masked) + a valid on-wire
    IPv4 checksum.
  - **SAF buffer BRAM-backed** — `pw_frame_saf`'s 512-beat frame buffer
    now infers as block RAM (reset-less write port + registered read-ahead
    drain) instead of ~37k FFs/instance + a wide mux. Frees ~24% of device
    FFs and ~14% LUTs across the two instances, which de-congested the
    route-dominated paths: **WNS +0.005 → +0.143 ns** with no feature or
    scale change. HW-revalidated (loopback loss=0, FORWARD, PUNT, inject
    round-trip).
  - **PUNT / slow-path RX to the host** — `pw_punt_rx_window` sinks the
    data plane's punt AXIS (`PUNT_TO_HOST` / `MIRROR_TO_HOST`) into a
    CSR-polled single-frame buffer (`PWFPGA_WIN_PUNT_RX`, BAR, no DMA).
    The SAF now carries each frame's `logical_if_id` + ingress port as
    metadata; `bar_slow_path_rx` drains frame + lif, and the daemon
    `host_plane` routes them to the per-`logical_if_id` TAP. New
    `sim_punt` unit tb; the `sim_top` punt scenario reads the frame back
    over the CSR BAR (lif verified).
  - **PUNT / slow-path TX from the host** — `pw_inject_tx_window` is the
    host → FPGA complement: the host composes a frame in a CSR buffer
    (`PWFPGA_WIN_INJECT_TX`, 512 B max), sets length + egress, writes GO;
    the window emits it into that egress port's TX arbiter (priority
    between forwarded frames and the generator). `bar_slow_path_tx`
    drives it. New `sim_inj` unit tb + a `tb_data_plane_axis` inject
    scenario (arbiter routes inject to the chosen egress). HW round-trip
    (`pw_phase3_inject`): inject out egress 0 → DAC → RX1 → PUNT → read
    back byte-identical, proving both slow-path directions on silicon.
  - **BRAM-backed latency histogram** (`pw_lat_histogram`) — freed the
    FF wall that capped flow scaling; read live via the CSR window.
  - **Egress hardware timestamping** (`pw_ts_insert` + `pw_ts_gray_cdc`)
    — tx_timestamp applied at the MAC (PTP one-step style), so measured
    latency reflects the DUT, not the tester's own TX queuing.
  - **CSR data-plane soft-reset** (`REG_DP_RESET`) — recover a wedged
    data plane without a JTAG reconfig.
  - **Wide CSR address map** — classifier/flow/stats windows 16 KB,
    histogram 8 KB (128 B stride); commit/trigger/clear above the data
    region. (ABI change; see `docs/design/csr-map.md`.)
- **In-system flash + reconfiguration**
  - `pw_spi_flash` CSR SPI master via STARTUPE3 — erase/program/read the
    config flash live over PCIe (no JTAG); `pktwyrm flash` / `pw_flash`.
  - `pw_icap_reboot` (ICAP IPROG via `REG_REBOOT`) — reload the bitstream
    from flash in-band; `pw_reboot`. The full-feature image is flashed as
    the cold-boot image.
- **Lab integration: pktwyrm-tinet**
  - `tools/pktwyrm-tinet/` generates a [tinet](https://github.com/tinynetwork/tinet)
    topology + per-router FRR configs from a small lab spec that
    references an existing PacketWyrm config. Each router runs in a
    container; its assigned PacketWyrm TAP is moved into the
    container's network namespace via tinet `postinit_cmds`, so
    PacketWyrm stays the data-plane truth and tinet handles the
    container lifecycle.
  - v1 supports BGP (asn / router_id / neighbors / advertised
    networks). OSPF / IS-IS can be added under the same `routing:`
    shape when needed.
  - Lifecycle CLI: `pktwyrm-tinet up LAB.YAML` starts `packetwyrmd`,
    waits for TAPs to appear, runs `tinet up` + `tinet conf`, and
    persists state (pid, tinet.yaml, TAP list) under
    `<out_dir>/.pktwyrm-lab.json`. `conf`, `down`, and `status`
    operate against that state file. `down` is idempotent and falls
    back to a best-effort `tinet down` when the state file is gone
    but a tinet.yaml is still present.
  - `make -C tools/pktwyrm-tinet test`: 35 / 35 tests in pure Python
    (PyYAML + `unittest.mock` only). No docker / tinet / FPGA
    required. Covers golden YAML/FRR rendering, lab-spec schema
    validation, state-file round-trip, shell command construction,
    and the up/down/conf orchestrator (with mocked subprocess).
  - Worked example at `configs/examples/lab-frr-2node/` with two FRR
    routers peering eBGP across a DUT.
  - Lab spec lives in its own file (referencing the PacketWyrm config
    by path); the core daemon and its JSON Schema are untouched.
- **Parser & classifier**
  - QinQ (802.1ad outer + 802.1Q inner) tag decoding
  - IPv6 (40-byte fixed header, source/dest extraction, next-header
    routing to TCP / UDP / ICMPv6)
  - Unified `l4_src` / `l4_dst` for TCP and UDP
  - Protocol class flags: `is_arp`, `is_ipv4`, `is_ipv6`, `is_tcp`,
    `is_udp`, `is_icmp`, `is_icmp6`, `is_ospf`
  - Matching mask bits for each new field
- **Test RX checker**
  - Per-flow min / max / sum / sample-count latency stats
  - Power-of-two latency histogram
- **Flow generator**
  - Token-bucket rate limit with Q16.16 bytes/cycle + burst-byte cap
- **CSR / BAR backend**
  - Wire-format structs (`pwfpga_classifier_entry`,
    `pwfpga_flow_config`, `pwfpga_test_hdr`, DMA descriptor /
    completion) are now `__attribute__((packed))` so the host
    and the RTL share a byte-for-byte view.
  - CSR window strides + commit register offsets centralised in
    `csr.h` (`PWFPGA_CLASSIFIER_STRIDE`,
    `PWFPGA_REG_CLASSIFIER_COMMIT`, etc.).
  - `pw_bar_backend_*` ops are functional end-to-end:
    classifier_write / flow_write / classifier_commit /
    flow_commit / stats_snapshot / port_stats_read /
    flow_stats_read / flow_hist_read all use word-aligned BAR
    writes/reads against the documented window layout.

- **Host stack**
  - `libpacketwyrm/tap.h` &mdash; create / configure TAP devices via
    `/dev/net/tun` + ioctl (no libnl dependency)
  - `libpacketwyrm/host_plane.h` &mdash; FPGA punt &harr; TAP fd
    bridge using slow-path RX/TX FIFOs on the backend
  - `libpacketwyrm/ipc.h` &mdash; length-prefixed JSON over Unix domain
    socket
  - Fake-backend slow-path FIFOs + `pw_fake_backend_inject_punt` /
    `_drain_tx` test helpers
  - `pw_pci_discover()` &mdash; sysfs-based PCI enumeration
  - `pw_bar_backend_open()` &mdash; mmap of
    `/sys/bus/pci/devices/<bdf>/resource0`
- **`packetwyrmd`**
  - Long-running event loop with TAP creation, host_plane stepping,
    SIGINT / SIGTERM clean shutdown
  - **Per-card worker threads**: one pthread per opened card runs
    its own `poll()` over its TAP fds + `pw_host_plane_step()`.
    The main thread keeps the control socket and Prometheus
    listener, so slow-path latency on one card cannot be starved
    by a busy control socket or by another card. Workers exit on
    a `stdatomic` stop flag set by the signal handler.
  - Initial program push to backends at startup
  - JSON-RPC server on a Unix socket:
    `version`, `cards`, `ports`, `flows`, `stats`,
    `flow.start`, `flow.stop`, `flow.stats`, `flow.hist`,
    `test.arm`, `test.start`, `test.stop`, `config.load`
  - **Live config reload** (`config.load`): the daemon accepts
    a fresh YAML body over RPC, parses / validates / compiles
    it, stops old flows, pushes the new program to every open
    backend, and swaps the cfg+prog atomically. Topology
    changes (cards / logical_ifs) are explicitly rejected
    because live TAP/backend swap isn't safe yet.
  - Prometheus `/metrics` exporter on `-p PORT`
- **`pktwyrm`**
  - Offline: `cards`, `ports`, `map`, `load`, `flow show`, `version`
  - Online: `rpc <method>`, `stats [--watch]`, `flow start|stop`,
    `flow stats`, `test arm|start|stop`, `hist latency --flow N`,
    `load <config.yaml> --socket PATH` (live deploy)
- **Packaging**
  - `make install` target with `DESTDIR` / `PREFIX` / split dirs
  - systemd unit (`packetwyrmd.service`), sysusers entry,
    tmpfiles entry, udev rule
- **Examples**
  - `configs/examples/container-frr/` &mdash; FRR-on-TAP via
    `ip netns` recipe, including a smoke-tested `start-r1.sh`
- **AS02MC04 (FPGA side)**
  - Phase 1 Vivado project skeleton with reverse-engineered pin
    assignments sourced from Julia Desmazes (Essenceia) and Alex
    Forencich (Taxi)
  - Verilator lint of the shared + AS02MC04 RTL
  - OpenOCD + J-Link JTAG bring-up recipe
- **Simulation**
  - `make -C sim sim`: Verilator-driven `tb_data_plane.sv`, 38 / 38
    assertions across scenarios: drop, punt, loopback, loss, dup,
    vlan, forward, ooo, rate, qinq, bgp, ospf, ipv6
  - `make -C sim sim_csr`: 24 / 24 assertions exercising the CSR
    window pipeline (AXI-Lite-style writes → shadow → commit →
    typed classifier table → data plane).
  - `make -C sim sim_flow`: 16 / 16 assertions for the flow-table
    window (per-port flow-gen inputs decoded from
    `pwfpga_flow_config` rows, lowest-indexed enabled row wins
    per egress port, atomic commit, disable via re-commit).
  - `make -C sim sim_stats`: 16 / 16 assertions for the stats
    snapshot window (per-port + per-flow counters latched on
    trigger, wire-format byte offsets match `pw_port_stats` /
    `pw_flow_stats`, re-trigger replaces the shadow).
  - `make -C sim sim_lat`: 16 / 16 assertions for the BRAM-backed
    per-flow latency histogram (`pw_lat_histogram`): accumulate via
    per-port checker events, live addressed read through
    `PWFPGA_WIN_HISTOGRAM` (NUM_BUCKETS u64s per flow at
    `lfid * PWFPGA_FLOW_HIST_STRIDE`), and clear.
  - `make -C sim sim_full`: 12 / 12 assertions exercising the
    full `pw_csr_full` AXI4-Lite slave end-to-end: identity
    reads, classifier write+commit through `axi_write`, stats
    snapshot trigger latches counters readable via the
    snapshot window, histogram trigger latches readable buckets.
  - `make -C sim sim_top`: 4 / 4 assertions exercising the
    `pwfpga_top_phase3` end-to-end loop: AXI-Lite host writes
    program both windows, the data plane emits frames via the
    AXIS serializer, the TB loops port-0 TX into port-1 RX
    through the deserializer, classifier hits TEST_RX, and the
    snapshot RPC reports rx_frames > 0. ARP on RX[0] raises
    the punt AXIS path.
  - `make -C sim sim_vec`: 25 / 25 assertions for the C ↔ SV
    wire-format byte-vector regression. A C-side generator
    (`sw/build/gen_bar_vectors`) drives the real
    `pw_bar_backend` ops against a tmpfs BAR, dumps the post-
    write image as a `$readmemh` hex file, and the RTL TB
    replays those dwords through `pw_csr_full` and verifies the
    decoded `pw_classifier_table_t` and per-port flow_gen
    inputs match what the host wrote. Drift in either side
    (csr.h struct layout, classifier_window byte offsets,
    flow_window byte offsets) fails this test before silicon
    ever boots.
- **CSR window RTL (Phase 3 ↔ BAR backend hookup)**
  - `rtl/shared/pw_csr_window.sv` &mdash; generic windowed-row CSR
    table with shadow + write-1-to-commit semantics. Parameters:
    `DEPTH`, `ROW_BYTES`, `WIN_BASE`, `COMMIT_OFFSET`. Live rows
    are exposed as packed byte arrays with byte 0 in the low bits,
    matching the AXI-Lite little-endian wire format.
  - `rtl/phase3/pw_classifier_window.sv` &mdash; adapts the wire-
    format `pwfpga_classifier_entry` rows into the typed
    `pw_classifier_table_t` that `pw_data_plane` consumes.
  - `rtl/phase3/pw_flow_window.sv` &mdash; adapts the wire-format
    `pwfpga_flow_config` rows into per-egress-port flow-generator
    inputs (token bucket Q16.16 tokens/cycle, burst bytes, MAC /
    IP / UDP / VLAN). The lowest-indexed enabled row binds to each
    `egress_local_port`.
  - Wire additions to `pwfpga_flow_config`:
    `tokens_per_tick_fp` (Q16.16 bytes/cycle, host-precomputed
    from `rate_bps` and `PWFPGA_DATA_PLANE_CLOCK_HZ`) and
    `burst_bytes`. The host flow compiler now populates both.
  - `rtl/phase3/pw_stats_snapshot.sv` &mdash; on
    `PWFPGA_REG_STATS_SNAPSHOT_TRIGGER` write, latches the live
    per-flow counters from `pw_test_rx_checker` and the per-port
    drop counters from the data plane into a shadow byte region
    whose layout matches `struct pw_port_stats` /
    `struct pw_flow_stats`. Reads served via `rd_addr/rd_data`.
  - Wire fix: `PWFPGA_FLOW_STATS_BASE` moved from `0x80` to
    `0x100` to keep the per-port stats area (2 × 128 B) from
    overlapping per-flow stats inside the snapshot window.
  - `rtl/phase3/pw_histogram_snapshot.sv` &mdash; same trigger
    semantics, separate window. Stores `NUM_BUCKETS` u64s per
    flow starting at `lfid * PWFPGA_FLOW_HIST_STRIDE`. Reads
    served via `rd_addr/rd_data`.
  - `rtl/phase3/pw_csr_full.sv` &mdash; AXI4-Lite slave (16-bit
    address) that wraps the identity registers and the four
    windows under one decode. Single write-strobe drives all
    four windows; a write to `PWFPGA_REG_STATS_SNAPSHOT_TRIGGER`
    latches the stats and histogram shadows in lockstep.
  - `rtl/phase3/pwfpga_top_phase3.sv` &mdash; board-agnostic
    integration top wiring `pw_csr_full` + `pw_data_plane`
    + per-port AXIS serializer / deserializer pair + a punt
    AXIS master. Per-board tops (e.g. AS02MC04) bring their
    PCIe → AXI-Lite bridge and 10G MAC IP around this core.
  - Wire change: `PWFPGA_CLS_FLAG_ENABLE` (bit 0 of
    `pwfpga_classifier_entry.flags`); the RTL ignores any row
    whose ENABLE bit is clear, and the host flow compiler sets
    it for every TEST_RX and PUNT_TO_HOST row.
- **Kernel driver (Phase 11 starting point)**
  - `kernel/packetwyrm.c` &mdash; out-of-tree PCI skeleton:
    `pci_driver` match on `10ee:a502`, BAR0 ioremap, identity-
    register read, dev_info dump.
  - `kernel/Kbuild` + `kernel/Makefile` for building against
    `linux-headers-$(uname -r)`.
  - `docs/design/kernel-driver.md` scoping doc: when the kernel
    driver becomes desirable vs. sticking with the userspace TAP
    plane, target architecture (NAPI / DMA / ethtool / devlink),
    coexistence rules, risks.

- **Tests**
  - `sw/libpacketwyrm/schema/packetwyrm.schema.json` &mdash;
    JSON Schema (Draft 2020-12) mirror of
    `docs/design/yaml-schema.md`. Informative only (the C
    validator is authoritative); useful for editor plugins
    (vscode-yaml, etc.) and a forcing function to keep the
    schema and the docs in sync.
  - `scripts/check-schema.sh` &mdash; optional dev tool that
    validates the example configs against the schema when
    `python3 + jsonschema + PyYAML` are installed (skips
    cleanly otherwise).
  - `make -C sw test`: 164 / 164 unit-test assertions across
    YAML / validator / flow compiler / backend (fake + BAR
    window writes / stats reads) / PCI discovery / host_plane /
    TAP / IPC
  - `make -C sw e2e`: shell-based daemon ↔ CLI smoke - launches
    packetwyrmd against an example config and walks the full
    JSON-RPC surface from pktwyrm, including `config.load`
    (same-topology accepted, different-topology rejected).
    18 / 18 checks.
  - `make -C sim/cocotb all`: Scapy + cocotb unit suite for the
    Phase 3 sub-modules. 17 / 17 Python assertions across
    `pw_parser`, `pw_classifier`, and `pw_flow_gen` behavioural
    mirrors. Runs under Icarus Verilog (the system Verilator
    5.020 predates cocotb 2.x's 5.036 minimum); the small
    behavioural RTL under `sim/cocotb/rtl/` mirrors the spec
    of the production modules on Icarus-friendly flat ports.
    The Verilator SV suite remains the integration gate against
    the production RTL.

### Documentation

- Initial design docs under `docs/design/` and phase plan under
  `docs/phases/`
- README updated to reflect the current implementation status
- Per-board bring-up notes in `fpga/as02mc04/docs/`
- This CHANGELOG
- RPC reference: `docs/design/rpc-protocol.md`
- Getting-started: `docs/guides/getting-started.md`
