#!/usr/bin/env fish
# ==============================================================================
# SCRIPT NAME : ccr-linksafe-reboot.fish
# VERSION     : 2.3.1
# DATE        : October 21, 2026
# BASED ON    : bash v1.7 (validated 6/6) + fish v2.1.0
# DESCRIPTION : Safe reboot / upgrade of a MikroTik CCR2004-1G-2XS-PCIe card.
#               Disables the PCIe link on the host root port BEFORE the card
#               resets, so the card's reset glitch cannot freeze the host.
#
# CHANGES v2.3.1:
#   F4  the config file is looked up next to the script first:
#       <script dir>/ccr-linksafe.conf, then /etc/ccr-linksafe.conf.
#       $CCR_LINKSAFE_CONF still overrides both. Keeping the parameters in
#       the same directory as the script (e.g. /root/ccr2004pcie/) means the
#       whole kit travels together and nothing has to be exported by hand.
#
# CHANGES v2.3.0:
#   F1  ssh is now called with -n: under GNU timeout ssh ended up in its own
#       process group and, reading the tty on stdin, was stopped by SIGTTIN
#       (state T). The card never received /system reboot and the run hung at
#       STEP 5 (reproduced on Proxmox VE 9.2.21, 22/10/2026).
#       Fix: ssh -n (stdin from /dev/null) in both call sites of run_on_card.
#   F2  parameters can live in a config file instead of the script/environment:
#       /etc/ccr-linksafe.conf (override with CCR_LINKSAFE_CONF). Format:
#       KEY=VALUE, one per line, '#' comments; environment still wins.
#   F3  DLActive is bit 13 (0x2000) of the Link Status register, not bit 14
#       (0x4000): the STEP 4/STEP 7 messages reported "DLActive=0" on a link
#       that was actually up. Cosmetic only.
#
# CHANGES v2.2.0 (review fixes):
#   P0  no credential in the script: key-based ssh by default, optional PASSCMD
#   P1  failsafe armed at STEP 1 (before touching anything), not at STEP 5
#   P2  failsafe +30 min instead of +4, cancelled before the final reboot
#   P3  the card reboot is checked by exit code: auth/connect errors abort with
#       recovery instead of being logged as "expected"
#   P4  --upgrade ported from v1.7: PHASE A download, install, firmware, verify
#   P5  routes restored on every abort path (EXIT-safe cleanup function)
#   P6  control path verified before and after the default route change
#   P7  same log file as v1.7, absent functions logged, honest STEP 8/9 output
#
# USAGE:
#   ./ccr-linksafe-reboot.fish [--dry] [--auto] [--upgrade]
#                              [--card-ip IP] [--gw IP] [-h|--help]
#
#   --dry       simulate: no route, link, PCI or shutdown change
#   --auto      unattended: +30 min failsafe armed at STEP 1, final warm reboot
#               issued by the script and failsafe cancelled on success
#   --upgrade   RouterOS package + firmware cycle (2 card reboots)
#
# CONFIG: defaults can be overridden, in order of precedence:
#   command line (--card-ip, --gw) > environment > /etc/ccr-linksafe.conf > defaults
#
# AUTH: ssh key from this host to the card (recommended, already installed).
#       If a password is unavoidable, export PASSCMD="cat /root/.ccrpass"
#       (a command that PRINTS the password — never the password itself).
# ==============================================================================

set -g SCRIPT_VERSION "2.3.1"

# --- CONFIG FILE (env > file > defaults) ---
# /etc/ccr-linksafe.conf, or $CCR_LINKSAFE_CONF. KEY=VALUE per line, '#' comments.
# A variable already present in the environment is never overwritten here.
if set -q CCR_LINKSAFE_CONF
    set -g CONF_FILE $CCR_LINKSAFE_CONF
else
    set -l script_dir (dirname (status filename))
    if test -r $script_dir/ccr-linksafe.conf
        set -g CONF_FILE $script_dir/ccr-linksafe.conf
    else
        set -g CONF_FILE /etc/ccr-linksafe.conf
    end
end
if test -r $CONF_FILE
    for line in (string match -rv '^\s*(#|$)' < $CONF_FILE)
        set -l kv (string split -m1 = -- $line)
        if test (count $kv) -lt 2
            continue
        end
        set -l k (string trim -- $kv[1])
        set -l v (string trim -- $kv[2])
        set -l v (string replace -r '^"(.*)"$' '$1' -- $v)
        if not set -q $k
            set -gx $k $v
        end
    end
