# Managing the card at Layer 2: MAC-Telnet (`mndp`, `macping`, `mactelnet`)

The RouterOS instance inside the **CCR2004-1G-2XS-PCIe** speaks MikroTik's
**MAC-Telnet** protocol: it periodically broadcasts MNDP discovery frames and
accepts terminal sessions addressed **directly to its MAC address**, with no IP
configuration involved. The [MAC-Telnet client
suite](https://github.com/haakonnessjoen/MAC-Telnet) (`mndp`, `macping`,
`mactelnet`) brings those tools to the Linux host side.

Why this matters for this card:

- **First configuration** — a brand-new (or netboot-reset) card can be given a
  RouterOS console before it has a usable IP at all;
- **Recovery / IP lockout** — if the management address is lost (DHCP change,
  firewall lockout, misconfiguration), the Layer-2 path still works;
- **The card exposes its own MACs on the host interfaces** — the four emulated
  AR8151 functions (`atl1c` on the host: `nic0`, `nic1`, `nic2`, `nic5`)
  inherit the card's MAC block (lab host: card `ether1` =
  `f4:1e:57:31:f8:e5`, host `nic0` = `f4:1e:57:31:f8:e9`), so discovery and
  console sessions run from the host itself and do not depend on the routing
  or the bridge configuration being intact.

> ⚠️ The MAC-Telnet protocol is based on UDP broadcast packets and is **not
> secure** (upstream's own warning). Use it on a trusted management network
> and restrict the RouterOS side under `/tool mac-server`
> (`allowed-interface-list`). All three tools use raw sockets: **run them as
> root**.
>
> These tools apply while the card is **up**. During a `ccr-linksafe-reboot`
> run the card is isolated (PCIe link disabled) or resetting: no L2 traffic
> until the procedure completes.

---

## 1. Installation on Debian / Proxmox VE (build from source)

The package is not available from the standard `apt` repositories on our
Proxmox VE hosts. Build the official sources (validated on the MS-02 Ultra
lab host: **MAC-Telnet 0.6.3**):

```bash
apt-get install -y build-essential automake autoconf autopoint gettext libbsd-dev libssl-dev
git clone https://github.com/haakonnessjoen/MAC-Telnet.git
cd MAC-Telnet
./autogen.sh
./configure --without-mactelnetd   # client tools only; the daemon is not needed
make                               # builds src/mactelnet, src/macping, src/mndp
make install                       # -> /usr/local/bin/{mactelnet,macping,mndp}
```

(Prefer copying by hand: `cp src/mactelnet src/macping src/mndp
/usr/local/bin/`.)

---

## 2. Discover the card: `mndp`

```bash
mndp            # equivalent: mactelnet -l
```

`mndp` passively listens for MNDP discovery broadcasts. RouterOS emits them
about once a minute, so give it up to 60 s. Real output from the lab host —
the card is the `ccr2004PCIe` line (last column: the RouterOS interface the
frame was sent from):

```text
IP              MAC-Address       Identity (platform version hardware) uptime
192.168.99.148  f4:1e:57:31:f8:e5 ccr2004PCIe (MikroTik 7.24.5 (stable) 2026-09-29 14:21:27 CCR2004-1G-2XS-PCIe)  up 0 days 9 hours  CC9C-K6VD ether1
```

That single line gives everything the other two tools need: the **MAC**
(`f4:1e:57:31:f8:e5`), the **identity** (`ccr2004PCIe`), the running
**RouterOS version** and the current **IP** — which may be missing entirely,
and that is exactly when this suite earns its keep.

---

## 3. Check Layer-2 reachability: `macping`

```bash
macping f4:1e:57:31:f8:e5 -c 3
```

Real output from the lab host:

```text
f4:1e:57:31:f8:e5 56 byte, ping time 1.59 ms
f4:1e:57:31:f8:e5 56 byte, ping time 1.48 ms
f4:1e:57:31:f8:e5 56 byte, ping time 1.50 ms

3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 1.48/1.53/1.59 ms
```

Handy in scripts too: `macping <MAC> -c 2 >/dev/null 2>&1 || echo "card not
answering at L2"`.

---

## 4. Open a RouterOS console: `mactelnet`

```bash
mactelnet f4:1e:57:31:f8:e5 -u admin
# the identity works as well (resolved via MNDP):
mactelnet ccr2004PCIe -u admin
```

The tool prompts for the password and drops you into the regular RouterOS CLI
(`[admin@ccr2004PCIe] >`). From there anything you would do over SSH is
available at Layer 2 — e.g. restore the management address (`/ip address
print`, `/ip address add ...`) or inspect the emulated PCIe ports
(`/interface print`: `ether-pcie1..4`).

---

## 5. Lab-host quick reference (MS-02 Ultra)

| Value | What it is |
|---|---|
| `ccr2004PCIe` | RouterOS identity of the card |
| `f4:1e:57:31:f8:e5` | card `ether1` MAC (management, OOB LAN via host `nic3`) |
| `f4:1e:57:31:f8:e9` | host `nic0` (emulated `ether-pcie1`, same MAC block) |
| `192.168.99.148` | card management IP when configured (DHCP on the OOB LAN) |
| `mndp` / `macping` / `mactelnet` | MAC-Telnet 0.6.3 in `/usr/local/bin/` on the host |

Related: the IP-based procedure, prerequisites and recovery recipes in
[getting-started.md](getting-started.md); the safe reboot/upgrade procedure in
[ccr-linksafe-reboot.md](ccr-linksafe-reboot.md).
