# MikroTik CCR2004-1G-2XS-PCIe — survival kit for Proxmox VE / Linux hosts

Everything we learned (the hard way) about running the MikroTik
**CCR2004-1G-2XS-PCIe** inside a Proxmox VE host - in our case a Minisforum
MS-02 Ultra, the same combo discussed in the MikroTik forum thread
*"CCR2004-1G-2XS-PCIe: Impossible to update RouterOS without crashing
Proxmox/Linux Host"*.

The card's SoC exposes four **virtual** PCIe Ethernet functions as
Qualcomm Atheros AR8151 v2.0 `[1969:1083]`, driven by Linux `atl1c`.
These are emulated interfaces, not four discrete AR8151 controllers.

## Reboot / upgrade the card without killing the host

`scripts/ccr-linksafe-reboot.ver.2.3.2.fish` (fish, **current**) implements the validated
link-disable procedure: it quiesces `atl1c`, removes the PCI functions, disables the
**PCIe link on the root port**, reboots the card (optionally upgrading RouterOS and the
RouterBOARD firmware), then restores the link, rescans and reboots the host. Host
parameters come from a config file (see `examples/ccr-linksafe.conf.example`), the
environment or the command line, in that order. This is the only implementation kept in
the tree: the older **bash v1.7** (validated 6/6) and **fish v2.2.1** were removed in
this release and remain available in the git history (`git show 0c1a939:scripts/...`).

```sh
sudo ./scripts/ccr-linksafe-reboot.ver.2.3.2.fish --dry              # simulate, change nothing
sudo ./scripts/ccr-linksafe-reboot.ver.2.3.2.fish                    # interactive, asks for confirmation
# unattended (survives a dropped ssh session, reboots the host at the end):
nohup ./scripts/ccr-linksafe-reboot.ver.2.3.2.fish --upgrade --auto </dev/null >/dev/null 2>&1 & disown
tail -n 0 -f /var/log/ccr-linksafe-reboot.log     # follow the steps live until the reboot
```

Requirements: root, `fish`, an **ssh key** from the host to the RouterOS user (no
credential is stored in the script) and a management path to the card that does **not**
go through it (e.g. the onboard 10GbE). During the procedure the host is reachable on the
control NIC only; if the host is unreachable, recovery is out-of-band (Intel AMT).
If the **card** loses its management IP instead, its RouterOS console is still reachable
over Layer 2 (no IP needed) with the MAC-Telnet suite:
**[docs/mac-telnet-management.md](docs/mac-telnet-management.md)**.

**First time here?** The **[step-by-step guide](docs/getting-started.md)**
walks you from zero to a completed upgrade: install, one-command discovery of
every host value, configuration, SSH setup, dry run, first attended run,
post-checks and troubleshooting. **Appendix A of the guide is a worked example
for the Minisforum MS-02 Ultra lab host**, with a ready-to-paste configuration
file.

### Configuration file (v2.3.0+)

Host parameters live in a `KEY=VALUE` file, looked up **next to the script
first** (`<script dir>/ccr-linksafe.conf`), then `/etc/ccr-linksafe.conf`;
`CCR_LINKSAFE_CONF=/path/to/file` overrides both. Precedence: command line
(`--card-ip`, `--gw`) > environment > config file > built-in defaults (which
are neutral placeholders — running without a config aborts at the preflight).

```sh
# <script dir>/ccr-linksafe.conf — values below are the MS-02 Ultra lab host
CARD_IP=192.168.99.148      # RouterOS management address (reachable via CTRL_IF)
CARD_USER=admin             # RouterOS user (ssh + reboot + update rights)
CTRL_IF=nic3                # NIC of the management path (must not depend on the card)
GW=                         # gateway reachable via CTRL_IF; EMPTY = do not touch the default route
ROOTPORT=00:06.0            # PCIe root port that hosts the card
CARDPCI=0000:01:00          # card PCI functions prefix (no trailing .N)
BRIDGE=vmbr0                # bridge that carries the LAN
BRIDGE_PORT=nic0            # bridge port towards the card
CARD_IFS=nic0 nic1 nic2 nic5  # every card interface on the host
MTU=1600                    # must match RouterOS l2mtu (never lower)
LOG=/var/log/ccr-linksafe-reboot.log
```

How to discover each value on your own host, the SSH-key setup and the
non-default-port case: **[step-by-step guide, Steps 2-4](docs/getting-started.md)**.
A ready-to-edit template ships as `examples/ccr-linksafe.conf.example`.

A real successful run — RouterOS **7.24.4 → 7.24.5** plus RouterBOARD firmware
**7.24.4 → 7.24.5**, two card resets with the host staying alive — is in
[`logs/linksafe-upgrade-2026-10-22.log`](logs/linksafe-upgrade-2026-10-22.log).

Options, exit codes, log reference and remote-run notes:
**[`docs/ccr-linksafe-reboot.md`](docs/ccr-linksafe-reboot.md)**.

This repository contains:

| Path | What |
|------|------|
| `driver/atl1c-dkms-1.3/` | **Current production DKMS package**: 1.1 + RX shared-info guard against the card's misplaced DMA writes (host-crash mitigation, `rx_shinfo_corrupt` counter) + module metadata (`ethtool -i` version) |
| `driver/atl1c-dkms-1.1/` | Previous DKMS package (superseded by 1.3): patched `atl1c` driver (also carries upstream fix `36c2009d90f2` for the tpd_cons soft-lockup; predates the RX leak v3/v4 work) |
| `driver/patches/` | Original oversized-RX submission and the v3 patch fixing RX error-descriptor buffer leaks |
| `scripts/ccr-linksafe-reboot.ver.2.3.2.fish` | Fish v2.3.2 (**current, only implementation**): link-disable procedure + config file, `ssh -n` fix (SIGTTIN hang), DLActive bit fix |
| `examples/ccr-linksafe.conf.example` | Parameter file for v2.3.0+ (`/etc/ccr-linksafe.conf`) |
| `docs/ccr-linksafe-reboot.md` | Manual (EN) for v2.3.2: options, config file, exit codes, reading the log, remote run |
| `docs/mac-telnet-management.md` | Layer-2 management of the card without any IP: MAC-Telnet suite (`mndp`, `macping`, `mactelnet`) built from source on Debian/PVE, card discovery by MAC, console access — with real lab output |
| `docs/atl1c-upstream-status.md` | Accepted upstream commits, stable-queue state, pending submissions and verification status |
| `docs/atl1c-misplaced-dma-write.md` | The card's misplaced-DMA-write quirk: symptoms, instrumented builds, evidence, hypothesis testing, mitigation in 1.3 |
| `docs/CCR2004-PCIe-Report.md` | Full technical report: crash analysis, kernel logs, experiment matrix |
| `logs/` | Raw evidence: kernel journals and procedure logs from the crash experiments and the 2026-11 driver campaign |

## The three failure modes (short version)

1. **Soft lockup on card reboot** — the card reports an out-of-range
   `tpd_cons` (0xffff) while resetting; `atl1c_clean_tx()` spins forever.
   Fixed upstream by commit `36c2009d90f2` (included in our DKMS package).
2. **`skb_over_panic` on RX** — RouterOS defaults to `l2mtu 1600`; a host
   at MTU 1500 allocates ~1522-byte skbs; `skb_put()` of a 1600-byte frame
   panics the host. The minimal bounds-check fix is now accepted in
   `netdev/net` as commit `c4ba1716853d`: oversized or corrupt frames are
   dropped and counted instead of panicking. The original broader patch
   remains in `driver/patches/` for reference.
3. **Card-side reset misbehaviour (NOT fixable from Linux)** — around
   resets and the card's spontaneous link-downs the device issues DMA at
   bogus addresses (IOMMU fault reason 0x71, e.g. `0xff3a6000`). The
   September experiments showed VT-d DMAR wedges (every NIC in the host
   loses DMA until reboot) and the card failing to re-enumerate on PCI
   rescan. The November instrumented-driver campaign characterized the
   write side: the card sometimes **misplaces a small frame at a
   128-byte-aligned offset inside a posted RX buffer's own mapping** —
   when the write lands in the skb shared info, the next free crashes
   the host. Analysis and evidence:
   [`docs/atl1c-misplaced-dma-write.md`](docs/atl1c-misplaced-dma-write.md).
   **DKMS package 1.3 mitigates the crash** (corrupt skbs are leaked,
   logged and counted instead of freed). Track with MikroTik
   (SUP-223678).

## Additional atl1c fix: RX error-descriptor buffer leak

A separate issue in the RX error path recycled RFD slots without unmapping
and freeing their buffers. The v3 fix was submitted to netdev on
2026-11-03 and is included verbatim in `driver/patches/`. After a further
Sashiko review, a v4 series (descriptor validation + reset on mismatch,
and serialization of the link-down ring reset against in-flight RX polls)
is prepared and was **validated on this card** in November 2026 through
instrumented test builds: 1.5 M+ descriptors validated with zero
mismatches, zero Oops across 15+ reset cycles. Submission pending.

See **[atl1c upstream patch status](docs/atl1c-upstream-status.md)** for
the submission links, verification details, the stable-queue state of the
accepted oversized-RX fix, and the explicit distinction between accepted
upstream changes and the local DKMS packages.

## Quick start

### Install the patched driver (DKMS)

```sh
sudo dkms add driver/atl1c-dkms-1.3
sudo dkms build atl1c-ccr2004fix/1.3
sudo dkms install atl1c-ccr2004fix/1.3
sudo reboot        # load the new module with a reboot - see warning below
ethtool -i <iface> # must show: version: 1.3
```

> ⚠️ **Never unload/remove `atl1c` while the driver is active**
> (interfaces up, port attached to a bridge): on this hardware it
> wedges the kernel instantly. Load a new build with a **reboot**, and
> keep an out-of-band path (Intel AMT / a NIC on a different PCIe
> device) available. The `ccr-linksafe-reboot` procedure quiesces
> everything for you when the card itself must reboot.
>
> `dkms autoinstall` promotes the **highest** registered version at every
> kernel upgrade: retire old or test versions with
> `sudo dkms remove atl1c-ccr2004fix/<version> --all`.

Then raise the host MTU to match RouterOS `l2mtu` (default 1600):

```sh
ip link set <iface> mtu 1600 up
# and in /etc/network/interfaces for the bridge:
#   mtu 1600
```

## Credits

- **Gajdos Tamás** — upstream `atl1c` tpd_cons fix (`36c2009d90f2`) and the
  PCI remove/rescan recovery procedure this work builds on
- **jaymemaurice** — first public write-up of the `skb_over_panic` issue
- The MikroTik forum thread participants for the shared debugging

## License

GPL-2.0-only for the kernel driver code (as the Linux kernel).
See `LICENSE` (the repository ships GPLv3 for the general material;
driver files retain their original GPL-2.0-only SPDX headers).
