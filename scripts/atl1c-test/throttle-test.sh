#!/bin/bash
# throttle-test.sh — exercise the atl1c v5 link-down RX-poll wait (and, when
# the timing lines up, its bounded timeout) on a live host.
#
# Mechanism: a TCP pull from a zero-streaming server on another machine
# (scripts/atl1c-test/zero-http-server.py) loads the RX path through the
# physical wire of the tested NIC. The two busiest NAPI kthreads (TX + RX of
# that NIC) are moved into a threaded cgroup limited to cpu.max="1000 1000000"
# (1 ms of CPU per second). A starved NAPI thread cannot complete its poll,
# so NAPI_STATE_SCHED stays set; when a link flap then runs the driver's
# link-down work item, the bounded wait introduced by the v5 patch iterates
# (diag_poll_waits increments). Depending on when the thread gets its next
# 1 ms slice, the wait either completes benignly (a few loops) or reaches
# its bound and takes the timeout branch: ratelimited warning
# "RX poll won't finish, skipping link-down reset" + diag_poll_timeouts.
#
# Usage:  bash throttle-test.sh          (as root, on the host under test)
# The only manual step: flap the upstream port (RouterOS: disable/enable
# ether-pcie1) while the flap window is open.
#
# WARNING: the NIC under test carries the host management IP in our lab, so
# the SSH session becomes very slow (and stalls during each flap). Keep an
# out-of-band console (Intel AMT / serial) open as a safety net. All state
# is restored automatically by the EXIT trap.
#
# Kernel notes (learned the hard way, see docs/atl1c-hw-test-campaigns.md):
#  - the cgroup-v2 freezer does NOT freeze NAPI kthreads (they never reach a
#    freezing point), so cpu.max throttling is used instead;
#  - NAPI kthreads created before the netdev was renamed all show up as
#    "napi/eth%d-N"; they are identified here by measuring schedstat deltas
#    under load instead of by name;
#  - kthreads with PF_NO_SETAFFINITY (kworkers) cannot be moved into a
#    threaded cgroup (EINVAL); plain NAPI kthreads can.
set -u
CG=/sys/fs/cgroup/napi-throttle
FLOOD_URL=http://192.168.97.94:9999/	# zero-streaming server (adjust)
MAC=192.168.97.94			# flood source (adjust)
WINDOW=240
FLOODPID=""

cleanup() {
	[ -n "$FLOODPID" ] && kill "$FLOODPID" 2>/dev/null
	if [ -d "$CG" ]; then
		echo max > "$CG/cpu.max" 2>/dev/null
		sleep 2
		for p in $(cat "$CG/cgroup.threads" 2>/dev/null); do
			echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null
		done
		for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do
			echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null
		done
		sleep 1
		echo domain > "$CG/cgroup.type" 2>/dev/null
		rmdir "$CG" 2>/dev/null && echo "cgroup removed" \
			|| echo "cgroup left behind (empty, harmless): $CG"
	fi
	echo 0 > /sys/class/net/nic0/threaded 2>/dev/null
	echo "--- cleanup: threaded=0, flood stopped, cpu.max=max ---"
}
trap cleanup EXIT

cpu_ns() { awk '{print $1}' "/proc/$1/schedstat" 2>/dev/null || echo 0; }
nr_thr() { awk '/^nr_throttled/ {print $2}' "$CG/cpu.stat" 2>/dev/null || echo 0; }
vmbr_rx() { ip -s link show vmbr0 | awk '/RX:/{getline; print $1; exit}'; }

echo "[1/7] threaded=1 on nic0 (was: $(cat /sys/class/net/nic0/threaded 2>/dev/null))"
echo "------------------------------------------------------------------"
echo " READ THIS NOW: in ~15 s this SSH session becomes very slow,"
echo " because the host RX path is deliberately starved."
echo ""
echo " When 'FLAP WINDOW' appears, flap the upstream port twice:"
echo "   disable the port -> count 5 s -> enable it"
echo "   wait for Link Up (~20-30 s), then repeat once"
echo ""
echo " IF THE SCRIPT PRINTS 'ERROR' AND EXITS: do NOT flap; keep the log."
echo "------------------------------------------------------------------"
echo 1 > /sys/class/net/nic0/threaded || { echo "ERROR: sysfs threaded"; exit 1; }

echo "[2/7] RX flood: TCP pull from $FLOOD_URL"
ping -c1 -W2 "$MAC" >/dev/null 2>&1 && echo "  flood source ($MAC) reachable" \
	|| { echo "ERROR: flood source unreachable"; exit 1; }
if command -v curl >/dev/null 2>&1; then
	curl -s "$FLOOD_URL" -o /dev/null &
	FLOODPID=$!
else
	wget -q "$FLOOD_URL" -O /dev/null &
	FLOODPID=$!