end

# --- DEFAULT HARDWARE PARAMETERS (override with env vars) ---
set -g CARD_IP (set -q CARD_IP; and echo $CARD_IP; or echo "192.0.2.148")
set -g CARD_USER (set -q CARD_USER; and echo $CARD_USER; or echo "admin")
set -g CTRL_IF (set -q CTRL_IF; and echo $CTRL_IF; or echo "nic3")
set -g ROOTPORT (set -q ROOTPORT; and echo $ROOTPORT; or echo "00:06.0")
set -g CARDPCI (set -q CARDPCI; and echo $CARDPCI; or echo "0000:01:00")
set -g BRIDGE (set -q BRIDGE; and echo $BRIDGE; or echo "vmbr0")
set -g BRIDGE_PORT (set -q BRIDGE_PORT; and echo $BRIDGE_PORT; or echo "nic0")
set -g CARD_IFS (set -q CARD_IFS; and echo $CARD_IFS; or echo "nic0 nic1 nic2 nic5")
set -g MTU (set -q MTU; and echo $MTU; or echo "1600")
set -g LOG (set -q LOG; and echo $LOG; or echo "/var/log/ccr-linksafe-reboot.log")
set -g CARD_MGT_NET "192.0.2.0/24"

# --- FLAGS / STATE ---
set -g AUTO 0
set -g DRY 0
set -g UPGRADE 0
set -g PKG_UPDATE 0
set -g ROUTES_CHANGED 0
set -g QUIESCED 0
set -g LINK_DISABLED 0
set -g FAILSAFE_ARMED 0
set -g LNKCTL ""
set -g OLD_GW ""
set -g OLD_DEV ""
set -g OLD_MGT_DEV ""
set -g OLD_MGT_VIA ""
set -g SSH_SRC ""

# --- GATEWAY DISCOVERY ---
if not set -q GW
    set -l detected_gw (ip -4 route show default 2>/dev/null | string match -rg 'via (\S+)' | head -n 1)
    if test -n "$detected_gw"
        set -g GW $detected_gw
    else
        set -g GW ""
    end
end

# --- ARGUMENTS ---
set -l i 1
while test $i -le (count $argv)
    switch $argv[$i]
        case "--dry"
            set -g DRY 1
        case "--auto"
            set -g AUTO 1
        case "--upgrade"
            set -g UPGRADE 1
        case "--card-ip"
            set i (math $i + 1)
            set -g CARD_IP $argv[$i]
        case "--gw"
            set i (math $i + 1)
            set -g GW $argv[$i]
        case "-h" "--help"
            echo "ccr-linksafe-reboot.fish v$SCRIPT_VERSION"
            echo "Usage: ./ccr-linksafe-reboot.fish [--dry] [--auto] [--upgrade] [--card-ip IP] [--gw IP]"
            echo "  --dry       simulate, change nothing"
            echo "  --auto      unattended: failsafe +30 min, final warm reboot by the script"
            echo "  --upgrade   RouterOS package + firmware cycle"
            echo "  Detected card IP: $CARD_IP | gateway: $GW | control NIC: $CTRL_IF"
            exit 0
        case "*"
            echo "Unknown option: $argv[$i] (try --help)" >&2
            exit 64
    end
    set i (math $i + 1)
end

# --- LOGGING ---
function log
    set -l tag "[v$SCRIPT_VERSION]"
    if test $DRY -eq 1
        set tag "[v$SCRIPT_VERSION:DRY-RUN]"
    end
    echo (date +%T)" $tag $argv" | tee -a $LOG
end

function cancel_scheduled_reboot
    shutdown -c >/dev/null 2>&1
end

# --- RECOVERY (used on every abort path) ---
function reenable_link
    if test $LINK_DISABLED -eq 1
        log "RECOVERY: restoring LnkCtl($ROOTPORT)=0x$LNKCTL and rescanning the bus"
        setpci -s $ROOTPORT CAP_EXP+10.w=0x$LNKCTL
        echo 1 > /sys/bus/pci/rescan
        set -g LINK_DISABLED 0
    end
end

