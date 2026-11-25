# atl1c upstream patch status

Last updated: 2026-11-25.

This page tracks the upstream status of the `atl1c` fixes related to the
CCR2004-1G-2XS-PCIe work. It distinguishes accepted changes from patches
still under review and from the local DKMS package.

## Hardware interface note

The CCR2004-1G-2XS-PCIe does not contain four discrete AR8151 controllers.
Its SoC exposes four virtual PCIe Ethernet functions identifying as
AR8151 v2.0 `[1969:1083]`, which the host drives with `atl1c`. Testing on
this card therefore exercises MikroTik's emulated implementation and is
not a substitute for testing on a physical AR8151 NIC.

MikroTik documents the four virtual interfaces in the product description:
https://mikrotik.com/product/ccr2004_1g_2xs_pcie

Historical patch text using the shorthand "4x AR8151" refers to these
emulated functions; submitted patch files are retained verbatim.

## Accepted upstream

### TX soft lockup

Commit `36c2009d90f2` (`net: atl1c: fix soft lockup on out-of-range
tpd_cons read`) handles the out-of-range TX consumer index observed while
the card resets.

### Oversized RX frames

The minimal RX bounds-check fix was accepted in `netdev/net` as commit
`c4ba1716853d` (`net: atl1c: drop oversized RX frames instead of
panicking`). It drops a frame that does not fit the allocated skb instead
of reaching `skb_over_panic`.

The original, broader submission remains in
`driver/patches/0001-net-atl1c-fix-skb_over_panic-on-oversized-RX-frames.patch`
for reference. The accepted upstream change is intentionally smaller than
that original patch.

### Backports to 5.10-stable and 5.15-stable

The 6.1, 6.6, 6.12, 6.18 and 7.3 stable queues carry the upstream commit.
Sasha Levin reported that it does not apply to the 5.10-stable and
5.15-stable trees. The hunk lands in both, but the result does not build:
neither tree has `dev_core_stats_rx_dropped_inc()` or
`SKB_DROP_REASON_PKT_TOO_BIG`, and 5.10 also lacks `kfree_skb_reason()`.

Backports for both trees were submitted to `stable@vger.kernel.org` on
2026-11-11, each as a reply to the corresponding failure report:

- 5.10.y, version 2:
  https://lore.kernel.org/stable/20261111042846.78846-1-federico@rimpianto.com/
- 5.15.y:
  https://lore.kernel.org/stable/20261111042847.78866-1-federico@rimpianto.com/

Both count the drop with `atomic_long_inc(&netdev->rx_dropped)`, the
counter that `dev_core_stats` later replaced and that `dev_get_stats()`
adds to the values returned by `atl1c_get_stats()`, and free the frame
with `kfree_skb()`.

The 5.10 backport differs further because the receive loop there is still
`atl1c_clean_rx_irq()`: `work_done` is an `int *`, and the refill at the
end of the poll is gated on a separate local `count`, so the drop path
increments both. 5.10 also lacks the 64-byte RX slack added by commit
`86565682e905` (`atl1c: Work around the DMA RX overflow issue`), so the
code comment is reworded.

Version 2 of the 5.10 backport supersedes the first submission:

https://lore.kernel.org/stable/20261110233836.64643-1-federico@rimpianto.com/

That version incremented only `work_done`. A poll that saw only dropped
frames did not refill the ring, so sustained oversized traffic could still
stop RX. It also counted the drop in `netdev->stats.rx_dropped`, which
`atl1c_get_stats()` overwrites on every read.

Both backports were build-tested on x86_64 (`defconfig` with
`CONFIG_ATL1C=m`, W=1 and Sparse) against 5.10.274 and 5.15.225, with no
new warnings. Neither has been run on hardware.