fi
sleep 3
R1=$(vmbr_rx); sleep 2; R2=$(vmbr_rx)
RATE=$(( (R2 - R1) / 2 ))
# nic0's own counters are always zero on this card (ndo_get_stats64 bug),
# so the bridge counters are used to prove the flood is flowing.
echo "  vmbr0 RX: ~$((RATE / 1024 / 1024)) MB/s"
if [ "$RATE" -lt 1000000 ]; then
	echo "ERROR: flood not flowing (<1 MB/s). Is the server running? Abort."
	exit 1
fi

echo "[3/7] identifying the active NAPI kthreads (2 s sampling)..."
PIDS=$(ps -eLo pid=,comm= | awk '$2 ~ /^napi\// {print $1}')
[ -n "$PIDS" ] || { echo "ERROR: no napi kthreads"; exit 1; }
declare -A T1
for p in $PIDS; do T1[$p]=$(cpu_ns "$p"); done
sleep 2
declare -A DELTA
for p in $PIDS; do
	t2=$(cpu_ns "$p"); DELTA[$p]=$((t2 - ${T1[$p]}))
done
# The two busiest threads = TX + RX of the flooded NIC. The v5 wait samples
# the RX napi, so both are throttled.
PICK=$(for p in $PIDS; do echo "${DELTA[$p]} $p"; done | sort -rn | head -2)
BEST=""
while read -r d p; do
	if [ "$d" -ge 1000000 ]; then
		BEST="$BEST $p"
		echo "  selected pid $p ($(cat /proc/$p/comm 2>/dev/null)) delta ${d} ns / 2 s"
	fi
done <<< "$PICK"
if [ -z "${BEST// }" ]; then
	echo "ERROR: no napi kthread above 1 ms/2s (flood not reaching the NIC?)"
	exit 1
fi

echo "[4/7] threaded cgroup + throttle (shared quota 1 ms/s)"
mkdir -p "$CG"
[ -f "$CG/cgroup.type" ] && echo threaded > "$CG/cgroup.type" 2>/dev/null
grep -qw cpu /sys/fs/cgroup/cgroup.subtree_control \
	|| echo +cpu > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
for p in $BEST; do
	echo "$p" > "$CG/cgroup.procs" || { echo "ERROR: moving pid $p failed"; exit 1; }
done
echo "1000 1000000" > "$CG/cpu.max" || { echo "ERROR: cpu.max rejected"; exit 1; }
echo "  cgroup.type=$(cat "$CG/cgroup.type")  cpu.max=$(cat "$CG/cpu.max")  threads:$BEST"

echo "[5/7] verifying that throttling is active (4 s)..."
N1=$(nr_thr); sleep 4; N2=$(nr_thr)
echo "  nr_throttled: $N1 -> $N2"
if [ "$N2" -le "$N1" ]; then
	echo "ERROR: throttle not active (nr_throttled flat). Do NOT flap. Abort."
	exit 1
fi
for p in $BEST; do
	A=$(cpu_ns "$p"); sleep 1; B=$(cpu_ns "$p")
	echo "  pid $p schedstat delta under throttle: $((B-A)) ns / 1 s"
done

echo "[6/7] ================= FLAP WINDOW: ${WINDOW} s ================="
echo "  Flap the upstream port twice from the switch/router side."
echo "  This session stays slow during the window: that is expected."
echo "  The script exits early as soon as diag_poll_timeouts >= 1."
START=$(date +%s)
END=$(( START + WINDOW ))
while [ "$(date +%s)" -lt "$END" ]; do
	sleep 10
	echo "  $(date +%T) ($((END - $(date +%s)))s left) waits=$(cat /sys/module/atl1c/parameters/diag_poll_waits 2>/dev/null) timeouts=$(cat /sys/module/atl1c/parameters/diag_poll_timeouts 2>/dev/null) calls=$(cat /sys/module/atl1c/parameters/diag_poll_calls 2>/dev/null)"
	T=$(cat /sys/module/atl1c/parameters/diag_poll_timeouts 2>/dev/null || echo 0)
	[ "${T:-0}" -ge 1 ] && { echo "  >> TIMEOUT OBSERVED — closing the window"; break; }
done

echo "[7/7] restore and final checks"
echo max > "$CG/cpu.max"
sleep 2
for i in $(seq 1 20); do
	[ "$(cat /sys/class/net/nic0/carrier 2>/dev/null)" = "1" ] && break
	sleep 2
done
echo "--- dmesg (expected on a timeout):"
dmesg | grep -i "won't finish" | tail -3 || echo "  (no warning: benign waits only)"
echo "--- final counters:"
grep . /sys/module/atl1c/parameters/diag_*
echo "--- link:"
ip -br link show nic0
[ -x /root/atl1c-045-test/snap045.sh ] && /root/atl1c-045-test/snap045.sh timeout-1
echo "DONE."