function restore_routes
    # after the quiesce vmbr0 has no ports: restoring the routes would cut the
    # only live path (nic3). Leave them on the control NIC until the reboot.
    if test $QUIESCED -eq 1
        log "ROUTES: left on $CTRL_IF on purpose (vmbr0 has no ports until the warm reboot)"
        return 0
    end
    if test $ROUTES_CHANGED -eq 1
        if test -n "$OLD_GW"; and test -n "$OLD_DEV"
            log "RECOVERY: default route back to via $OLD_GW dev $OLD_DEV"
            ip route replace default via $OLD_GW dev $OLD_DEV 2>/dev/null
        else
            log "RECOVERY: removing the default route added via $GW dev $CTRL_IF"
            ip route del default via $GW dev $CTRL_IF 2>/dev/null
        end
        if test -n "$SSH_SRC"
            ip route del $SSH_SRC dev $CTRL_IF 2>/dev/null
        end
        if test -n "$OLD_MGT_DEV"
            log "RECOVERY: $CARD_MGT_NET back to via $OLD_MGT_VIA dev $OLD_MGT_DEV"
            ip route replace $CARD_MGT_NET via $OLD_MGT_VIA dev $OLD_MGT_DEV 2>/dev/null
        else if test -n "$GW"
            log "RECOVERY: removing the $CARD_MGT_NET route added via $GW dev $CTRL_IF"
            ip route del $CARD_MGT_NET via $GW dev $CTRL_IF 2>/dev/null
        end
        set -g ROUTES_CHANGED 0
    end
end

function abort_run --argument-names msg code
    log "ABORT: $msg"
    reenable_link
    restore_routes
    if test $FAILSAFE_ARMED -eq 1
        log "RECOVERY: cancelling the scheduled failsafe reboot"
        cancel_scheduled_reboot
        set -g FAILSAFE_ARMED 0
    end
    log "Cleanup complete, exit code $code"
    exit $code
end

# --- SSH TO THE CARD ---
function run_on_card --argument-names cmd tmo
    if test -z "$tmo"
        set tmo 15
    end
    if set -q PASSCMD; and test -n "$PASSCMD"
        timeout $tmo sshpass -p (eval $PASSCMD) ssh -n -o StrictHostKeyChecking=no \
            -o ConnectTimeout=8 -o PubkeyAuthentication=no $CARD_USER@$CARD_IP "$cmd" 2>/dev/null
    else
        timeout $tmo ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
            -o BatchMode=yes $CARD_USER@$CARD_IP "$cmd" 2>/dev/null
    end
end

# read a single RouterOS property without parsing formatted output: the
# console wraps long values, and an awk on "print" produced garbage
# (e.g. "stablemode" read as the RouterOS version).
function card_get --argument-names path prop
    run_on_card ":put [/$path get $prop]" 20 | tr -d '\r' | string trim
end

function card_ssh_rc --argument-names cmd tmo
    run_on_card $cmd $tmo >/dev/null
    return $status
end

function wait_card_down --argument-names max_s
    # a real reboot makes the card disappear for ~20-30 s: ping must FAIL at
    # least once. Exit code alone is not proof (ssh returns 255 for auth
    # failures too).
    set -l waited 0
    while test $waited -lt $max_s
        sleep 3
        set waited (math $waited + 3)
        if not timeout 3 ping -c 1 -W 2 $CARD_IP >/dev/null 2>&1
            return 0
        end
    end
    return 1
end

function wait_card --argument-names max_s
    set -l waited 0
    while test $waited -lt $max_s
        sleep 5
        set waited (math $waited + 5)
        if timeout 3 ping -c 1 -W 2 $CARD_IP >/dev/null 2>&1
            # ping answers BEFORE sshd is ready: probe ssh so the VERIFY
            # step reads real output instead of an empty capture
            set -l j 0
            while test $j -lt 18
                if run_on_card ":put ready" 10 | string match -q -- "*ready*"
                    break
                end
                sleep 5
                set j (math $j + 5)
            end
            sleep 2
            return 0
        end
    end
    return 1
end

# ==============================================================================
# PREFLIGHT — nothing is touched before every check passes
# ==============================================================================
echo "========================================================================"
echo "          CCR2004 PCIe LINK-SAFE REBOOT / UPGRADE (v$SCRIPT_VERSION)"
echo "========================================================================"

if test (id -u) -ne 0
    echo "ERROR: must run as root" >&2
    exit 77
end

for c in setpci ip ssh ping timeout awk seq
    if not command -q $c
        echo "ERROR: missing command: $c" >&2
        exit 78
    end
