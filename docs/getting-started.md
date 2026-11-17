# Getting started with `ccr-linksafe-reboot` — step by step

Goal of this guide: go from zero to a **safe RouterOS + firmware upgrade** of a
MikroTik CCR2004-1G-2XS-PCIe inside a Proxmox VE / Linux host, in numbered
steps you can copy-paste. Every step shows the expected output and what to do
if it fails.

The script reboots/upgrades the card **with its PCIe link disabled at the root
port**, so the card's reset glitches (bogus DMA, link flaps) cannot reach the
host. Appendix A is a fully worked example for our lab host
(**Minisforum MS-02 Ultra**, `pve-ms02ultra`); if that is your machine, its
configuration file is ready to copy verbatim.

> ⚠️ **Read before starting — non-negotiables**
>
> 1. **The host reboots at the end.** Stop/migrate VMs and containers first.
> 2. You need an **out-of-band path**: Intel AMT console or physical access.
>    If anything goes wrong, that is your way back.
> 3. Run the script from a session that **does not depend on the card**:
>    the local/AMT console, or SSH through the independent control NIC
>    (`CTRL_IF`). Never through a bridge port of the card itself — the
>    preflight rejects it (exit 82), and rightly so.
> 4. **Never reboot/upgrade the card "directly"** (WebFig/WinBox reboot or
>    `/system reboot` while the PCIe link is live): the card's reset wedges
>    the host's IOMMU and takes the whole machine down. This is exactly what
>    this procedure exists to prevent.

---

## Step 1 — Install (or refresh) the kit on the host

All commands run as **root on the host** (console, AMT SOL, or SSH via the
control NIC).

```bash
apt update && apt install -y fish pciutils iproute2 openssh-client git
rm -rf /root/ccr2004pcie
git clone https://github.com/rimpianto/mikrotik.CCR2004-1G-2XS-PCIe.git /root/ccr2004pcie
chmod 755 /root/ccr2004pcie/scripts/ccr-linksafe-reboot.ver.2.3.2.fish
```

Expected: the clone finishes; `fish --version` prints 3.x/4.x.

> Always re-clone before a run: an older copy of the script may lack safety
> fixes (v2.3.0 fixed an SSH/SIGTTIN hang at STEP 5; v2.3.2 ships neutral
> defaults). The script must run through its `#!/usr/bin/env fish` shebang —
> never via `bash`.

**If it fails:** `fish: command not found` → the `apt install` line did not
run. Clone errors → check DNS/Internet on the host.

## Step 2 — Collect your host values

Each value has a one-command discovery method; the last column shows the
answers for the MS-02 Ultra lab host (Appendix A).

| Variable | What it is | Discover with | MS-02 Ultra |
|---|---|---|---|
| `ROOTPORT` | PCIe root port above the card | `lspci -t` — the `00:xx.y` node whose branch contains the card's bus | `00:06.0` |
| `CARDPCI` | card functions prefix, with domain, without the trailing `.N` | `lspci -nn -d 1969:1083` | `0000:01:00` |
| `BRIDGE` / `BRIDGE_PORT` | Linux bridge and the card port attached to it | `bridge link` | `vmbr0` / `nic0` |
| `CARD_IFS` | every host interface belonging to the card | `readlink -f /sys/class/net/<if>/device` per interface | `nic0 nic1 nic2 nic5` |
| `CTRL_IF` | independent NIC used to reach the host during the run | `ip -br addr` — a NIC **not** in `CARD_IFS` | `nic3` (192.168.99.144) |
| `CARD_IP` | RouterOS management address, reachable via `CTRL_IF` | RouterOS config | `192.168.99.148` (DHCP on `ether1`, OOB LAN) |
| `CARD_USER` | RouterOS user with ssh + reboot + update rights | — | `admin` |
| `GW` | gateway reachable **through `CTRL_IF`**, or empty | `ip -4 route show` | empty (see below) |
| `MTU` | must match RouterOS `l2mtu`; never lower | `/system interface print` on the card | `1600` |
| `LOG` | append-only log path | — | default is fine |

`GW=` **empty is a valid, deliberate choice**: the script then never touches
the default route. Use it when no gateway is reachable through `CTRL_IF` (the
MS-02 Ultra case) or when the card itself is the site's gateway.

