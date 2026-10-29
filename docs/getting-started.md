# Getting started with `ccr-linksafe-reboot`

This guide covers the first use of
`scripts/ccr-linksafe-reboot.ver.2.3.2.fish`: installation, host discovery,
configuration, SSH authentication, a dry run, and the first real run.

The script reboots a MikroTik **CCR2004-1G-2XS-PCIe** while isolating its PCIe
link from the Linux/Proxmox VE host. It can also upgrade RouterOS and the
RouterBOARD firmware.

> **Plan for host downtime.** This procedure removes the card's PCI functions
> and always ends with a warm reboot of the host. With `--auto`, the script
> reboots the host itself; without it, you must do so when prompted. Stop or
> migrate VMs and containers first, and make sure you have out-of-band or
> physical access before starting.

## 1. Requirements

Run everything below as **root on the Proxmox VE/Linux host containing the
card**, not on the MikroTik card itself.

You need:

- the CCR2004-1G-2XS-PCIe already visible on the PCI bus;
- a control/management NIC that **does not belong to the card** and does not
  depend on it for its return path;
- an SSH session through that control NIC, or a local/out-of-band console;
- an SSH key from root on the host to a RouterOS user with sufficient rights
  for reboot, package update, and RouterBOARD firmware operations;
- out-of-band recovery (for example Intel AMT) or physical access;
- for `--upgrade`, Internet access and working DNS on the card.

