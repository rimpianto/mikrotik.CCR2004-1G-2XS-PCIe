# atl1c hardware test campaigns (2026-11-24 and 2026-11-25)

Validation of the **v5 upstream candidate** — the two-patch series
`net: atl1c: fix the RX buffer leak on errored frames` (RX poll-sync before
the link-down ring reset + RRD validation and error-path free) — on the
actual hardware: a MikroTik CCR2004-1G-2XS-PCIe whose SoC exposes emulated
AR8151 v2.0 functions, driven by `atl1c`, installed in a Proxmox VE host
(`pve-ms02ultra`, kernel `7.0.14-29-pve`).

Tested module: DKMS build **0.4.5** = production 1.3 + v5 candidate +
read-only diagnostic counters (`diag_poll_calls`, `diag_poll_waits`,
`diag_poll_max_loops`, `diag_poll_down_skips`, `diag_poll_timeouts`,
`diag_rrd_oos`, `rx_shinfo_corrupt`), srcversion
`82F3F15ABFC9A037A585BD2`. A **0.4.6** rebuild aligns the package with the
final amended candidate (explicit `smp_mb()` instead of
`smp_mb__after_atomic()`, one locked instruction on x86, see below);
0.4.5 remains the build of record for the runtime results.

Executor: Federico Musto (host, AMT console, RouterOS). Preparation, data
acquisition and analysis: automated from a build VM and a workstation.
Scripts: [`scripts/atl1c-test/`](../scripts/atl1c-test/).

## Campaign 1 — 2026-11-24: baseline behaviour (PASS)

2+2 GiB of traffic in both directions, 6 MTU changes (1500↔1600, `nic0` in
`vmbr0`), 3 manual flaps of the upstream port `ether-pcie1`:

- `diag_poll_calls=9` — every link-down went through the new bounded poll
  sync; `waits`, `timeouts`, `down_skips`, `rrd_oos`, `shinfo_corrupt` all 0;
- link recovered every time; no Oops, no warnings;
- **observation (no attribution)**: two IOMMU-blocked DMAR *DMA-Read* faults
  (`fault reason 0x71`, device `01:00.0`) about 1.26 s after MTU changes #1
  and #3 and about 0.2 ms *before* the hard-IRQ "Link is Down" message, i.e.
  before the driver's link-down work item had run. They cannot come from the
  link-down unmaps; an earlier hypothesis blaming the pre-existing TX-side
  race was retracted after timestamp analysis. Reads blocked by the IOMMU
  cannot corrupt host memory. Candidate explanations (unverified): the
  emulated device fetching a stale TX buffer address around its internal
  link-down, or an in-range but wrong `tpd_cons` (the out-of-range variant
  is upstream commit `36c2009d90f2`).

Because `diag_poll_waits` stayed 0, the wait loop itself — and its
`__AT_DOWN`-skip and timeout branches — were never executed. The v5 cover
letter states exactly that. The next campaign tried to close the gap.

## Campaign 2 — 2026-11-25: exercising the wait (partial success)

Goal: make a link-down land while an RX poll is genuinely in flight, so the
wait loop iterates (`diag_poll_waits > 0`) and, ideally, reaches its bound
(`diag_poll_timeouts = 1`, ratelimited warning, reset skipped, link
recovered on re-enable).

### Scenario A — flaps under RX flood

Flapping `ether-pcie1` while the host pulls a flood over the wire.

- First attempts with the flood generated between the host and a VM failed
  to load the driver: that traffic is bridge-local (`vmbr0` between two
  bridge ports) and never passes through `nic0`'s wire RX NAPI. **Traffic
  must come from the LAN side.**
- With a workstation→host TCP pull (~78 MB/s, `zero-http-server.py` +
  `curl`), link-down events were handled correctly (18 events across the
  day, all recovered, journal clean), but plain flaps still rarely catch a
  poll in flight: when the PHY link drops, packet delivery stops
  immediately, the in-flight poll finishes in microseconds, and the work
  item that runs milliseconds later sees `NAPI_STATE_SCHED` already clear.

### Scenario B — holding NAPI_STATE_SCHED artificially

To make the wait (and its timeout) observable, the NAPI thread must be
prevented from completing its poll while the work item samples the state
bit. Attempts, in order:

1. **cgroup-v2 freezer** (`cgroup.freeze` on a threaded cgroup holding the
   NAPI kthread): **does not work on NAPI kthreads** — they never reach a
   freezing point; `cgroup.events` stays `frozen 0` (verified on a 6.12 VM).
   Side finding: bound kthreads (kworkers, `PF_NO_SETAFFINITY`) cannot be
   moved into non-root cgroups at all (EINVAL); plain NAPI kthreads can.
2. **`cpu.max` starvation** (`echo threaded > cgroup.type`, move the kthread
   in, `cpu.max="1000 1000000"` = 1 ms of CPU per second): on a Debian VM
   (kernel 6.12.117) this throttles the NAPI kthread as expected
   (schedstat delta 53 ms/2 s → 1.5 ms/2 s, `nr_throttled` growing). On the
   **7.0.14-29-pve host it did not enforce**: `nr_throttled` incremented but
   the threads kept running ~112 ms/s against a 1 ms/s quota, so polls kept
   completing and the wait never had to spin long. Root cause not
   established (PVE kernel or threaded-cgroup bandwidth semantics); not
   pursued further on a production host.
3. Thread identification detail: NAPI kthreads created before the netdev was
   renamed all appear as `napi/eth%d-N`; they were identified by measuring
   `/proc/<pid>/schedstat` deltas under load instead of by name (the two
   busiest are the tested NIC's TX and RX threads).

### Results

- `diag_poll_waits`: **0 → 4**. On four link-down events (three under light
  load, one under the ~78 MB/s wire flood) an RX poll was genuinely in
  flight: the v5 wait loop iterated, the poll completed within a few
  milliseconds (≤2 loops ≈ 2-4 ms), and the reset proceeded normally. This
  is the handshake the patch exists for, observed on real hardware.
- `diag_poll_timeouts`, `diag_poll_down_skips`, `diag_rrd_oos`: still 0 —
  the timeout branch, the concurrent-teardown skip and the RRD out-of-sync
  reset were **not** exercised on hardware. Forcing the timeout needs the
  state bit held for ≥0.5 s, which the available non-invasive mechanisms
  could not achieve on this kernel (remaining options — SCHED_FIFO spinner
  plus `sched_rt_runtime_us=-1`, CPU hotplug — were judged too invasive for
  a host in daily use).
- 18 link-down events on 2026-11-25 (27 total across both campaigns), every
  one recovered; no Oops, no WARNING, no new DMAR faults, no RRD
  out-of-sync, no shared-info corruption during the campaigns.
- One `rx_shinfo_corrupt` event appeared overnight (00:04, host idle): the
  known misplaced-DMA-write quirk of this card
  ([atl1c-misplaced-dma-write.md](atl1c-misplaced-dma-write.md)) — an STP
  BPDU written at a wrong offset inside a posted RX buffer's shared info.
  The production 1.3 guard leaked and logged the skb as designed; the host
  was unaffected. This is the first recorded live firing of the guard
  (the same event class crashed the host on the unguarded 1.1 driver on
  2026-11-16).

### Reusable lessons

- Bridge-local traffic does not load the physical NIC's NAPI: generate test
  load from the LAN side.
- `nic0`'s own RX/TX counters are always zero on this card
  (`ndo_get_stats64` does not report the rings — a separate, still
  unsubmitted issue); use the bridge (`vmbr0`) counters to verify traffic.
- A TCP flood dies at the first link flap and must be restarted; a UDP
  flood from macOS dies with ENOBUFS after ~50 s at ~74 kpps unless paced.
- NAPI kthreads cannot be frozen with the cgroup-v2 freezer; `cpu.max`
  enforcement on threaded cgroups is kernel-dependent — verify with
  `schedstat` deltas, never trust `nr_throttled` alone.
- When the tested NIC carries host management, every starving test also
  starves the SSH session: run it from a script with an EXIT trap and keep
  an out-of-band console open.

## Relation to the upstream submission

The v5 series was posted to netdev on 2026-11-25 with a cover letter whose
test paragraph states exactly the coverage above (27 link-down events, four
in-flight-poll waits completed benignly under load; timeout/skip/out-of-sync/
error paths not exercised on hardware; emulated AR8151 only, `Tested-by:` on
genuine Atheros hardware welcome). See
[atl1c-upstream-status.md](atl1c-upstream-status.md) for links and the
review history.