## Step 3 — Write the configuration file

The script reads `ccr-linksafe.conf` **next to itself** first, then
`/etc/ccr-linksafe.conf`; `$CCR_LINKSAFE_CONF` overrides both. Keep the config
beside the script so the whole kit travels together:

```bash
cat > /root/ccr2004pcie/scripts/ccr-linksafe.conf <<'EOF'
CARD_IP=192.0.2.10
CARD_USER=ccr-admin
CTRL_IF=mgmt0
GW=
ROOTPORT=00:06.0
CARDPCI=0000:01:00
BRIDGE=vmbr0
BRIDGE_PORT=nic0
CARD_IFS=nic0 nic1 nic2 nic3
MTU=1600
LOG=/var/log/ccr-linksafe-reboot.log
EOF
chmod 600 /root/ccr2004pcie/scripts/ccr-linksafe.conf
```

Replace the placeholders with your Step-2 values (**Appendix A has the
ready-made file for the MS-02 Ultra**). Precedence:

```text
command line (--card-ip, --gw) > environment > config file > built-in defaults
```

The built-in defaults are neutral placeholders on purpose: running without a
config file aborts at the preflight instead of touching a real host.

> **v2.3.2 limitation:** the management network used during route migration is
> `CARD_MGT_NET=192.0.2.0/24` in the script. If `CARD_IP` is on another subnet
> **and** `GW` is non-empty, review and adjust that value before the real run.
> With `GW=` empty (MS-02 Ultra) it does not apply.

If RouterOS SSH listens on a non-standard port, map it in root's
`/root/.ssh/config` (the script has no port option):

```
Host 192.0.2.10
     User ccr-admin
     Port 2222
     IdentityFile ~/.ssh/id_ed25519
```

## Step 4 — Verify the three prerequisites (60 seconds)

```bash
# 4a. the card answers ping via the control network
ping -c2 192.0.2.10

# 4b. passwordless SSH host -> card works (the script uses BatchMode=yes:
#     a password prompt would abort it)
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new ccr-admin@192.0.2.10 ":put ready"
#     must print exactly:  ready

# 4c. all four card functions are on the bus
lspci -nn -d 1969:1083
```

**If 4b fails** (permission denied / password prompt): install root's public
key on the card once —

```bash
# Do not overwrite an existing key.
test -f /root/.ssh/id_ed25519 || ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519

scp /root/.ssh/id_ed25519.pub ccr-admin@192.0.2.10:key.pub
ssh ccr-admin@192.0.2.10 "/user ssh-key import public-key-file=key.pub user=ccr-admin"
ssh ccr-admin@192.0.2.10 "/file remove key.pub"

# Repeat the non-interactive test — must print: ready
ssh -o BatchMode=yes ccr-admin@192.0.2.10 ":put ready"
```

Never put credentials in the script or the config file. (If a password is
truly unavoidable, the script accepts `PASSCMD` — a command that *prints* it.)

## Step 5 — Dry run (touches nothing)

```bash
cd /root/ccr2004pcie
./scripts/ccr-linksafe-reboot.ver.2.3.2.fish --dry
```

Check the startup banner **line by line**: card address, gateway, control
interface, root port, mode. The run must end with:

```text
SUCCESS (dry-run): logic verified, nothing was changed
```

`--dry` makes no route, PCI, link, card, or shutdown change; it still runs the
read-only checks and appends to the log. If you will use `--upgrade`, dry-run
that flow too:

```bash
./scripts/ccr-linksafe-reboot.ver.2.3.2.fish --upgrade --dry
```

**Do not continue until the dry run succeeds and every banner value is
correct.** Any preflight abort is a deliberate safety stop — see the exit
code table in Troubleshooting.

## Step 6 — First real run: plain card reboot, attended

Stay on the console or on SSH **via `CTRL_IF`**, and follow the log from a
second session:

```bash
# second session
touch /var/log/ccr-linksafe-reboot.log
tail -n 20 -F /var/log/ccr-linksafe-reboot.log

# first session
cd /root/ccr2004pcie
./scripts/ccr-linksafe-reboot.ver.2.3.2.fish
```

Review the confirmation screen; press Enter only if the values are right.
What happens (STEP numbers appear in the log):

