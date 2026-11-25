# atl1c hardware test scripts

Scripts used for the hardware validation of the atl1c v5 upstream candidate
(the RX buffer leak fix series and its companion link-down poll-sync patch)
on a MikroTik CCR2004-1G-2XS-PCIe in a Proxmox VE host. Full campaign record:
[`docs/atl1c-hw-test-campaigns.md`](../../docs/atl1c-hw-test-campaigns.md).

They assume the instrumented DKMS test build (0.4.5/0.4.6: production 1.3 +
v5 candidate + read-only `diag_*` module parameters) and the lab topology of
that host: the tested interface is `nic0`, bridged into `vmbr0`, which also
carries the host management IP, and its upstream port is `ether-pcie1` on the
card's own RouterOS.

| script | runs on | purpose |
|---|---|---|
| `snapshot-diag.sh <tag>` | host under test | append diag counters + link state + journal anomaly count to `counters.log`, save a `dmesg` tail; taken before/after every test phase |
| `zero-http-server.py` | a second machine on the LAN | endless HTTP body of zeros (~70+ MB/s measured); the host under test pulls it with `curl` to load the physical RX path |
| `throttle-test.sh` | host under test (root) | exercises the v5 link-down wait: loads RX, finds the NIC's NAPI kthreads by schedstat delta, starves them with `cpu.max` in a threaded cgroup, opens a flap window, restores everything on exit |
| `napi-throttle-vmtest.sh` | any Linux VM | mechanism test for the above (threaded NAPI, kthread→threaded-cgroup move, cpu.max enforcement) without needing the special hardware |

Safety notes:

- On the lab host the tested NIC carries management traffic: while
  `throttle-test.sh` runs, SSH to the host becomes very slow and stalls
  during each link flap. Keep an out-of-band console (Intel AMT / serial)
  open. Sessions survive (TCP rides through ~30 s outages), but do not run
  anything else on that SSH during the window.
- Everything is restored by the scripts' EXIT traps (`threaded=0`, cgroup
  removed, flood killed). If a run is interrupted hard, check:
  `cat /sys/class/net/nic0/threaded`, `ls /sys/fs/cgroup/napi-throttle`.
- Do not hot-reload the NIC driver on this card: after a module reload or a
  warm reboot the PCIe function can come back down and needs a PCI
  remove/rescan (see the getting-started guide's recovery section).
