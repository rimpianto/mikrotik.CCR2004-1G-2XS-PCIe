# atl1c-ccr2004fix 1.3 — production DKMS package

Production build of the patched `atl1c` driver for Linux hosts carrying the
MikroTik **CCR2004-1G-2XS-PCIe** (four emulated Qualcomm Atheros AR8151
PCIe functions, `[1969:1083]`).

## What 1.3 is

`1.3 = 1.1 + RX shared-info guard + module metadata.`

- **1.1** (unchanged): upstream `atl1c` plus the MTU/rx-buffer-size
  handling and the oversized-RX-frame drop that was accepted upstream as
  commit `c4ba1716853d` ("net: atl1c: drop oversized RX frames instead of
  panicking") and queued for the stable trees.
- **RX shared-info guard (new)**: before an RX skb is freed or passed up
  the stack, its `skb_shared_info` is validated (zeroed up to `dataref`,
  `dataref == 1`). A corrupted skb is **intentionally leaked** instead of
  being freed, logged rate-limited, and counted in the read-only module
  parameter `rx_shinfo_corrupt`.
- **Module metadata (new)**: maintainer `MODULE_AUTHOR`, `MODULE_VERSION`
  (`1.3`), and the version is surfaced in `ethtool -i` (drvinfo->version
  used to be empty).

## Why the guard exists

The emulated AR8151 of this card occasionally DMA-writes a small frame
(84-115 bytes observed) at a **wrong 128-byte-aligned offset inside a
still-posted RX buffer** when the link drops spontaneously ~1.3 s after a
MAC reset (MTU change, card reboot). The write is inside the buffer's own
DMA mapping — it is not a stale address. When the misplaced write lands in
the `skb_shared_info` area (past the frame region, same page), the next
free of that skb crashes the host with a general protection fault in
`skb_release_data` (observed 2026-11-16 on Proxmox VE 7.0.14-29-pve; the
kworker died holding rtnl on the second pass, wedging the host).

The guard converts that crash into a small, logged, intentional skb leak.
Evidence and instrumentation history (test builds 0.4.1 → 0.4.4-b1):
see `docs/atl1c-misplaced-dma-write.md` in this repository.

The guard is a **device-quirk mitigation, not an upstream candidate**: the
upstream fix track (RX error-descriptor buffer handling) is separate, see
`docs/atl1c-upstream-status.md`.

## Install

Requires the kernel headers for the running kernel and `dkms`. From this
directory:

```sh
sudo dkms add .
sudo dkms build atl1c-ccr2004fix/1.3
sudo dkms install atl1c-ccr2004fix/1.3
sudo reboot
```

**Never `modprobe -r atl1c` while its interfaces are in use** — on this
card it can wedge the host. Load the new module with a reboot, and keep an
out-of-band path (Intel AMT / a NIC on a different PCIe device) available.

`dkms status` must show `atl1c-ccr2004fix/1.3, <kernel>: installed`, and
after the reboot:

```sh
modinfo -F srcversion atl1c     # matches the build
ethtool -i <if>                 # version: 1.3
```

Note: `dkms autoinstall` promotes the **highest** registered version on
every kernel upgrade. Retire older/test versions with
`dkms remove atl1c-ccr2004fix/<v> --all` so 1.3 stays the one in control.

## Runtime parameters

| path | mode | meaning |
|---|---|---|
| `/sys/module/atl1c/parameters/rx_shinfo_corrupt` | ro | RX skbs leaked because their shared info was corrupted by a misplaced device DMA write |

A growing counter means the card is hitting the quirk; each event is one
leaked skb (~2-4 KiB) plus a rate-limited `atl1c: corrupt RX skb shared
info` message in the kernel log. This is the designed, safe behaviour.
