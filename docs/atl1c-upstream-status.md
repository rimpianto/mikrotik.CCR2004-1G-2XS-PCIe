# atl1c upstream patch status

Last updated: 2026-11-17.

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

**Queued (updated 2026-11-17).** Sasha Levin acked both backports on
2026-11-11 ("Queued for 5.15 and 5.10, thanks." —
https://lore.kernel.org/stable/20261111042846.78846-1-federico@rimpianto.com/T/).
`stable-queue` was re-checked on 2026-11-16/17: `queue-5.10` and
`queue-5.15` contain
`net-atl1c-drop-oversized-rx-frames-instead-of-panick.patch` (the 5.10
copy with `(*work_done)++` and `count++`, the 5.15 copy with
`work_done++`), as do the 6.1, 6.6, 6.12, 6.18 and 7.3 queues for the
mainline commit. No release ships the fix yet: the newest tags at the
time of writing are 5.10.274, 5.15.225, 6.1.192, 6.6.162, 6.12.117,
6.18.63 and 7.3.4 (-rc1 exists for 6.12.118, 6.18.64 and 7.3.5).

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

### v4 (prepared, not yet submitted as of 2026-11-17)

Patchwork tracks v3 as `changes-requested` (id 14942144) after a further
Sashiko review of 2026-11-08 whose main finding is that the error path
consumes the device-written `rfd_index` (12 bits, ring holds 512) and
`rfd_num` without validating them, and that the link-down ring reset is
not serialized against in-flight RX polls.

A v4 series of two patches is prepared against `netdev/net` (aa40afa831eb)
and fully verified (W=1 + Sparse + `checkpatch --strict`):

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

Submission awaits the reply to the Sashiko review (`pw-bot: cr`) and is
done only with the maintainer's explicit go-ahead.

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
| 0.4.x | test builds, never published | instrumented diagnostics used for the 2026-11-16/17 hardware campaign (see `docs/atl1c-misplaced-dma-write.md`); version numbers deliberately below 1.1 so `dkms autoinstall` can never promote them |

None of the packages above contains the v4 leak fix yet; it will land in
a future package version once accepted upstream. The submitted v3 patch
remains in `driver/patches/` for reference.