For the host driver installation and MTU requirements, see the
[README](../README.md#quick-start). This guide only covers the linksafe script.

## 2. Install the script

On a Debian-based Proxmox VE host:

```bash
apt update
apt install -y fish pciutils iproute2 openssh-client git

git clone https://github.com/rimpianto/mikrotik.CCR2004-1G-2XS-PCIe.git /root/ccr2004pcie
cd /root/ccr2004pcie
chmod 755 scripts/ccr-linksafe-reboot.ver.2.3.2.fish
```

The script uses `setpci`, `ip`, `ssh`, `ping`, `timeout`, `awk`, and `seq`, and
must run through its fish shebang. Launch it directly as shown below; do not
run it with `bash`.

## 3. Discover the host-specific values

The built-in values are placeholders. Do not run the real procedure until
every value in your configuration matches the host.

These read-only commands help collect them:

```bash
# Network interfaces, addresses, routes, and bridge membership
ip -br link
ip -br addr
ip -4 route show
bridge link

# The four Atheros AR8151 functions and the PCI topology
lspci -nn -d 1969:1083
lspci -t

# Map one host interface back to its PCI function; repeat as needed
readlink -f /sys/class/net/<interface>/device
```

Use the results to fill in:

| Variable | What to enter |
|---|---|
| `CARD_IP` | RouterOS management address of the card |
| `CARD_USER` | RouterOS SSH user |
| `CTRL_IF` | Independent host NIC used to reach the host during the procedure |
| `GW` | Gateway reachable through `CTRL_IF`; leave empty to leave the default route unchanged |
| `ROOTPORT` | Root port above the card, as shown by `lspci -t` (for example `00:06.0`) |
| `CARDPCI` | First card function without the final `.0`, including the PCI domain (for example `0000:01:00`) |
| `BRIDGE` | Linux bridge normally containing the card port |
| `BRIDGE_PORT` | Card interface attached to that bridge |
| `CARD_IFS` | All host interfaces belonging to the card |
| `MTU` | Value matching RouterOS `l2mtu`; never configure a lower value |
| `LOG` | Append-only log path; the default is suitable for most hosts |

The address formats matter: `ROOTPORT=00:06.0` and `CARDPCI=0000:01:00` are
**examples**, not values to copy blindly.

## 4. Create the configuration file

The script looks for `ccr-linksafe.conf` next to itself first, then in
`/etc/ccr-linksafe.conf`. Keep the configuration beside the script:

```bash
cd /root/ccr2004pcie
install -m 600 examples/ccr-linksafe.conf.example scripts/ccr-linksafe.conf
vi scripts/ccr-linksafe.conf
```

A completed file has this shape. Replace every example value with the values
found on your host:

```bash
CARD_IP=192.0.2.10
CARD_USER=ccr-admin
CTRL_IF=mgmt0
GW=198.51.100.1
ROOTPORT=00:06.0
CARDPCI=0000:01:00
BRIDGE=vmbr0
BRIDGE_PORT=nic0
CARD_IFS=nic0 nic1 nic2 nic3
MTU=1600
LOG=/var/log/ccr-linksafe-reboot.log
```

`GW=` empty is a deliberate setting: the script then does not change the
default route. Use it when the card itself is the site's gateway and there is
no independent gateway to move the route to.

Configuration precedence is:

```text
command line (--card-ip, --gw) > environment > config file > built-in defaults
```

> **v2.3.2 limitation:** the management network used during route migration is
> `CARD_MGT_NET=192.0.2.0/24` in the script. If `CARD_IP` is on another subnet
> and `GW` is non-empty, review and adjust that value before the real run.

If RouterOS SSH uses a non-default port, configure it in root's
`/root/.ssh/config`; there is no SSH-port option in the script. See the
[full manual](ccr-linksafe-reboot.md#3b-configuration-file-v230) for an example.

## 5. Verify SSH authentication

The normal authentication path is key-only and non-interactive. Test it with
the same user and address configured in `ccr-linksafe.conf`:

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  ccr-admin@192.0.2.10 ":put ready"
```

The command must print:

```text
ready
```

If no key is installed yet, create one if needed and import the public key into
RouterOS. Replace the example user, address, and key path with your own:

```bash
# Do not overwrite an existing key.
test -f /root/.ssh/id_ed25519 || \
  ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519

scp /root/.ssh/id_ed25519.pub ccr-admin@192.0.2.10:key.pub
ssh ccr-admin@192.0.2.10 \
  "/user ssh-key import public-key-file=key.pub user=ccr-admin"
ssh ccr-admin@192.0.2.10 "/file remove key.pub"

# Repeat the non-interactive test.
ssh -o BatchMode=yes ccr-admin@192.0.2.10 ":put ready"
```

Because the script uses `BatchMode=yes`, it cannot answer a password or key
passphrase prompt. This is especially important for a detached `--auto` run.
Do not put credentials in the script or configuration file.

## 6. Run the preflight in dry-run mode

First check that the script sees the expected options, then simulate the full
procedure:

```bash
cd /root/ccr2004pcie
./scripts/ccr-linksafe-reboot.ver.2.3.2.fish --help
./scripts/ccr-linksafe-reboot.ver.2.3.2.fish --dry
```

Check the startup line carefully: card address, gateway, control interface,
root port, and mode must all be correct. The run must finish with:

```text
SUCCESS (dry-run): logic verified, nothing was changed
```

`--dry` makes no route, PCI, link, card, or shutdown changes. It still performs
read-only hardware/network checks and appends to the log. To include the
upgrade flow in the simulation:

```bash
./scripts/ccr-linksafe-reboot.ver.2.3.2.fish --upgrade --dry
```

Do not continue until the dry run exits successfully and every displayed value
is correct.

## 7. Do the first real run attended

For the first real run, stay connected through the independent control NIC or
an out-of-band console. A plain card reboot is the simplest test:

```bash
cd /root/ccr2004pcie
./scripts/ccr-linksafe-reboot.ver.2.3.2.fish
```

Review the confirmation screen and press Enter only if the values are correct.
In a second session on the control path, follow the log with:

```bash
touch /var/log/ccr-linksafe-reboot.log
tail -n 20 -F /var/log/ccr-linksafe-reboot.log
```

At the end of an interactive run, the script leaves the host running and tells
you to reboot it. This final warm reboot is part of the procedure, not an
optional cleanup:

```bash
reboot
```

Once the plain attended run has been verified, use `--upgrade` for the full
RouterOS plus RouterBOARD firmware cycle:

```bash
./scripts/ccr-linksafe-reboot.ver.2.3.2.fish --upgrade
```

An upgrade can involve two card reboots: one for RouterOS and one for firmware.

## 8. Run an unattended upgrade

Use `--auto` when the SSH session may drop. It arms a 30-minute host-reboot
failsafe and performs the final host reboot automatically.

Confirm the maintenance window and guest shutdown/migration first, then launch
from a bash shell:

```bash
nohup /root/ccr2004pcie/scripts/ccr-linksafe-reboot.ver.2.3.2.fish \
  --upgrade --auto </dev/null >/dev/null 2>&1 & disown
```

Follow the run until the host disconnects for its final reboot:

```bash
touch /var/log/ccr-linksafe-reboot.log
tail -n 0 -F /var/log/ccr-linksafe-reboot.log
```

During the procedure, use the control NIC address to reconnect to the host. An
address routed through the card may be unavailable until the final reboot.

## 9. Verify the result

After the host is back:

```bash
uptime
lspci -nn -d 1969:1083
ip -br addr
bridge link

ssh -o BatchMode=yes ccr-admin@192.0.2.10 \
  "/system package update print; /system routerboard print"
```

Confirm that:

- all four `1969:1083` PCI functions are present;
- the card interfaces and bridge port are back;
- host management and the independent control path are reachable;
- for an upgrade, RouterOS and `current-firmware` show the expected versions;
- the log contains `STEP4 ok` and a final `DONE` line.

Depending on the platform, warnings about the link not retraining or the card
not re-enumerating before the final host reboot can be expected. Do not ignore
`ERROR`, `ABORT`, or `reboot NOT confirmed` messages; keep the log for
troubleshooting.

## 10. If preflight fails

Common failures before the card reset are deliberate safety stops:

| Exit code | Meaning | First check |
|---|---|---|
| 1 | Card unreachable | `CARD_IP`, management routing, and whether the card answers ping |
| 79 | Control NIC missing or down | `CTRL_IF`, cabling, and `ip -br link` |
| 80 | Root port cannot be read | `ROOTPORT` and `lspci -t` |
| 81 | Gateway unreachable through the control NIC | `GW` and the independent network path |
| 82 | SSH client route would not use the control NIC | Return routing; do not bypass this check |
| 83 | No terminal for confirmation | Run attended on a TTY or deliberately use `--auto` |

If the script aborts after quiescing the card, a host reboot may still be
required to restore the bridge and card interfaces. With `--auto`, a hang is
covered by the 30-minute failsafe; otherwise use out-of-band or physical
recovery if the host becomes unreachable.

For the complete option list, exit codes, log reference, and recovery details,
see [the full manual](ccr-linksafe-reboot.md). A successful upgrade transcript
is available in
[`logs/linksafe-upgrade-2026-10-22.log`](../logs/linksafe-upgrade-2026-10-22.log).
