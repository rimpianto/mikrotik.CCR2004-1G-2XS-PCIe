# MikroTik CCR2004-1G-2XS-PCIe — survival kit for Proxmox VE / Linux hosts

Everything we learned (the hard way) about running the MikroTik
**CCR2004-1G-2XS-PCIe** (4x Qualcomm Atheros AR8151, driven by the Linux
`atl1c` driver) inside a Proxmox VE host - in our case a Minisforum
MS-02 Ultra, the same combo discussed in the MikroTik forum thread
*"CCR2004-1G-2XS-PCIe: Impossible to update RouterOS without crashing
Proxmox/Linux Host"*.

## Reboot / upgrade the card without killing the host

`scripts/ccr-linksafe-reboot.ver.2.3.1.fish` (fish, **current**) implements the validated
link-disable procedure: it quiesces `atl1c`, removes the PCI functions, disables the
**PCIe link on the root port**, reboots the card (optionally upgrading RouterOS and the
RouterBOARD firmware), then restores the link, rescans and reboots the host. Host
parameters come from a config file (see `examples/ccr-linksafe.conf.example`), the
environment or the command line, in that order. This is the only implementation kept in
the tree: the older **bash v1.7** (validated 6/6) and **fish v2.2.1** were removed in
this release and remain available in the git history (`git show 0c1a939:scripts/...`).

```sh
sudo ./scripts/ccr-linksafe-reboot.ver.2.3.1.fish --dry              # simulate, change nothing
sudo ./scripts/ccr-linksafe-reboot.ver.2.3.1.fish                    # interactive, asks for confirmation
# unattended (survives a dropped ssh session, reboots the host at the end):
nohup ./scripts/ccr-linksafe-reboot.ver.2.3.1.fish --upgrade --auto </dev/null >/dev/null 2>&1 & disown
tail -n 0 -f /var/log/ccr-linksafe-reboot.log     # follow the steps live until the reboot
```

Requirements: root, `fish`, an **ssh key** from the host to the RouterOS user (no
credential is stored in the script) and a management path to the card that does **not**
go through it (e.g. the onboard 10GbE). During the procedure the host is reachable on the
control NIC only; if the host is unreachable, recovery is out-of-band (Intel AMT).

### Configuration file (v2.3.0+)

Host parameters are no longer hardcoded or exported by hand. The script looks for the
file **next to itself first** (`<script dir>/ccr-linksafe.conf`), then
`/etc/ccr-linksafe.conf`; `CCR_LINKSAFE_CONF=/path/to/file` overrides both. Keeping the
file in the same directory as the script means the whole kit travels together
(e.g. `/root/ccr2004pcie/`). Format is `KEY=VALUE`, one per line, `#` for comments, quotes
optional.

```sh
# <script dir>/ccr-linksafe.conf (or /etc/ccr-linksafe.conf)
CARD_IP=192.0.2.10          # management address of the card
CARD_USER=ccr-admin            # RouterOS user
CTRL_IF=mgmt0                  # NIC of the management path (must not depend on the card)
GW=                           # gateway reachable via CTRL_IF; EMPTY = do not touch the default route
ROOTPORT=00:06.0              # root port that hosts the card
CARDPCI=0000:01:00            # card PCI address (first function)
BRIDGE=vmbr0                  # bridge that carries the LAN
BRIDGE_PORT=nic0              # bridge port towards the card
CARD_IFS=nic0 nic1 nic2 nic3  # card interfaces on the host
MTU=1600                      # must match RouterOS l2mtu (never lower)
LOG=/var/log/ccr-linksafe-reboot.log
```

Precedence: command line (`--card-ip`, `--gw`) > environment > config file > built-in
defaults. A variable already present in the environment is never overwritten by the file,
so `CARD_IP=10.0.0.9 ./scripts/ccr-linksafe-reboot.ver.2.3.1.fish --dry` still wins.

Two notes from real hosts:

- **`GW=` empty is meaningful**: the script then leaves the default route alone. Use it
  when the card itself is the gateway of the site and no independent gateway exists.
- the card SSH **port is not a script parameter**. If RouterOS listens on a non-default
  port (e.g. 444), map it in `~/.ssh/config` of the user that runs the script:

```sh
Host 192.0.2.10
     HostName 192.0.2.10
     User ccr-admin
     Port 22
     IdentityFile ~/.ssh/id_ed25519-git
```

A ready-to-edit copy ships as `examples/ccr-linksafe.conf.example`; copy it next to
the script as `ccr-linksafe.conf`.

Options, exit codes, log reference and remote-run notes:
**[`docs/ccr-linksafe-reboot.md`](docs/ccr-linksafe-reboot.md)**.

This repository contains:

| Path | What |
|------|------|
| `driver/patches/` | Kernel patch (`git format-patch`) fixing `skb_over_panic` on oversized RX frames |
| `driver/atl1c-dkms-1.1/` | Full DKMS package: patched `atl1c` driver (also carries upstream fix `36c2009d90f2` for the tpd_cons soft-lockup) |
| `scripts/ccr-linksafe-reboot.ver.2.3.1.fish` | Fish v2.3.0 (**current, only implementation**): link-disable procedure + config file, `ssh -n` fix (SIGTTIN hang), DLActive bit fix |
| `examples/ccr-linksafe.conf.example` | Parameter file for v2.3.0 (`/etc/ccr-linksafe.conf`) |
| `docs/ccr-linksafe-reboot.md` | Manual (EN) for v2.3.0: options, config file, exit codes, reading the log, remote run |
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
> from the bridge first. The `ccr-linksafe-reboot` procedure does this for you.

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