end

set -g MODE "plain reboot"
if test $UPGRADE -eq 1
    set -g MODE "RouterOS+firmware upgrade"
end
if test $AUTO -eq 1
    set -g MODE "$MODE, AUTO"
end
if test $DRY -eq 1
    set -g MODE "$MODE, DRY-RUN"
end

log "Starting. card=$CARD_IP gw=$GW ctrl_if=$CTRL_IF rootport=$ROOTPORT mode=$MODE"

# control NIC must exist and carry a link: it is the return path
if not test -e /sys/class/net/$CTRL_IF
    abort_run "control interface $CTRL_IF does not exist" 79
end
set -l ctrl_state (cat /sys/class/net/$CTRL_IF/operstate 2>/dev/null)
if test "$ctrl_state" != "up"
    abort_run "control interface $CTRL_IF has no link (operstate=$ctrl_state) — fix the return path first" 79
end

# root port must expose the PCIe capability
set -l lnk_probe (setpci -s $ROOTPORT CAP_EXP+10.w 2>/dev/null)
if test -z "$lnk_probe"
    abort_run "cannot read LnkCtl on root port $ROOTPORT (setpci failed)" 80
end
log "Preflight: LnkCtl($ROOTPORT) = 0x$lnk_probe"

# card must be reachable on the CURRENT path before we change anything
if not timeout 8 ping -c 2 -W 3 $CARD_IP >/dev/null 2>&1
    abort_run "card $CARD_IP unreachable before any change (nothing was touched)" 1
end
log "Preflight: card $CARD_IP reachable"

# ==============================================================================
# PHASE A (--upgrade): download while the link is still UP
#   NB: (a) re-running check-for-updates CANCELS a staged download — read the
#       status FIRST and keep it; (b) the check is ASYNC, poll until settled.
# ==============================================================================
if test $UPGRADE -eq 1; and test $DRY -eq 1
    log "[DRY] would check for RouterOS updates and download them while the link is up (PHASE A)"
else if test $UPGRADE -eq 1
    log "PHASE A: checking RouterOS updates (link still up)..."
    set -g PKG_UPDATE 0
    set -l st (card_get "system package update" "status")
    if string match -q -- "*Downloaded*" "$st"
        log "PHASE A: package already downloaded and staged (keeping it)"
        set -g PKG_UPDATE 1
    else
        run_on_card "/system package update check-for-updates" 30 >/dev/null
        # async: wait until latest-version is populated AND the status has
        # settled (an empty field right after the check is not "up to date")
        set -l waited 0
        set -l latest ""
        while test $waited -lt 60
            sleep 3
            set waited (math $waited + 3)
            set st (card_get "system package update" "status")
            set latest (card_get "system package update" "latest-version")
            if test -n "$latest"; and not string match -q -- "*finding out*" "$st"
                break
            end
        end
        set -l inst (card_get "system package update" "installed-version")
        if test -z "$latest"
            log "PHASE A WARNING: latest-version empty (check failed?) — continuing WITHOUT package update"
            set -g PKG_UPDATE 0
        else if test "$inst" = "$latest"
            log "PHASE A: RouterOS $inst is the latest (no package update needed)"
            set -g PKG_UPDATE 0
        else
            log "PHASE A: update $inst -> $latest available, downloading (zero downtime)..."
            run_on_card "/system package update download" 60 >/dev/null
            set -l waited 0
            while test $waited -lt 200
                sleep 5
                set waited (math $waited + 5)
                set st (card_get "system package update" "status")
                string match -q -- "*Downloaded*" "$st"; and break
            end
            if string match -q -- "*Downloaded*" "$st"
                log "PHASE A: package downloaded and staged ($inst -> $latest)"
                set -g PKG_UPDATE 1
            else
                abort_run "download did not complete — nothing was touched" 1
            end
        end
    end
end

# --- interactive confirmation (only when it can actually be answered) ---
if test $DRY -eq 0; and test $AUTO -eq 0
    echo ""
    echo "------------------------------------------------------------------------"
    echo " LINK-SAFE reboot of the CCR2004 card"
    echo "   card        : $CARD_IP"
    echo "   gateway     : $GW   (control NIC: $CTRL_IF)"
    echo "   root port   : $ROOTPORT"
    echo "   mode        : $MODE"
    echo "------------------------------------------------------------------------"
    if not tty -s
        abort_run "no TTY to confirm on; use --auto for unattended runs" 83
    end
    read -P "Press [ENTER] to start, Ctrl+C to abort... " confirm
    echo ""
