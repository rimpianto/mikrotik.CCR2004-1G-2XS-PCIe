#!/bin/bash
# snapshot-diag.sh — append a snapshot of the atl1c diagnostic counters,
# the nic0 link state and a journal anomaly count to counters.log, and save
# a dmesg tail. Used by every hardware test phase on pve-ms02ultra.
#
# Usage: snapshot-diag.sh <tag>        (e.g. snapshot-diag.sh flapA-1)
# Requires the instrumented DKMS build (0.4.x test packages) with the
# read-only diag_* module parameters.
tag=$1; d=/root/atl1c-045-test; mkdir -p $d
{ echo "=== $tag $(date "+%F %T") ==="
  for p in rx_shinfo_corrupt diag_rrd_oos diag_poll_calls diag_poll_waits \
           diag_poll_max_loops diag_poll_down_skips diag_poll_timeouts; do
    printf "%s=%s\n" "$p" "$(cat /sys/module/atl1c/parameters/$p 2>/dev/null)"
  done
  ip -s link show nic0 | tail -6
  echo "oops/warn/dmar in journal: $(journalctl -k -b --no-pager | grep -ciE "oops|warning|dmar")"
} | tee -a $d/counters.log
dmesg | tail -40 > $d/dmesg-$tag.txt
