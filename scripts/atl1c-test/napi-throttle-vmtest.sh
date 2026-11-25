#!/bin/bash
# napi-throttle-vmtest.sh — mechanism test for throttle-test.sh, runnable on
# any Linux box with a spare interface (developed against a Debian VM,
# kernel 6.12). Verifies, without any atl1c hardware:
#   1. threaded NAPI can be enabled and the kthread appears;
#   2. a NAPI kthread CAN be moved into a threaded cgroup (unlike kworkers,
#      which are rejected with EINVAL because of PF_NO_SETAFFINITY);
#   3. cpu.max actually throttles it (schedstat delta collapses,
#      nr_throttled grows);
#   4. restoring cpu.max=max brings it back.
# It also documents what does NOT work: the cgroup-v2 freezer never freezes
# NAPI kthreads (cgroup.events "frozen" stays 0) — see napi-freezer note in
# docs/atl1c-hw-test-campaigns.md.
#
# The VM briefly loses network responsiveness while the throttle is applied
# (its own NAPI thread is the victim); keep the freeze window short.
set -u
IF=$(ip -o link show | awk -F': ' '$2 != "lo" && $2 !~ /veth|docker|br-/ {print $2; exit}')
TGT=192.168.97.115	# any peer that answers ping (adjust)
CG=/sys/fs/cgroup/tst-napi
cpu_ns() { awk '{print $1}' "/proc/$1/schedstat" 2>/dev/null || echo 0; }
nr_thr() { awk '/^nr_throttled/ {print $2}' "$CG/cpu.stat" 2>/dev/null || echo 0; }

# clean up leftovers from previous runs
if [ -d "$CG" ]; then
	echo max > "$CG/cpu.max" 2>/dev/null; sleep 1
	for p in $(cat "$CG/cgroup.threads" 2>/dev/null); do echo "$p" > /sys/fs/cgroup/cgroup.procs; done
	sleep 0.5; echo domain > "$CG/cgroup.type" 2>/dev/null || true
	rmdir "$CG" 2>/dev/null || true
fi

echo "IF=$IF threaded -> 1"
echo 1 > /sys/class/net/$IF/threaded
ping -q -c 600 -i 0.01 $TGT >/dev/null 2>&1 &
PP=$!
sleep 2
echo "napi threads:"; ps -eLo pid=,comm= | awk '$2 ~ /^napi\//'
PID=$(ps -eLo pid=,comm= | awk '$2 ~ /^napi\// {print $1; exit}')
echo "NAPIPID=$PID comm=$(cat /proc/$PID/comm 2>/dev/null)"

mkdir -p "$CG"
echo threaded > "$CG/cgroup.type"
grep -qw cpu /sys/fs/cgroup/cgroup.subtree_control || echo +cpu > /sys/fs/cgroup/cgroup.subtree_control
echo "$PID" > "$CG/cgroup.procs" && echo MOVE-OK || { echo MOVE-FAIL; kill $PP; exit 1; }

sn() { cpu_ns "$PID"; }
A=$(sn); sleep 2; B=$(sn); echo "schedstat delta PRE-throttle:   $((B-A)) ns (expect > 0)"
if echo "1000 1000000" > "$CG/cpu.max" 2>/dev/null; then
	echo "cpu.max = $(cat $CG/cpu.max)"
else
	echo "cpu.max write REJECTED"; exit 1
fi
N1=$(nr_thr); sleep 3; N2=$(nr_thr); echo "nr_throttled: $N1 -> $N2 (expect growth)"
A=$(sn); sleep 2; B=$(sn); echo "schedstat delta THROTTLED:      $((B-A)) ns (expect ~1-2 ms max)"
echo max > "$CG/cpu.max"
A=$(sn); sleep 2; B=$(sn); echo "schedstat delta POST-restore:   $((B-A)) ns (expect > 0)"

for p in $(cat "$CG/cgroup.threads" 2>/dev/null); do echo "$p" > /sys/fs/cgroup/cgroup.procs; done
sleep 1
echo domain > "$CG/cgroup.type" 2>/dev/null || true
rmdir "$CG" && echo "rmdir OK" || echo "rmdir FAIL"
kill $PP 2>/dev/null
echo 0 > /sys/class/net/$IF/threaded
echo VM-VERIFY-DONE
