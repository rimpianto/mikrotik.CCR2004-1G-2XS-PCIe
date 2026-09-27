# MikroTik CCR2004-1G-2XS-PCIe — survival kit for Proxmox VE / Linux hosts

Everything we learned (the hard way) about running the MikroTik
**CCR2004-1G-2XS-PCIe** (4x Qualcomm Atheros AR8151, driven by the Linux
`atl1c` driver) inside a Proxmox VE host - in our case a Minisforum
MS-02 Ultra, the same combo discussed in the MikroTik forum thread
*"CCR2004-1G-2XS-PCIe: Impossible to update RouterOS without crashing
Proxmox/Linux Host"*.

This repository contains:

| Path | What |
|------|------|
| `driver/patches/` | Kernel patch (`git format-patch`) fixing `skb_over_panic` on oversized RX frames |
| `driver/atl1c-dkms-1.1/` | Full DKMS package: patched `atl1c` driver (also carries upstream fix `36c2009d90f2` for the tpd_cons soft-lockup) |
| `scripts/ccr-safe-reboot` | Safe reboot/upgrade procedure for the card that keeps the host kernel alive |
| `docs/CCR2004-PCIe-Report.md` | Full technical report: crash analysis, kernel logs, experiment matrix |
| `logs/` | Raw evidence: kernel journals and procedure logs from the crash experiments |

## The three failure modes (short version)

1. **Soft lockup on card reboot** — the card reports an out-of-range
   `tpd_cons` (0xffff) while resetting; `atl1c_clean_tx()` spins forever.
   Fixed upstream by commit `36c2009d90f2` (included in our DKMS package).
2. **`skb_over_panic` on RX** — RouterOS defaults to `l2mtu 1600`; a host
   at MTU 1500 allocates ~1522-byte skbs; `skb_put()` of a 1600-byte frame
   panics the host. Fixed by our patch: RX buffers sized for full frame
   overhead (`ETH_HLEN + VLAN_HLEN + ETH_FCS_LEN + NET_IP_ALIGN`),
   descriptor length validated against `skb_tailroom()` before `skb_put()`,
   oversized/corrupt frames dropped and counted instead of panicking.
3. **Card-side reset misbehaviour (NOT fixable from Linux)** — on reset
   the card issues DMA writes to bogus addresses (IOMMU fault reason 0x71,
   e.g. `0xff3a6000`), wedging the VT-d DMAR: every NIC in the host loses
   DMA until reboot, and the card does not re-enumerate on PCI rescan.
   Track with MikroTik (SUP-223678).

## Quick start

### Install the patched driver (DKMS)

```sh
sudo dkms add driver/atl1c-dkms-1.1
sudo dkms build atl1c-ccr2004fix/1.1
sudo dkms install atl1c-ccr2004fix/1.1
sudo modprobe -r atl1c && sudo modprobe atl1c    # see warning below
```

> ⚠️ **Never unload/remove `atl1c` while the driver is active**
> (interfaces up, port attached to a bridge): on this hardware it
> wedges the kernel instantly. Take the interfaces down / detach them
> from the bridge first. The `ccr-safe-reboot` script does this for you.

Then raise the host MTU to match RouterOS `l2mtu` (default 1600):

```sh
ip link set <iface> mtu 1600 up
# and in /etc/network/interfaces for the bridge:
#   mtu 1600
```

### Reboot / upgrade the card without killing the host

```sh
sudo /usr/local/bin/ccr-safe-reboot
```

The script (requires a management path to the card that does **not**
go through it — e.g. the onboard 10GbE): quiets `atl1c`, removes the
PCI functions, orders the card reboot, waits, rescans, re-attaches
the port to the bridge. Verified to keep the kernel alive; see the
report for the current state of each step and the residual card-side
issues.

## Credits

- **Gajdos Tamás** — upstream `atl1c` tpd_cons fix (`36c2009d90f2`) and the
  PCI remove/rescan recovery procedure this work builds on
- **jaymemaurice** — first public write-up of the `skb_over_panic` issue
- The MikroTik forum thread participants for the shared debugging

## License

GPL-2.0-only for the kernel driver code (as the Linux kernel).
See `LICENSE` (the repository ships GPLv3 for the general material;
driver files retain their original GPL-2.0-only SPDX headers).
