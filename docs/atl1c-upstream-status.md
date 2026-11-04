# atl1c upstream patch status

Last updated: 2026-11-03.

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

`driver/atl1c-dkms-1.1/` predates the RX error-descriptor leak v3 patch.
Do not assume that installing DKMS version 1.1 includes this latest fix.
The submitted patch above is provided separately until the DKMS source and
version are updated and rebuilt.