end

# ==============================================================================
# STEP 1 — control path, verified, then failsafe
# ==============================================================================
set -g SSH_SRC (echo "$SSH_CLIENT" 2>/dev/null | cut -d' ' -f1)
log "STEP1: ssh client source = '$SSH_SRC', control NIC $CTRL_IF ($ctrl_state)"

if test -n "$GW"
    # the gateway must be reachable THROUGH the control NIC before we move
    # the default route onto it
    if not timeout 5 ping -c 1 -W 2 -I $CTRL_IF $GW >/dev/null 2>&1
        abort_run "gateway $GW not reachable via $CTRL_IF — refusing to move the default route" 81
    end
    set -l old_default (ip -4 route show default | head -n 1)
    set -g OLD_GW (echo "$old_default" | string match -rg 'via (\S+)' | head -n 1)
    set -g OLD_DEV (echo "$old_default" | string match -rg 'dev (\S+)' | head -n 1)
    set -l old_mgt (ip -4 route show $CARD_MGT_NET | head -n 1)
    set -g OLD_MGT_VIA (echo "$old_mgt" | string match -rg 'via (\S+)' | head -n 1)
    set -g OLD_MGT_DEV (echo "$old_mgt" | string match -rg 'dev (\S+)' | head -n 1)

    if test $DRY -eq 0
        ip route replace $CARD_MGT_NET via $GW dev $CTRL_IF 2>/dev/null
        ip route replace default via $GW dev $CTRL_IF
        set -g ROUTES_CHANGED 1
    else
        log "[DRY] would move $CARD_MGT_NET and default via $GW dev $CTRL_IF"
    end
end

if test -n "$SSH_SRC"
    if test $DRY -eq 0
        ip route replace $SSH_SRC dev $CTRL_IF
    else
        log "[DRY] would pin a host route to $SSH_SRC via $CTRL_IF"
    end
end

if test $DRY -eq 0
    # the session must now leave through the control NIC, otherwise STEP 2
    # is a lockout
    if test -n "$SSH_SRC"
        set -l rget (ip route get $SSH_SRC 2>/dev/null | head -n 1)
        if not string match -q -- "*dev $CTRL_IF*" "$rget"
            abort_run "route to ssh client does not use $CTRL_IF ($rget)" 82
        end
        log "STEP1 ok: client route via $CTRL_IF verified"
    end
    if not timeout 8 ping -c 2 -W 3 $CARD_IP >/dev/null 2>&1
        abort_run "card unreachable after the route change" 1
    end
    log "STEP1 ok: card still reachable through the new path"
end

if test $AUTO -eq 1
    if test $DRY -eq 0
        shutdown -r +30 "ccr-linksafe-reboot AUTO failsafe" >/dev/null 2>&1
        set -g FAILSAFE_ARMED 1
        log "STEP1-failsafe: +30 min host reboot armed"
    else
        log "[DRY] would arm a +30 min failsafe reboot"
    end
end

# ==============================================================================
# STEP 2 — quiesce the driver
# ==============================================================================
if test $DRY -eq 0
    ip link set $BRIDGE_PORT nomaster 2>/dev/null
    for dev in $CARD_IFS
        ip link set $dev down 2>/dev/null
    end
    set -g QUIESCED 1
    log "STEP2 ok: $BRIDGE_PORT detached from $BRIDGE, card interfaces DOWN"
else
    log "[DRY] would detach $BRIDGE_PORT from $BRIDGE and set $CARD_IFS DOWN"
end

# ==============================================================================
# STEP 3 — remove the PCI functions (driver already quiesced)
# ==============================================================================
if test $DRY -eq 0
    sleep 3
    for f in 0 1 2 3
        if test -e /sys/bus/pci/devices/{$CARDPCI}.$f
            echo 1 > /sys/bus/pci/devices/{$CARDPCI}.$f/remove
            log "STEP3: function $CARDPCI.$f removed"
        else
            log "STEP3: function $CARDPCI.$f already absent"
        end
    end
else
    log "[DRY] would remove PCI functions $CARDPCI.0-3"
end

