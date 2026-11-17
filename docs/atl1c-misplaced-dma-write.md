# atl1c on CCR2004-1G-2XS-PCIe: the misplaced DMA write

Status: identified 2026-11-16/17 with instrumented driver builds. Mitigated
by DKMS package **1.3** (`driver/atl1c-dkms-1.3/`). This is a device-side
bug of the emulated AR8151: the Linux driver cannot prevent the write, it
can only avoid crashing because of it.

## Symptom history

- **Sep 2026 (first experiments)**: DMAR faults from the card
  (`01:00.0`, IOMMU fault reason `0x71` = present bit clear, i.e. the
  device used an IOVA that is not mapped), both `[DMA Read]` and
  `[DMA Write]`, around card resets and link flaps.
- **16 Nov 2026, production driver 1.1, MTU-change stress**: the host
  died with

  ```
  Oops: general protection fault, probably for non-canonical address 0x1400030380620b
  skb_release_data <- napi_consume_skb <- atl1c_clean_rx_ring
    <- atl1c_reset_dma_ring <- atl1c_check_link_status (kworker)
  ```

  110 ms after a card-initiated link-down that itself followed a DMAR
  Read fault by ~5 ms. The worker died mid-cleanup; the next MTU change
  re-entered the same slot: `WARNING dma-iommu.c iommu_dma_unmap_phys`
  (double unmap, IOVA `0xff366140`, size `0x658` = 1624) plus a second
  identical Oops, this time with rtnl held — from there everything that
  takes rtnl stalled (host answered ping, sshd sent no banner). Recovery
  through Intel AMT.
- **Analysis of that Oops**: the skb was intact and consistent with its
  ring slot; its `skb_shared_info` had been overwritten (`flags` bit 0
  set = zerocopy, `destructor_arg` = garbage → GPF in the free path).
  Geometry for a 1624-byte buffer: data at page offset `0x140`, shared
  info at `0x800`; from the start of the data to the end of
  `destructor_arg` there are 1776 bytes, while the largest legal frame
  on an l2mtu-1600 link is 1622 — a legal write to a legal address
  cannot reach that far.

## Instrumented builds (0.4.x test series — diagnostics, not shipped)

Built and verified on a Debian 13 VM against the `7.0.14-29-pve` headers
(W=1 + Sparse, zero new warnings), each layer reverse-applied and compared
byte-for-byte with the previously shipped source, then run on the host
with an out-of-band console (AMT) and per-event snapshots.

| build | adds |
|---|---|
| 0.4.1 | read-only `diag_*` counters, observe-only RRD validation gate, error injection knobs |
| 0.4.2 | RX buffer poison (0xa5) with per-buffer validation, shared-info check before free/pass-up (corrupt skb lost, not freed), stale-RRD count at reset |
| 0.4.3 | per-queue map-time IOVA history + match of the written IOVA against earlier epochs, per-reset `epoch N ends` summary line (buffer IOVA min-max, descriptor-ring IOVAs) |
| 0.4.4-b1 | teardown snapshot: the 511 IOVAs still posted at each of the last two ring resets per queue (immune to traffic wrap), unconditional absolute-IOVA log of every misplaced write, module metadata |

## Evidence: four misplaced writes captured

| date (2026-11-17) / build | queue.slot | size | data offset | inside own mapping | stale-IOVA match |
|---|---|---|---|---|---|
| 00:52 / 0.4.2 | q3 s277 | 84 B | 384 | yes | n/a (0.4.2 had no IOVA logging) |
| 09:08 / 0.4.3 | q2 s446 | 84 B | 256 | yes | no (map-time history wrapped by 4 GB traffic) |
| 09:08 / 0.4.3 | q3 s499 | 84 B | 640 | yes | no (history wrapped) |
| 10:04 / 0.4.4-b1 | q1 s281 | 115 B | 1280 | yes | **no — decisive** (teardown tables of the last 2 resets) |

Common signature of all four:

- the data offset is an exact **multiple of 128** (256, 384, 640, 1280) —
  PCIe max-payload-style granularity;
- a **small complete frame** (84–115 bytes observed);
- the written IOVA lies **inside the buffer's own current DMA mapping**
  (the very buffer whose address the driver gave the card in its RFD);
- **no RRD completion** is written for it: the buffer stays "posted" and
  the write is discovered by the next ring reset;
- timing: always ~1.3 s after `Link is Up` following a MAC reset, at the
  card's **spontaneous link-down** (the card drops the link by itself
  after every reset — with the stock and with the patched driver);
- sometimes accompanied ~1 ms earlier by a DMAR **Read** fault at an
  unmapped IOVA (blocked read, harmless on its own).

The 0.4.4-b1 event, verbatim from the kernel log:

```
diag: queue 1 slot 281: posted buffer written at 1344-1458, its frame area is 64-1591
diag: queue 1 slot 281: posted-buffer write wrote iova 0x00000000febe2a80-0x00000000febe2af2,
     own mapping 0x00000000febe2580+1528, epoch 2
```

