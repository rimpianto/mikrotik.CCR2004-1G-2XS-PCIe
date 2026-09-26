# MikroTik CCR2004-1G-2XS-PCIe on Proxmox VE — full technical report

## Host crash on card reboot: analysis, driver fixes, safe procedures and experimental evidence

---

## Environment

- **Host**: Minisforum MS-02 Ultra (Intel Core Ultra 9 285HX), Proxmox VE 9.2,
  kernel 7.0.14-19-pve
- **Card**: MikroTik CCR2004-1G-2XS-PCIe (4x AR8151, PCI 01:00.0-3, Linux
  driver `atl1c`)
- **Host networking**: vmbr0 with bridge port nic0 (= sfp28-1 of the card);
  IOMMU/VT-d enabled; independent out-of-band paths = onboard RTL8127 10GbE
  (`r8127` DKMS) and Intel AMT (I226-LM, WS-Man 16993)
- **RouterOS**: 7.15.2 → 7.24.4 (upgraded during the tests)

## Observed symptoms (3 distinct crash types)

### 1. Soft lockup on card reboot (stock driver)

RouterOS reboot (`/system reboot`) → the host dies with:

```
watchdog: BUG: soft lockup - CPU#12 stuck for 354s! [napi/eth%d-0:329]
RIP: 0010:atl1c_clean_tx+0x142/0x2d0 [atl1c]
```

**Cause**: while resetting, the card reports an out-of-range `tpd_cons`
(0xffff) → `atl1c_clean_tx()` spins forever → soft lockup → cascading
deadlock (ipset in D-state, nft mutex, I/O logging stops). Requires a
physical power cycle.