**Released / in review (updated 2026-11-19).** Sasha Levin acked both
backports on 2026-11-11 ("Queued for 5.15 and 5.10, thanks." —
https://lore.kernel.org/stable/20261111042846.78846-1-federico@rimpianto.com/T/).
The mainline commit shipped in the stable releases of 2026-11-17:
**7.3.5, 6.18.64 and 6.12.118** (verified in the official kernel.org
ChangeLogs; `Upstream commit c4ba1716853d`).

On 2026-11-18 Greg Kroah-Hartman posted the -rc1 review cycles for the
four remaining branches, each carrying the patch; the -final releases
follow the usual ~7-day review window (i.e. around 2026-11-25):

- 6.6.163-rc1 (`[PATCH 6.6 1437/3318]`)
- 6.1.193-rc1 (`[PATCH 6.1 1222/2857]`)
- 5.15.226-rc1 (`[PATCH 5.15 0952/2214]`) — the backport submitted above
- 5.10.275-rc1 (`[PATCH 5.10 0784/1848]`) — the backport submitted above

6.6 and 6.1 queue the mainline commit unchanged (both trees have
`dev_core_stats_rx_dropped_inc()` and `kfree_skb_reason()`); 5.15 and
5.10 queue the adapted backports, with Sasha Levin's sign-off appended.

## Submitted, pending review

### RX error-descriptor buffer leak

Version 3 of `net: atl1c: free the RX buffer when the descriptor reports
an error` was submitted to netdev on 2026-11-03:

https://lore.kernel.org/all/20261103225218.19206-1-federico@rimpianto.com/

The submitted patch is stored verbatim in
`driver/patches/0002-net-atl1c-free-the-RX-buffer-when-the-descriptor-reports-an-error.patch`.

Before this fix, an RX descriptor carrying `RRS_RX_ERR_SUM` or
`RRS_802_3_LEN_ERR` caused the RFD slots to be recycled without unmapping
the DMA mapping or freeing the skb. Repeated CRC, alignment, truncation or
runt-frame errors could therefore leak receive buffers and DMA mappings.

Version 3 addresses the findings from the Sashiko review of v2:

- decode `rrs->word0` once in CPU byte order and use the decoded RFD index
  consistently;
- unmap, free and recycle every RFD belonging to an errored multi-RFD
  frame, including ring wrap;
- count errored descriptors as completed work so RX refill runs;
- clear the RRD ring during reset so stale error descriptors cannot free
  newly reposted buffers.

The Sashiko response marking v2 as changes-requested is archived at:

https://lore.kernel.org/all/20261103225321.19288-1-federico@rimpianto.com/

### v4 (submitted to netdev on 2026-11-17)

Patchwork tracks v3 as `changes-requested` (id 14942144) after a further
Sashiko review of 2026-11-08 whose main finding is that the error path
consumes the device-written `rfd_index` (12 bits, ring holds 512) and
`rfd_num` without validating them, and that the link-down ring reset is
not serialized against in-flight RX polls. A point-by-point reply to that
review was sent on the v3 thread on 2026-11-17.

The v4 series of two patches, against `netdev/net` (aa40afa831eb), was
submitted on 2026-11-17 22:55 UTC as patchwork series **1214336**
(1/2 id 14994927, 2/2 id 14994926):

https://lore.kernel.org/all/20261117225521.19689-1-federico@rimpianto.com/

- **1/2** — after `netif_carrier_off()`, the link-down work item waits
  for in-flight RX polls before touching the rings. Deliberately *not*
  via `napi_disable()`: the work item is not serialized against
  `atl1c_down()`, and a second `napi_disable()` sleeps holding the netdev
  instance lock, deadlocking the first caller's `napi_enable()`.
- **2/2** — before acting on an RRD, validate `rfd_num == 1`,
  `rfd_index == rfd_ring->next_to_clean` and that the slot holds a skb;
  on mismatch touch no buffer and schedule `ATL1C_WORK_EVENT_RESET`
  (the pattern `alx_clean_rx_irq()` uses). The error path unmaps and
  frees. The ring reset also clears the RRD ring (1.1 clears only the
  RFD ring).

Netdev CI on the submission is green on both patches (builds incl.
32-bit, clang and clang+rust, allmodconfig, kdoc, verify-fixes,
signed-off, series format); the only finding is a cosmetic checkpatch
warning on 2/2 (one 84-column line in a debug printk). As of
2026-11-18 the `sashiko-nipa` and contest checks are still pending and
no review comments have arrived; both patches are in state `new`.

### v5 (submitted to netdev on 2026-11-25)

The Sashiko AI review of v4 (2026-11-21) raised six findings: on 1/2, the
`__AT_DOWN` exit still reset the rings without having waited (High), an
unbounded wait under threaded busy-poll (Medium) and the TX side of the same
reset (High, pre-existing); on 2/2, a missing `dma_rmb()` between the
valid-bit test and `word0` (Medium), the `schedule_work()` lifetime /
`common_task` use-after-free (High, pre-existing with a new trigger) and the
missing serialization of `common_task` against the rtnl holders (High,
pre-existing).

v5 was additionally reviewed by a second independent model before posting.
That review confirmed the code as sound and corrected three written claims,
amended before submission:

- the barrier rationale of 1/2 was factually wrong: `netif_carrier_off()` is
  a fully ordered `test_and_set_bit()` (not a "plain bit store"), and
  `__napi_schedule()` contains no `test_and_set_bit(NAPI_STATE_SCHED)` — the
  bit is set by the `try_cmpxchg()` in `napi_schedule_prep()`. The handshake
  is a store-buffer pattern; the barrier is now an explicit `smp_mb()`,
  correct independently of how `netif_carrier_off()` sets its bit and on
  stable trees without commit `415d83249709`;
- the cover letter originally attributed two DMAR Read faults observed on
  24/11 to the MTU-change teardowns / the pre-existing TX race. Timestamp
  analysis disproved the attribution (the faults follow MTU changes #1 and
  #3 by ~1.26 s and *precede* the link-down interrupt); they are now
  disclosed as an observation without attribution;
- the test-coverage claims now state exactly which paths were and were not
  exercised: see [atl1c-hw-test-campaigns.md](atl1c-hw-test-campaigns.md).

v5 changes vs v4:

- **1/2** — on `__AT_DOWN`, skip the link-down reset entirely (the
  concurrent teardown resets the rings after `napi_disable()`); bound the
  wait (500 × 1-2 ms) and skip with a ratelimited warning on timeout; wait
  only on the work-item path (`atl1c_up()` passes `false`); explicit
  `smp_mb()` between the carrier-off store and the `NAPI_STATE_SCHED`
  sampling.
- **2/2** — `dma_rmb()` between the valid-bit test and the rest of the
  descriptor; hardware-coverage caveat (validation ran on an emulated
  single-queue AR8151 only, `Tested-by:` on genuine Atheros hardware
  welcome) and a note that it applies textually only on top of 1/2.

Submitted 2026-11-25 11:31 UTC as patchwork series **1222008** (1/2 id
15021737, 2/2 id 15021738), base `netdev/net` `aa40afa831eb` (the atheros
tree is unchanged up to `32756b82fde8` as of 25/11):

https://lore.kernel.org/netdev/20261125113120.99743-1-federico@rimpianto.com/

Point-by-point replies to the v4 Sashiko review (including `pw-bot: cr`)
were posted on the v4 thread on 2026-11-25.

### Companion one-liner: cancel common_task in atl1c_remove()

The pre-existing use-after-free flagged by the v4 review — `atl1c_remove()`
frees the netdev and adapter without ever cancelling `common_task`, and
`atl1c_close()` cancels it *before* `atl1c_down()` frees the IRQ, so a
link-change interrupt in between re-queues the work — is fixed by a separate
single-patch submission posted the same day (the v5 series deliberately stays
at two patches):

`net: atl1c: cancel the common_task work in atl1c_remove()` —
`cancel_work_sync()` after `unregister_netdev()`, where the IRQ is freed,
NAPI is disabled and the TX watchdog is stopped.
`Fixes: 43250ddd75a3`, Cc stable. Patchwork 15021740 (series 1222010):

https://lore.kernel.org/netdev/20261125113141.99792-1-federico@rimpianto.com/

On 2026-11-25 the `netdev-bot+sinfo` bot asked this patch to state its test
hardware. The answer — not tested on real hardware, found by inspection,
build-tested W=1+sparse, lab context on the emulated-AR8151 card — was
delivered on-list in plain text (a first attempt from a mail client was
rejected by the list servers as HTML, and the plain-text resend was
accidentally posted twice; both copies are identical):
https://lore.kernel.org/netdev/20261125121328.2662-1-federico@rimpianto.com/

## Hardware validation (2026-11-16/17, CCR2004-1G-2XS-PCIe)

The v4 candidate was validated on the actual card through instrumented
DKMS test builds (0.4.1 → 0.4.4-b1: v4 plus counters, buffer poisoning,
IOVA history and teardown snapshots — diagnostics only, never shipped):

- 1.5 M+ RRDs validated per session with **zero** descriptor mismatches
  across 15+ MTU-change resets and 4+2 GB traffic phases;
- the link-down poll-wait of 1/2 never timed out and never deadlocked;
- **zero Oops/WARNING/lockups on any v4-based build**, while the
  production 1.1 driver (without v4) crashed the host on the eighth MTU
  change of the same loop (see below — the crash trigger turned out to be
  a device quirk, not the race v4 fixes);
- stale-RRD counting showed the condition 2/2 guards against
  (`RRS_RXD_UPDATED` left set at reset) never occurred in 11 resets.

The campaign also identified a **separate, device-side fault**: around
its spontaneous post-reset link-down the card sometimes DMA-writes a
small frame at a wrong 128-byte-aligned offset *inside a posted RX
buffer's own mapping*, without writing an RRD; when the write lands in
the `skb_shared_info` the next free crashes the host (this is the
2026-11-16 Oops). Full analysis, evidence and hypothesis testing:
[atl1c-misplaced-dma-write.md](atl1c-misplaced-dma-write.md). It is
mitigated in DKMS package 1.3 and is **not** part of the upstream
submission.

The v5 validation campaigns of 2026-11-24/25 (27 link-down events; the
link-down wait observed iterating and completing benignly four times under
load; timeout branch not exercised; first recorded live firing of the 1.3
shared-info guard) are documented in
[atl1c-hw-test-campaigns.md](atl1c-hw-test-campaigns.md), with the scripts
in [`scripts/atl1c-test/`](../scripts/atl1c-test/).

## Verification of v3

The patch was checked against `netdev/net`:

- `git apply --check`: passed;
- `scripts/checkpatch.pl`: 0 errors, 0 warnings, 0 checks;
- baseline and patched W=1 builds with Sparse: both succeeded;
- no new warnings; three endian-related Sparse warnings were removed;
- no hardware runtime test has been performed for this specific fix.

The pre-existing descriptor memory-ordering issue and the link-reset/NAPI
race are not addressed by this patch and require separate work.

## DKMS package status

| version | status | contents |
|---|---|---|
| **1.3** (`driver/atl1c-dkms-1.3/`) | **current production** | 1.1 + RX shared-info guard against the misplaced device DMA write (corrupt skb leaked, logged, counted in `rx_shinfo_corrupt`) + module metadata (`MODULE_VERSION`, maintainer `MODULE_AUTHOR`, version in `ethtool -i`) |
| 1.1 (`driver/atl1c-dkms-1.1/`) | superseded | upstream + MTU/rx-buffer handling + oversized-frame drop (`c4ba1716853d`) + tpd_cons fix (`36c2009d90f2`). **Exposed to the host-fatal GPF** when a misplaced write hits a shared info — upgrade to 1.3 |
| 1.2 | retired, never published here | local build of the v3 leak fix; superseded by the v4 rework. Do not install |
| 0.4.x | test builds, never published | instrumented diagnostics for the hardware campaigns (see `docs/atl1c-misplaced-dma-write.md` and `docs/atl1c-hw-test-campaigns.md`); version numbers deliberately below 1.1 so `dkms autoinstall` can never promote them. **0.4.5** = 1.3 + v5 candidate + read-only `diag_*` counters: the hardware-tested build of record (srcversion `82F3F15ABFC9A037A585BD2`). **0.4.6** = 0.4.5 aligned with the final amended candidate (explicit `smp_mb()`; srcversion `8B1B51099A36CBAB6E87D9D`), build-verified only |

None of the published packages contains the leak fix yet; the v5 candidate
lives in the 0.4.5/0.4.6 test builds and will land in a future package
version once accepted upstream. The submitted patches are retained in
`driver/patches/` for reference.