# ==============================================================================
# STEP 4 — the key step: disable the PCIe link on the root port
# ==============================================================================
set -g LNKCTL (setpci -s $ROOTPORT CAP_EXP+10.w)
set -l lnkctl_dec (math "0x$LNKCTL")
set -l newval_dec (math "bitor $lnkctl_dec, 16")
set -l newval (printf "0x%04x" $newval_dec)
log "STEP4: LnkCtl($ROOTPORT) before = 0x$LNKCTL"

if test $DRY -eq 0
    setpci -s $ROOTPORT CAP_EXP+10.w=$newval
    set -g LINK_DISABLED 1
    sleep 3
    set -l lnksta (setpci -s $ROOTPORT CAP_EXP+12.w)
    set -l lnksta_dec (math "0x$lnksta")
    set -l dl (math "bitand $lnksta_dec, 8192")
    if test $dl -ne 0
        log "STEP4 WARN: link still active (LnkSta=0x$lnksta) — ROLLBACK, card NOT rebooted"
        reenable_link
        restore_routes
        if test $FAILSAFE_ARMED -eq 1
            cancel_scheduled_reboot
            set -g FAILSAFE_ARMED 0
        end
        log "STEP4: rollback complete (link restored). NOTE: $BRIDGE_PORT stays off $BRIDGE — a host warm reboot is still required to bring management back"
        exit 2
    end
    log "STEP4 ok: PCIe link DISABLED (LnkSta=0x$lnksta, DLActive=0)"
else
    log "[DRY] would write LnkCtl=$newval (LnkDisable) and verify DLActive=0"
end

# ==============================================================================
# STEP 5 — first card reboot (plain, or RouterOS package install)
# ==============================================================================
if test $DRY -eq 0
    set -l rc 0
    if test $UPGRADE -eq 1; and test $PKG_UPDATE -eq 1
        log "STEP5: ordering package update install (card reboot #1: RouterOS)..."
        card_ssh_rc "/system package update install" 120
        set rc $status
    else
        log "STEP5: ordering card reboot..."
        card_ssh_rc "/system reboot" 20
        set rc $status
    end
    if test $rc -ne 0; and test $rc -ne 255
        # 5/6 = auth/connect error, 124 = timeout. We cannot abort usefully here:
        # the PCI functions are already removed, so the host needs its warm
        # reboot regardless. Log loudly and let the checks below decide.
        log "STEP5 ERROR: ssh to the card failed (rc=$rc) — the card was probably NOT rebooted"
    end
    set -l reboot_wait 60
    if wait_card_down $reboot_wait
        log "STEP5 ok: card stopped answering — reboot confirmed"
    else
        log "STEP5 ERROR: card still answering after $reboot_wait s — reboot NOT confirmed (ssh auth? wrong IP?)"
    end
else
    log "[DRY] would send '/system reboot' (or package install) to $CARD_USER@$CARD_IP"
end

# ==============================================================================
# STEP 6 — wait for boot #1
# ==============================================================================
if test $DRY -eq 0
    log "STEP6: waiting for card boot #1..."
    if wait_card 300
        log "STEP6 ok: card back up"
    else
        log "STEP6 WARN: card not answering after 300s — continuing"
    end
else
    log "[DRY] would poll $CARD_IP until the card answers"
end

# ==============================================================================
# STEP 5b/6b (--upgrade) — firmware staging + second card reboot
# ==============================================================================
if test $UPGRADE -eq 1; and test $DRY -eq 0
    log "STEP5b: staging firmware (/system routerboard upgrade)..."
    set -l fw (run_on_card "/system routerboard upgrade" 60)
    set -l fw_rc $status
    if test $fw_rc -ne 0
        abort_run "routerboard upgrade command failed (ssh rc=$fw_rc)" 3
    end
    set -l fw_cur (card_get "system routerboard" "current-firmware")
    set -l fw_upg (card_get "system routerboard" "upgrade-firmware")
    log "STEP5b: firmware current=$fw_cur upgrade=$fw_upg"
    if test -n "$fw_upg"; and test "$fw_cur" != "$fw_upg"
        log "STEP5b: firmware upgrade pending ($fw_cur -> $fw_upg), ordering card reboot #2..."
        card_ssh_rc "/system reboot" 20
        set -l rc2 $status
        if test $rc2 -ne 0; and test $rc2 -ne 255
            log "STEP5b ERROR: ssh to the card failed (rc=$rc2) — firmware reboot probably not issued"
        end
        set -l reboot_wait2 60
        if wait_card_down $reboot_wait2
            log "STEP5b ok: card stopped answering — firmware reboot confirmed"
        else
            log "STEP5b ERROR: card still answering after $reboot_wait2 s — firmware reboot NOT confirmed"
        end
        log "STEP6b: waiting for boot #2 (firmware apply, slower)..."
        if wait_card 480
            log "STEP6b ok: card back up after firmware apply"
        else
            log "STEP6b WARN: card not answering after 480s — continuing"
        end
    else if string match -qi -- "*please reboot*" "$fw"; or string match -qi -- "*upgraded successfully*" "$fw"
        # the card says it wrote the firmware, but the property already matches:
        # nothing left to apply, no second reboot
        log "STEP5b: firmware already applied ($fw_cur), no second reboot needed"
    else
        log "STEP5b: no firmware staging needed (current $fw_cur)"
    end
    log "VERIFY: installed RouterOS + firmware:"
    run_on_card "/system package update print; /system routerboard print" 30 | tee -a $LOG