`0xfebe2a80 = 0xfebe2580 + 1280`; the write ends at `+1395 < +1528`,
entirely inside the mapping. No `STALE-MATCH`: the address matched none
of the 511 buffers still posted at the previous ring reset, nor any of
the 511 posted at the reset before that.

## Hypotheses, and how each was tested

- **A — the card keeps using pre-reset buffer addresses**, and the IOMMU
  meanwhile reassigns those IOVA pages to new buffers.
  *Refuted for the address set that matters.* The 0.4.4-b1 teardown
  tables contain every IOVA the device was still holding at each reset;
  the misplaced write matched none. The precondition for A does exist —
  the IOMMU aggressively reuses just-freed IOVAs (`diag_iova_reuse`
  counted 135–183 exact reuses per post-reset refill of ~2044) — but the
  card demonstrably did not write to a stale posted address. The
  residual variant (an address of a buffer consumed mid-epoch) is
  mechanically weak — the device would have to retain addresses of
  frames it already completed with an RRD — and is inconsistent with
  the 4/4 multiple-of-128 signature (under A the offset inside the hit
  buffer would be an arbitrary IOVA difference).
- **B — stale RRDs left valid after reset** make the driver consume and
  unmap a buffer the card then writes.
  *Refuted*: the stale-RRD counter was 0 at every one of the 11 resets
  observed with 0.4.2+ (which additionally zeroes the RRD ring at reset).
- **C — the card's DMA engine places a frame at a wrong, 128-aligned
  internal offset of the buffer it was just given.**
  *Consistent with everything*: the offsets, the sizes, the writes
  inside own mappings, the absence of RRDs, the timing at the
  spontaneous link-down, the 16 Nov Oops (offset ≈ 1664 with a ≥115-byte
  write spills from data+1664 into the shared info at data+1728 → GPF at
  free), and the DMAR **Write** faults (the same misplacement landing
  outside the mapping or the page → blocked by the IOMMU).

## Conclusion

Around its spontaneous post-reset link-down, the emulated AR8151
sometimes misplaces a small-frame DMA write inside a posted RX buffer,
at a 128-byte-aligned offset, without writing the completion descriptor.
The bug is in the device (firmware/emulation). Follow up with MikroTik
(existing ticket: SUP-223678).

## Mitigation: DKMS package 1.3

`atl1c_rx_skb_sane()` validates the shared info of an RX skb before the
skb is freed or passed up the stack (both in the ring-reset cleanup — the
path that killed the host on 16 Nov — and in the poll completion path).
A corrupt skb is **intentionally leaked** instead of freed, logged
rate-limited, and counted in the read-only module parameter
`rx_shinfo_corrupt`. Worst case per event: one lost frame and a ≤4 KiB
leak instead of a host-fatal GPF.

Cost: one `memchr_inv` of ~320 bytes per received frame. The instrumented
builds ran the same check plus far heavier validation over 1.5 M+ frames
per session with no measurable impact on this host.

The guard is a device-quirk mitigation for this card, **not an upstream
candidate**. The upstream `atl1c` work (RX error-descriptor leak fix,
link-down reset vs. RX poll serialization) is tracked separately in
[atl1c-upstream-status.md](atl1c-upstream-status.md). During the hardware
campaign the v4 upstream candidate itself was exercised indirectly: its
descriptor validation passed 1.5 M+ RRDs with zero mismatches across
15+ MTU-change resets, and its poll-wait change survived every
link-down reset without a single Oops in the 0.4.x builds.

## The DMAR Read faults (separate, blocked, unattributed)

~1.26–1.28 s after each `Link is Up` that follows an MTU change, and
1–3 ms before the spontaneous link-down, the card issues one DMA Read at
an unmapped IOVA (reason `0x71`). Seen with both production (1.1) and
instrumented builds; a read is blocked by the IOMMU and corrupts
nothing. The addresses (`0xfef8f000`, `0xfffc9000`, `0xfe22c000`,
`0xfec5a000`, …) could not be attributed offline: they fall inside the
min-max IOVA span of every epoch, and per-buffer data exists only in
kernel memory while the driver cannot see IOMMU faults.

## Reproduction

On a host whose interface is carried by the card, loop MTU changes
(each change is a MAC reset plus the card's spontaneous link-down):

```sh
ip link set dev <if> mtu 1500; sleep 30
ip link set dev <if> mtu 1600; sleep 30
```

Observed event rate on 2026-11-17: 4 misplaced writes across ~10 reset
cycles. **Warnings**: with an unguarded driver (≤1.1) a write landing in
a shared info crashes the host — keep an out-of-band console (Intel AMT)
attached, and never unload `atl1c` on a live interface.

## Raw evidence

- `logs/misplaced-dma-write-2026-11-17.txt` — kernel-log excerpts of the
  0.4.3 (09:08) and 0.4.4-b1 (10:04) events, including the `epoch N
  ends` summary lines and the DMAR faults of the session.
- Full per-event snapshots (counters, dmesg, dkms state) of the
  2026-11-16/17 campaign are kept on the lab host; contact the
  maintainer.
