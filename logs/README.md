# Raw evidence logs

Kernel journals and procedure logs captured from the test host
(Minisforum MS-02 Ultra / Proxmox VE 9.2, kernel 7.0.14-19-pve) during
the crash experiments of Sep 26-27, 2026.

| File | Content |
|------|---------|
| `journal-crash-boot.txt` | Kernel journal of the boot in which the card reboot caused the silent DMAR-wedge crash (DMA write faults at 0xff... addresses, no soft lockup, no panic). See the DMAR entries around 00:32. |
| `journal-softlockup-boot.txt` | Kernel journal of an earlier boot cycle from the same experiment session (context: stock-vs-patched driver comparison). |
| `ccr-safe-reboot.log` | Step-by-step log of the `ccr-safe-reboot` procedure — both executions: the interrupted one (00:28) and the complete one (00:32) showing remove OK, card reboot ordered, rescan failing to re-enumerate. |

Key excerpts are quoted in `docs/CCR2004-PCIe-Report.md`.