| STEP | Action |
|---|---|
| 1 | verifies the control path, arms a +30 min failsafe host reboot |
| 2 | quiesces the driver: card `nic*` detached from the bridge, down |
| 3 | removes the four PCI functions |
| 4 | **disables the PCIe link on the root port — the key step**: from here the card cannot touch the host |
| 5/6 | reboots the card, waits for boot #1 |
| 5b/6b | (`--upgrade` only) stages the firmware, second card reboot |
| 7 | re-enables the PCIe link |
| 8 | attempts a PCI rescan — *usually fails until the warm reboot; expected and honestly logged* |
| 9 | re-attaches `BRIDGE_PORT` if present (usually absent pre-reboot) |

At the end an interactive run prints:

```text
DONE: host alive, link restored. Run 'reboot' now for the final warm reboot.
```

**The final warm reboot is part of the procedure**, not optional cleanup:

```bash
reboot
```

## Step 7 — Post-run verification (after the host is back)

```bash
uptime
lspci -nn -d 1969:1083                       # four functions present
ip -br addr                                  # bridge IP back
bridge link                                  # card port back in the bridge
ip link show nic0 | grep mtu                 # MTU correct (1600 on the lab host)
ethtool -i nic0 | head -2                    # patched driver loaded (atl1c, version 1.3)
ping -c2 <a host on the bridged LAN>         # data plane through the card
ssh -o BatchMode=yes ccr-admin@192.0.2.10 "/system resource print"
```

Everything above must pass. Also check the log contains `STEP4 ok` and a final
`DONE` line. Warnings about the link not retraining or the card not
re-enumerating **before** the final reboot are expected.

## Step 8 — The real thing: RouterOS + firmware upgrade

Once a plain reboot cycle has been verified end to end:

```bash
cd /root/ccr2004pcie
./scripts/ccr-linksafe-reboot.ver.2.3.2.fish --upgrade
```

`--upgrade` adds **PHASE A** while the link is still up: checks
`/system package update`, downloads and stages the RouterOS package (zero
downtime), then performs up to **two card reboots** (RouterOS install, then
RouterBOARD firmware) inside the link-disabled window. Requirements: working
DNS + Internet **on the card** (via its management port).

Unattended variant — survives a dropped SSH session, arms the +30 min
failsafe, and issues the final host reboot itself:

```bash
nohup /root/ccr2004pcie/scripts/ccr-linksafe-reboot.ver.2.3.2.fish \
  --upgrade --auto </dev/null >/dev/null 2>&1 & disown
tail -n 0 -F /var/log/ccr-linksafe-reboot.log
```

During the run, reconnect to the host via the `CTRL_IF` address; addresses
routed through the card are down until the final reboot.

After an upgrade, re-run **Step 7** and also check:

```bash
ssh -o BatchMode=yes ccr-admin@192.0.2.10 \
  "/system package update print; /system routerboard print"
```

`version` and `current-firmware` must show the new release. A complete
successful transcript (RouterOS 7.24.4 → 7.24.5 + firmware, 117 s):
[`logs/linksafe-upgrade-2026-10-22.log`](../logs/linksafe-upgrade-2026-10-22.log).

---

## Troubleshooting

### Preflight exit codes (nothing was touched yet)

| Exit | Meaning | First check |
|---|---|---|
| 1 | Card unreachable | `CARD_IP`, routing via `CTRL_IF`, card powered |
| 2 | Root-port link control not writable | `ROOTPORT` value, `setpci` present |
| 64 | Bad command line | `--help` |
| 77 | Not root | become root |
| 78 | Missing tool | the command named in the error (`setpci`, `ip`, …) |
| 79 | Control NIC missing/down | `CTRL_IF`, cabling, `ip -br link` |
| 80 | Root port unreadable | `ROOTPORT`, `lspci -t` |
| 81 | Gateway unreachable via control NIC | `GW`; leave `GW=` empty if none exists |
| 82 | This SSH session would die at STEP 2 | reconnect via `CTRL_IF` or the console; do not bypass |
| 83 | No terminal for confirmation | run attended on a TTY, or use `--auto` deliberately |

### Mid-run and post-run