end

# ==============================================================================
# STEP 7 — re-enable the link
# ==============================================================================
if test $DRY -eq 0
    sleep 10
    setpci -s $ROOTPORT CAP_EXP+10.w=0x$LNKCTL
    set -g LINK_DISABLED 0
    log "STEP7: LnkDisable cleared, waiting for retrain..."
    set -l dl 0
    for k in (seq 1 12)
        sleep 5
        set -l lnksta (setpci -s $ROOTPORT CAP_EXP+12.w)
        set -l lnksta_dec (math "0x$lnksta")
        set dl (math "bitand $lnksta_dec, 8192")
        test $dl -ne 0; and break
    end
    if test $dl -ne 0
        log "STEP7 ok: link UP (DLActive=1)"
    else
        log "STEP7 WARN: link still down after 60s — expected on this platform, the warm reboot closes the procedure"
    end
else
    log "[DRY] would restore LnkCtl=0x$LNKCTL and wait for retrain"
end

# ==============================================================================
# STEP 8 — rescan (expected to fail until the warm reboot)
# ==============================================================================
if test $DRY -eq 0
    echo 1 > /sys/bus/pci/rescan
    sleep 10
    if test -e /sys/bus/pci/devices/{$CARDPCI}.0
        log "STEP8 ok: functions RE-ENUMERATED (hot retrain worked on this platform!)"
    else
        log "STEP8: rescan #1 did not enumerate the card, retrying in 30s"
        sleep 30
        echo 1 > /sys/bus/pci/rescan
        sleep 10
        if test -e /sys/bus/pci/devices/{$CARDPCI}.0
            log "STEP8 ok on the second rescan"
        else
            log "STEP8: card not re-enumerated (expected — the final warm reboot does it)"
        end
    end
else
    log "[DRY] would trigger a PCI bus rescan"
end

# ==============================================================================
# STEP 9 — re-attach (honest logging: nic0 is usually absent until reboot)
# ==============================================================================
if test $DRY -eq 0
    if test -e /sys/class/net/$BRIDGE_PORT
        ip link set $BRIDGE_PORT mtu $MTU up 2>/dev/null
        ip link set $BRIDGE_PORT master $BRIDGE 2>/dev/null
        log "STEP9: $BRIDGE_PORT re-attached to $BRIDGE (mtu $MTU)"
    else
        log "STEP9: $BRIDGE_PORT absent — nothing to re-attach (expected, the warm reboot restores it)"
    end
else
    log "[DRY] would re-attach $BRIDGE_PORT to $BRIDGE (mtu $MTU)"
end

# ==============================================================================
# END
# ==============================================================================
restore_routes   # no-op after the quiesce: routes stay on the control NIC

if test $DRY -eq 1
    log "SUCCESS (dry-run): logic verified, nothing was changed"
    exit 0
end

if test $AUTO -eq 1
    if test $FAILSAFE_ARMED -eq 1
        cancel_scheduled_reboot
        set -g FAILSAFE_ARMED 0
    end
    log "DONE (AUTO): final warm reboot NOW, the host returns by itself"
    shutdown -r now "ccr-linksafe-reboot AUTO: completed" >/dev/null 2>&1
else
    log "DONE: host alive, link restored. Run 'reboot' now for the final warm reboot."
end
