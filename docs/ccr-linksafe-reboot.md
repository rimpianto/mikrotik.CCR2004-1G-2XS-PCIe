# ccr-linksafe-reboot.fish v2.2.1 — manual

Reboot and upgrade the **MikroTik CCR2004-1G-2XS-PCIe** inside a **Proxmox VE** host
with the **PCIe link disabled** for the whole duration of the card reset. This is the
fish implementation of the validated bash v1.7 procedure, with the fixes that came out
of reviewing the v2.1.0 rewrite.

> Repository: [rimpianto/mikrotik.CCR2004-1G-2XS-PCIe](https://github.com/rimpianto/mikrotik.CCR2004-1G-2XS-PCIe).
> Host/platform notes: [rimpianto/minisforum.ms-02-ultra](https://github.com/rimpianto/minisforum.ms-02-ultra).

---

## 1. Why it exists

While the CCR2004-PCIe resets (RouterOS reboot, firmware upgrade) it disturbs the
host **PCIe bus**. The disturbance does not travel through the PCI functions: removing
them from the bus is **not enough** — in our tests 1 run out of 2 froze the whole
platform, silently (no kernel log, every NIC dead including ones on other root ports,
only the Intel ME alive).

The disturbance travels on the **physical link**. PCIe provides the remedy:
the **LnkDisable** bit (LnkCtl, bit 4) on the root port. With the link disabled the
card can glitch as much as it wants: nothing is attached to disturb.

```
  CPU ── root port 00:06.0 ═══ LINK ═══ CCR2004 card (4x AR8151)
                             ↑
                LnkDisable=1 → link DOWN while the card resets
```

Accepted, verified consequence: the Intel root port **does not retrain the link at
runtime**, and the host DMA engine stays wedged. The procedure therefore **always**
ends with a **warm reboot of the host** (planned, not an emergency).

---

## 2. What it does, step by step

Nothing is touched until the whole preflight is green.

### Preflight
- must run as root; checks for `setpci`, `ip`, `ssh`, `ping`, `timeout`, `awk`, `seq`;
- the control NIC (`CTRL_IF`, default `nic3`) must exist **and have a link**
  (`operstate=up`): it is the return path once the card's NICs go down;
- the root port must answer `setpci -s <ROOTPORT> CAP_EXP+10.w`;
- the card must be reachable **on the current path** before anything is changed.

### PHASE A — `--upgrade` only
The RouterOS package is downloaded **while the link is still up**, i.e. at zero risk:

1. reads `/system package update print` **first**: if a `Downloaded, please reboot` is
   already there it keeps it (re-running `check-for-updates` cancels a staged download);
2. otherwise runs `check-for-updates` and **polls** until the async status settles,
   then compares installed/latest;
3. if a newer version exists, downloads it and polls until `Downloaded, please reboot`;
4. if the download does not complete, **aborts without touching anything**.

### STEP 1 — control path and failsafe
- verifies the gateway is reachable **through** `CTRL_IF` (`ping -I <CTRL_IF> <GW>`);
  if not, it stops: moving the default route onto a NIC with no path is an instant lockout;
- saves the current default route and the MGT route (`192.0.2.0/24`), then moves
  both onto `CTRL_IF`;
- adds a host route to the SSH client (`$SSH_CLIENT`) through `CTRL_IF`;
- verifies with `ip route get <client>` that the session really leaves via `CTRL_IF`;
- re-checks the card on the new path;
- **with `--auto` only**: arms `shutdown -r +30` as a failsafe. If anything hangs
  half-way, the host comes back by itself. The failsafe is cancelled on completion
  (success or abort).

### STEP 2 — quiesce the driver
Detaches `nic0` from the bridge and sets **DOWN** every interface of the card
(`nic0 nic1 nic2 nic5`). The `atl1c` driver stays loaded but idle.
This step is mandatory: removing PCI functions with an active driver = instant wedge.

### STEP 3 — remove the PCI functions
`echo 1 > /sys/bus/pci/devices/0000:01:00.N/remove` for N=0..3. Functions already
absent are **logged**, not silently skipped.

### STEP 4 — the key step: link down (+ rollback)
```
LnkCtl  = setpci -s 00:06.0 CAP_EXP+10.w      # e.g. 0c40
new     = LnkCtl | 0x0010                     # bit 4 = LnkDisable
LnkSta  = setpci -s 00:06.0 CAP_EXP+12.w
DLActive= LnkSta & 0x4000                     # bit 13
```
If **DLActive stays 1** the bit did not take: the script restores LnkCtl, rescans,
cancels the failsafe and **exits 2 without rebooting the card**. An aborted procedure
is better than a frozen host.

### STEP 5 — card reboot (+ confirmation)
With `--upgrade` and a staged package: `/system package update install`; otherwise
`/system reboot`.

The SSH exit code is **not** proof: `ssh` also returns 255 for a failed login or an
unreachable host. So after sending the command the script verifies that the card
**stops answering ping** within 60 s. If it keeps answering it logs
`reboot NOT confirmed` and continues: at that point the PCI functions are already
removed, so the host needs its warm reboot regardless.

### STEP 6 — wait for the boot
ICMP polling; when the card answers, it **also probes SSH** (`:put ready`) because ping
returns ~10 s before sshd accepts commands. Timeout 300 s.

### STEP 5b/6b — `--upgrade` only: firmware
`/system routerboard upgrade` → if it answers `please reboot`, a second card reboot and
a wait of up to 480 s (post-firmware boot is slower). Then the installed versions are
printed into the log (`package update print`, `routerboard print`).

> Note: the RouterBOARD firmware ships **with the RouterOS package**, and this step runs
> **after** the package install. If the new release carries a new routerboot,
> `current-firmware` and `upgrade-firmware` will differ at that point and the second
> reboot **does** happen. Reading those two fields *before* the install says nothing:
> they describe the firmware bundled with the currently installed RouterOS (on this card
> `current-firmware: 7.24.4` with RouterOS 7.24.4). A RouterOS upgrade therefore normally
> means **two** card reboots.

### STEP 7 — link back up
Restores the **original** LnkCtl value and waits up to 60 s for the retrain.
On this firmware the retrain **does not happen**: the WARN is expected, not an error.

### STEP 8 — rescan
`echo 1 > /sys/bus/pci/rescan`, two attempts 30 s apart. On this platform the card
**does not re-enumerate** without a power cycle: "not re-enumerated (expected)" is the
norm, and the final warm reboot is what brings it back on the bus.

### STEP 9 — re-attach
If `nic0` exists: MTU (`1600`), `up`, `master vmbr0`. If it does not exist the log says
so explicitly instead of claiming a false success.

### End
- `--auto`: cancels the failsafe and issues `shutdown -r now` ("the host returns by itself");
- otherwise: leaves the host alive and prints `run 'reboot' now`.

> **Routes stay on `CTRL_IF` on purpose** when the procedure completes: `vmbr0` has no
> ports until the reboot, so restoring the default route onto `vmbr0` would cut the only
> management path. On abort paths **before** the quiesce the routes are restored to
> their original values.

---

## 3. Options

| Option | Effect |
|---|---|
| *(none)* | plain card reboot; asks for confirmation on a TTY; does **not** reboot the host by itself |
| `--dry` | simulate everything: no route, link, PCI or shutdown change; `--upgrade` makes no card calls either |
| `--auto` | unattended: `+30 min` failsafe armed at STEP 1, final host reboot issued by the script, failsafe cancelled on success |
| `--upgrade` | full RouterOS + firmware cycle (2 card reboots, PHASE A included) |
| `--card-ip <IP>` | override the card management IP |
| `--gw <IP>` | override the data-LAN gateway |
| `-h`, `--help` | usage plus detected values, exit 0 |

Typical combinations:

```sh
# lab, watching the log
./scripts/ccr-linksafe-reboot.ver.2.2.1.fish

# lab, full RouterOS + firmware cycle
./scripts/ccr-linksafe-reboot.ver.2.2.1.fish --upgrade

# remote / WAN: launch, disconnect, everything comes back by itself
nohup ./scripts/ccr-linksafe-reboot.ver.2.2.1.fish --upgrade --auto </dev/null >/dev/null 2>&1 & disown
exit
```

---

## 4. Recommended remote run

The procedure takes the host's management bridge down; a plain interactive run is a
child of your SSH session and can be killed by SIGHUP if the connection drops half-way.
For any run where you may be disconnected, use `--auto` and detach it:

```sh
# 1. launch it detached, so it survives the ssh session going away
nohup /root/ccr-linksafe-reboot.ver.2.2.1.fish --upgrade --auto </dev/null >/dev/null 2>&1 & disown

# 2. follow the same run in the foreground: every step, live, until the host reboots
touch /var/log/ccr-linksafe-reboot.log
tail -n 0 -F /var/log/ccr-linksafe-reboot.log
```

`-F` (capital) keeps retrying if the file does not exist yet: the script creates it with
`tee -a` at the first line, and a plain `-f` would exit with "no files remaining" if you
start the tail first (or right after deleting the log). `-n 0` shows only the new lines
(use `-n 20` for some context). When the host reboots the tail dies with
the session: that is the end of the procedure, and the log stays on disk for the
post-mortem.

What happens then (≈8-12 minutes with both card reboots, no interaction):

1. PHASE A downloads the package with the link still up;
2. the script arms the +30 min failsafe and takes the host's bridge down;
3. the card is updated and rebooted with the PCIe link disabled (twice, if the new
   release ships a new routerboot);
4. the link is restored, then the script **reboots the host itself** and cancels the failsafe;
5. the host comes back on its normal management address; the log holds the `VERIFY:` block.

While the procedure runs the host is reachable on the **control NIC** only, e.g.
`192.168.97.85` (nic3, 10GbE). The normal management address (on `vmbr0`, over one of
the card's ports) is **not** reachable until the final reboot.

If the host is completely unreachable, the out-of-band path is Intel AMT
(`192.0.2.153`, WS-Man 16993 / `amt-power cycle`, ~45 s), not the card's management
address.

---

## 5. Environment variables

Every value has a default for this host and can be overridden without editing the code.

| Variable | Default | Meaning |
|---|---|---|
| `CARD_IP` | `192.0.2.148` | card management IP (ether1, OOB LAN) |
| `CARD_USER` | `admin` | RouterOS user (needs ssh + reboot + update rights) |
| `PASSCMD` | *(empty)* | command that **prints** the password (e.g. `cat /root/.ccrpass`). Empty = ssh key |
| `CTRL_IF` | `nic3` | host NIC used as control path — must **not** belong to the card |
| `ROOTPORT` | `00:06.0` | PCI address of the root port above the card (`lspci -t`) |
| `CARDPCI` | `0000:01:00` | PCI prefix of the card's 4 functions |
| `BRIDGE` | `vmbr0` | bridge the main card port is attached to |
| `BRIDGE_PORT` | `nic0` | card port attached to the bridge |
| `CARD_IFS` | `nic0 nic1 nic2 nic5` | **all** card interfaces |
| `MTU` | `1600` | MTU to restore (= RouterOS l2mtu) |
| `LOG` | `/var/log/ccr-linksafe-reboot.log` | log file (same name as v1.7) |

On another machine:

```sh
CARD_IP=10.0.0.5 CTRL_IF=ens18 ROOTPORT=00:1c.0 ./scripts/ccr-linksafe-reboot.ver.2.2.1.fish --dry
```

---

## 6. Authentication: SSH key

The script **contains no credentials**. It uses the host's SSH key towards the card with
`BatchMode=yes` (no prompt, no password on disk).

Verify once, before the first run:

```sh
ssh -o BatchMode=yes -o StrictHostKeyChecking=no admin@192.0.2.148 ":put ready"
# must print: ready
```

If it does not work, install the key:

```sh
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519        # if missing
scp /root/.ssh/id_ed25519.pub admin@192.0.2.148:key.pub
ssh admin@192.0.2.148 "/user ssh-key import public-key-file=key.pub user=admin"
ssh admin@192.0.2.148 "/file remove key.pub"
```

> RouterOS 7.24: importing a key switches the default to
> `password-authentication=yes-if-no-key` — the password stops working for that user.
> If you also need the password (WebFig, other clients), set
> `/ip ssh set password-authentication=yes`.

If a password is really unavoidable, **do not put it in the script**: keep it in a file
outside the repo, readable by root only, and use `PASSCMD="cat /root/.ccrpass"`.
A password committed to a public repo stays public even after you delete the line:
git history keeps the commit.

---

## 7. Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | completed (or dry-run) | with `--auto` the host is already rebooting |
| 1 | card unreachable before any change, or after the route change | check network/MGT; **nothing was touched** (first case) |
| 2 | STEP 4: the link did not go down, rollback done, card **not** rebooted | investigate the root port; the host still needs a reboot to restore `vmbr0` |
| 3 | STEP 5b: firmware command failed | check SSH/permissions on the card |
| 64 | unknown option | `--help` |
| 77 | not root | run as root |
| 78 | missing command | install `pciutils`/`iproute2`/`openssh-client` |
| 79 | `CTRL_IF` missing or without link | fix the control path |
| 80 | `setpci` cannot read the root port | check `ROOTPORT` |
| 81 | gateway not reachable via `CTRL_IF` | fix `--gw` or the cabling |
| 82 | the client route does not leave via `CTRL_IF` | do not proceed: it would be a lockout |
| 83 | no TTY for the confirmation | use `--auto` (or run from a terminal) |

Every abort goes through a cleanup function: link restored (if it had been disabled),
routes put back (if the quiesce has not happened yet), failsafe cancelled.

---

## 8. Reading the log

Every line is `HH:MM:SS [v2.2.1] message` and is appended to `$LOG`.

| Line | Meaning |
|---|---|
| `Preflight: LnkCtl(00:06.0) = 0x0c40` | the root port answers; expected value on this machine |
| `STEP1 ok: client route via nic3 verified` | the SSH session leaves through the control NIC |
| `STEP1-failsafe: +30 min host reboot armed` | parachute open (`--auto` only) |
| `STEP2 ok: nic0 detached from vmbr0...` | driver quiesced |
| `STEP3: function ... removed / already absent` | PCI functions off the bus |
| `STEP4 ok: PCIe link DISABLED (DLActive=0)` | **isolation verified** |
| `STEP5 ok: card stopped answering — reboot confirmed` | the card really went down |
| `STEP5 ERROR: card still answering after 60 s — reboot NOT confirmed` | the reboot did not start (auth? IP?) |
| `STEP6 ok: card back up` | the card is back |
| `STEP7 WARN: link still down after 60 s — expected` | known limit, the warm reboot closes it |
| `STEP8: card not re-enumerated (expected...)` | known limit, same |
| `STEP9: nic0 absent — nothing to re-attach` | expected before the reboot |
| `DONE (AUTO): final warm reboot NOW` | the host reboots by itself |
| `DONE: ... Run 'reboot' now` | interactive run: the reboot is yours |

STEP 7/8 WARNs **are not errors**: they are the platform behaviour.

---

## 9. Prerequisites

- root on the host; `pciutils`, `iproute2`, `openssh-client`, `fish`;
- a working SSH key host → card (`:put ready`);
- a control NIC that does **not** belong to the card, with a link (here `nic3`, 10GbE);
- card MGT reachable independently of the host;
- for `--upgrade`: the card needs internet access and working DNS (it downloads itself);
- an out-of-band recovery path if the host is unattended: AMT (`amt-power cycle`, ~45 s)
  or physical access. With `--auto` the +30 min failsafe covers the case where the
  script itself hangs.

First use on a new machine: `--dry`, then a run without `--auto` while watching the log.

---

## 10. After the run

```sh
uptime                                  # is the host back?
lspci -nn | grep -i 1969:1083           # the card's 4 AR8151 functions
ip -br addr show vmbr0                  # management IP
ip -br addr show nic3                   # control path
ssh -o BatchMode=yes admin@192.0.2.148 "/system package update print; /system routerboard print"
```

After `--upgrade` the log also contains the `VERIFY:` block with the versions.

---

## 11. Recovery

| Situation | Remedy |
|---|---|
| the script hangs after the quiesce, `--auto` | the `+30 min` failsafe reboots the host by itself |
| the script hangs after the quiesce, interactive | `amt-power cycle` from another machine, or a physical reboot |
| STEP 4 cannot bring the link down | the script rolls back; the host still needs a reboot to restore `vmbr0` |
| the card does not come back | AMT KVM/SOL console; the card is independent of the host |

---

## 12. Known limits

- the link does **not** retrain at runtime: the final warm reboot is part of the procedure;
- the card does **not** re-enumerate while the host stays up: a reboot is required;
- AMT KVM needs an HDMI display (dummy plug) attached, otherwise the video session does
  not start; SOL and power work regardless;
- `--upgrade` applies **one** RouterOS package per cycle (that is RouterOS' own flow:
  install → reboot → firmware → reboot).

---

## 13. Differences from previous versions

| Aspect | v1.7 (bash) | v2.1.0 (fish) | **v2.2.1 (fish)** |
|---|---|---|---|
| Password | via `PASSCMD`, never hardcoded | **hardcoded** | **none**, ssh key only |
| Failsafe | +30 min at STEP 1 | +4 min at STEP 5 | +30 min at STEP 1 |
| Card reboot confirmation | exit code | always "expected" | ping stops answering + exit code |
| `--upgrade` | yes | **no** | yes |
| Route rollback | no | no | yes (pre-quiesce only) |
| Return path verification | partial | no | gateway ping + `ip route get` |
| Log | `/var/log/ccr-linksafe-reboot.log` | different name | same as v1.7 |
| `--dry` | no | yes (not total) | yes, no change at all |

### Changes in v2.2.1

The first real `--upgrade` run exposed two bugs in the version/firmware detection,
both fixed here:

- **RouterOS values are read with `:put [/system package update get <prop>]`** instead of
  parsing the `print` output. The console wraps long values, and the old `awk` read
  `stablemode` as the version — so PHASE A concluded "already the latest" and the package
  update was silently skipped.
- **Firmware staging is decided by comparing `current-firmware` and `upgrade-firmware`**
  (`:put [/system routerboard get ...]`). The card's `please reboot` message is flushed
  into the *next* console command, so it could not be matched where the script looked.

Also: the wait after `check-for-updates` now requires `latest-version` to be populated
before comparing (an empty field right after the check is not "up to date").

---

## 14. Files

| Path | Role |
|---|---|
| `scripts/ccr-linksafe-reboot` | bash v1.7, original implementation (kept for reference) |
| `scripts/ccr-linksafe-reboot.ver.2.2.1.fish` | this script |
| `docs/ccr-linksafe-reboot.md` | this manual |
| `/var/log/ccr-linksafe-reboot.log` | append-only log, survives reboots |

License: same as the rest of the repository. No credentials in the repository.