| Symptom | Cause / fix |
|---|---|
| Hangs at STEP 5 | Only with pre-v2.3.0 scripts (SSH stopped by SIGTTIN). Refresh the kit (Step 1). With `--auto`, the +30 min failsafe reboots the host anyway. |
| STEP 8 says rescan failed | **Expected** before the warm reboot. Just `reboot`. |
| After a **plain host reboot** (no linksafe): host shows `nic0` UP but no traffic passes, and the card shows `ether-pcie1` link down | The emulated PCIe link came up asymmetrically — a known behaviour of this card when the host warm-reboots without the card power-cycling. Recovery without rebooting again: the PCI remove+rescan recipe below. |
| Host unreachable on the card-side network during the run | Normal: the card is isolated. Use `CTRL_IF` / AMT. |
| `ERROR`, `ABORT`, `reboot NOT confirmed` in the log | Stop, keep the log, recover via AMT, re-check the config against Step 2. |
| Script aborted after STEP 2 | The card is quiesced: a host reboot restores the bridge and interfaces. |

### Recovery recipe: card link stale after a warm host reboot

Validated on the lab host (2026-11-17): after a plain host reboot the card can
keep its `ether-pcie*` side down while the host shows `nic0` UP + carrier; no
traffic passes. Fix without rebooting anything:

```bash
for f in 0 1 2 3; do
  echo 1 > /sys/bus/pci/devices/0000:01:00.$f/remove
done
sleep 2
echo 1 > /sys/bus/pci/rescan
ifreload -a     # or: ip link set nic0 up && ip link set nic0 master vmbr0
ip -br link     # card interfaces back, bridge port attached
```

(Replace `0000:01:00` with your `CARDPCI`.) The card-side link comes up within
~10 s — verify with `/interface print` on the card (`ether-pcie1` running).

For the complete option list, log reference and recovery details, see
[the full manual](ccr-linksafe-reboot.md).

---

## Appendix A — worked example: Minisforum MS-02 Ultra (`pve-ms02ultra`)

Topology of the lab host this kit was validated on:

```text
CPU ── root port 00:06.0 ═══ PCIe link ═══ CCR2004-1G-2XS-PCIe
                                            ├── ether-pcie1..4  (emulated AR8151 → host nic0/nic1/nic2/nic5)
                                            ├── ether1   → OOB LAN switch, DHCP 192.168.99.148
                                            └── sfp28-1  → site LAN (192.168.97.0/24, l2mtu 1600)
host nic0 (01:00.0) ── bridge port of vmbr0 (192.168.97.84/24, MTU 1600)
host nic3 (Realtek r8127 10G, NOT part of the card) ── OOB LAN switch, DHCP 192.168.99.144
Intel AMT ── OOB LAN switch, 192.168.99.153:16993
```

Ready-made `/root/ccr2004pcie/scripts/ccr-linksafe.conf`:

```bash
CARD_IP=192.168.99.148
CARD_USER=admin
CTRL_IF=nic3
GW=
ROOTPORT=00:06.0
CARDPCI=0000:01:00
BRIDGE=vmbr0
BRIDGE_PORT=nic0
CARD_IFS=nic0 nic1 nic2 nic5
MTU=1600
LOG=/var/log/ccr-linksafe-reboot.log
```

Host notes:

- the host runs **no VMs/CTs**: nothing to stop or migrate;
- the default route goes via `vmbr0` (site gateway `192.168.97.1`, which is
  **not** the card) — `GW=` stays empty so the script never touches it; the
  operator session runs through `nic3` (192.168.99.144) or the AMT console;
- driver: DKMS `atl1c-ccr2004fix` **1.3** (`driver/atl1c-dkms-1.3/`); after
  every reboot check `ethtool -i nic0` → `version: 1.3`, and MTU 1600 on
  `nic0`/`vmbr0` (`/etc/network/interfaces` already pins it);
- while the procedure runs, the host answers only on `192.168.99.144` (nic3)
  and AMT `192.168.99.153:16993`;
- validated history on this machine: bash v1.7 6/6 runs; fish v2.3.2 full
  upgrade 7.24.4 → 7.24.5 + firmware on 2026-10-22 (117 s, no crash);
  warm-reboot stale-link recovery (PCI remove+rescan) validated 2026-11-17.