**Upstream fix**: commit `36c2009d90f2` ("net: atl1c: fix soft lockup on
out-of-range tpd_cons read") by Gajdos Tamás — treat 0xffff as "nothing
new to clean". Installed via our DKMS package (`atl1c-ccr2004fix`).

### 2. skb_over_panic on oversized RX frames (stock driver)

RouterOS defaults to an l2mtu of **1600** on this card; a host at MTU 1500
allocates ~1522-byte skbs. A 1600-byte frame → `skb_put()` past tailroom
→ panic:

```
skb_over_panic: ... put:1600, head:..., tail:..., end:...
```

**Fix** (the patch in `driver/patches/`, shipped as DKMS
atl1c-ccr2004fix/1.1):

- `atl1c_set_rxbufsize()`: allocate
  `roundup(mtu + ETH_HLEN + VLAN_HLEN + ETH_FCS_LEN + NET_IP_ALIGN, 8)`
- `atl1c_clean_rx()`: validate `length` against `skb_tailroom(skb)` (and a
  minimum of `ETH_HLEN + ETH_FCS_LEN`) **before** `skb_put()`; oversized or
  corrupt frames are dropped and counted in `rx_length_errors`/`rx_dropped`
  instead of panicking the host
- `atl1c_change_mtu()`: enforce min/max MTU bounds; apply MTU changes
  requested while the interface is down (previously silently discarded)
- `netdev->min_mtu = ETH_MIN_MTU` in `atl1c_set_max_mtu()`

Verified in production: MTU 1600 on nic0+vmbr0, 1600-byte pings
end-to-end, zero panics, zero drops. Disabling TSO/GRO is no longer
needed.

### 3. Silent death without logs (residual — card-side)

With both driver fixes active, a card reboot **still** takes the host
down, but with no soft lockup and no panic in the logs. From the journal:

```
00:08:18  atl1c 0000:01:00.0: nic0 NIC Link is Down
00:08:19  DMAR: DRHD: handling fault status reg 2
00:08:19  DMAR: [DMA Write NO_PASID] Request device [01:00.0]
           fault addr 0xff3a6000 [fault reason 0x71]
           SM: Present bit in first-level paging entry is clear
           ... (no further kernel lines: the journal dies here)
```

**Interpretation**: during its own reset the card performs DMA writes to
bogus addresses (0xff3a6000, and in a second event 0xffa9e000/0xff9b6000/
0xffa9f000 — always page 0xff....000). The IOMMU blocks them (fault reason
0x71), but the fault storm wedges the DMAR: **every device loses DMA**,
including NICs unrelated to the card (the onboard 10GbE stops responding),
while the kernel stays alive (AMT KVM console usable, `reboot` from console
works).

## Experimental evidence: tested sequences

| # | Sequence | Outcome |
|---|----------|---------|
| 1 | `modprobe -r atl1c` with the driver active (card healthy) | **Instant host wedge** |
| 2 | `echo remove` of the PCI functions with the driver active (nic0 an active bridge port, link up) | **Instant host wedge** |
| 3 | Quiesce the driver (`ip link set nic0 nomaster` + down on nic0/1/2/5) → `echo remove` 01:00.{0..3} → card reboot via management network | **Kernel alive and healthy** throughout the card reboot (clean shutdown visible in the journal) |
| 4 | As 3, waited for the card boot → `echo 1 > /sys/bus/pci/rescan` | **The card does NOT re-enumerate**; DMAR fault storm at teardown; DMA of every NIC wedged until the host is rebooted |

Conclusions:

- Teardown/remove of atl1c **with the driver active** is lethal (wedge),
  but with a quiescent driver it is clean → a safe host-side procedure
  exists (see `scripts/ccr-safe-reboot`).
- After its own reboot the CCR2004 **does not come back on the PCIe bus**:
  a host power cycle is required (confirms the boot-block report by Eki99
  and the need for the card-side fix "probably under NDA" mentioned by
  gajdipajti in the forum thread).
- The DMA fault storm at reset is the mechanism that also kills NICs
  outside the card path: it is the DMAR/IOMMU that wedges, not the
  individual drivers.

## Safe procedure to reboot/upgrade the card (host survives)

Script `/usr/local/bin/ccr-safe-reboot` on the PVE host (step-by-step
logging to `/var/log/ccr-safe-reboot.log`):

```
1. route to the management network via an independent interface (onboard 10GbE)
2. quiesce atl1c: ip link set nic0 nomaster; nic0/1/2/5 down
3. echo 1 > /sys/bus/pci/devices/0000:01:00.{0..3}/remove
4. ssh admin@<card> "/system reboot"      # via management network
5. wait 150s
6. echo 1 > /sys/bus/pci/rescan           # NB: currently does NOT re-enumerate
7. ip link set nic0 mtu 1600 up; ip link set nic0 master vmbr0
```

**Verification status**: steps 1-5 verified working (kernel alive);
step 6 fails with the card in post-reboot state (does not re-enumerate) —
the host survives regardless and needs a warm reboot to get the card back.

Practical note: after a "soft" crash (type 3) the AMT KVM console still
works and rebooting from the console is possible — ~5 minute recovery
instead of a physical power cycle.

## Final working config on PVE

```
# /etc/network/interfaces (vmbr0)
auto vmbr0
iface vmbr0 inet static
        address 192.168.97.84/24
        gateway 192.168.97.1
        mtu 1600
        bridge-ports nic0
        bridge-stp off
        bridge-fd 0

# /etc/network/interfaces.d/nic3 (out-of-band 10GbE)
auto nic3
iface nic3 inet dhcp
```

- DKMS: `atl1c-ccr2004fix/1.1` (tpd_cons + RX bounds fixes),
  `r8127/11.0.15.00`
- Host MTU = RouterOS l2mtu (1600) → no more oversized RX frames
- **Operational rule**: never `modprobe -r atl1c` and never remove the PCI
  functions with the driver active; upgrade the card only through the safe
  procedure, planning a subsequent host reboot.

## Asks for MikroTik (ticket SUP-223678 / forum thread)

1. The card reset issues out-of-range DMA writes (IOMMU fault reason 0x71,
   addr 0xff...000): firmware needs fixing or the card side must quiesce
   its DMA engines on reset.
2. After a reboot the PCI function does not re-enumerate on rescan: we need
   specifics on which PCIe event the card generates at reset (FLR? surprise
   removal? lost config space?).
3. The card-side driver (mentioned as "under NDA") should handle reset
   without spewing DMA onto the bus.

## References

- MikroTik forum thread: "CCR2004-1G-2XS-PCIe: Impossible to update
  RouterOS without crashing Proxmox/Linux Host"
- Kernel commit: 36c2009d90f2 (tpd_cons fix, Gajdos Tamás)
- skb_over_panic analysis: jayme.ca (jaymemaurice on the thread)
- Full atl1c patch (format-patch with Signed-off-by): `driver/patches/`
