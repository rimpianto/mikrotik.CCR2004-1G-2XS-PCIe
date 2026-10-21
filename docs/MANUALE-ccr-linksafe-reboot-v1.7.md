# Manuale `ccr-linksafe-reboot` v1.7

> **Nota:** manuale storico della versione **bash v1.7**. La versione corrente è la
> **fish v2.2.0**: script `scripts/ccr-linksafe-reboot.ver.2.2.0.fish`, manuale
> `docs/MANUALE-ccr-linksafe-reboot-v2.2.0.md`.

Riavviare / aggiornare la MikroTik **CCR2004-1G-2XS-PCIe** senza congelare
l'host Proxmox — spiegazione completa, codice commentato riga per riga,
e i log reali del test di validazione end-to-end.

> Contesto tecnico completo: [rimpianto/mikrotik.CCR2004-1G-2XS-PCIe](https://github.com/rimpianto/mikrotik.CCR2004-1G-2XS-PCIe)
> e [rimpianto/minisforum.ms-02-ultra](https://github.com/rimpianto/minisforum.ms-02-ultra).

---

## 1. Il problema che lo script risolve

La CCR2004-PCIe ha un difetto card-side (SUP-223678): durante il proprio
reset (reboot RouterOS, upgrade firmware) disturba il bus PCIe dell'host.
Il disturbo **non passa dalle funzioni PCI** — rimuoverle non basta, nei
nostri test 1 run su 2 congelava comunque l'intera piattaforma, in
silenzio (zero log kernel, muoiono anche NIC su altre root port, sopravvive
solo il chip Intel ME).

Il disturbo viaggia sul **link PCIe fisico**. La specifica PCIe fornisce
il rimedio: il bit **LnkDisable** (LnkCtl bit 4) sulla root port —
l'equivalente software di staccare il cavo, riattaccabile via software.

```
   CPU ── root port 00:06.0 ═══ LINK ═══ scheda CCR2004 (4x AR8151)
                              ↑
                 LnkDisable=1: link GIÙ → la scheda
                 può glitchare quanto vuole: non c'è
                 nulla di collegato da disturbare.
```

Con il link disabilitato: **6/6 run, kernel vivo sempre, zero freeze**.
Prezzo noto e accettato: il link non riallinea a caldo e il DMA host
resta wedged → la procedura finisce SEMPRE con un warm reboot dell'host
(pianificato, ~6-7 min totali, mai un'emergenza).

---

## 2. I tre modi d'uso

```sh
# 1) reboot semplice della scheda, in lab (guardi il log, dai tu il reboot finale)
ccr-linksafe-reboot

# 2) ciclo completo di upgrade RouterOS + firmware, in lab
ccr-linksafe-reboot --upgrade

# 3) IL CASO REALE — da remoto/WAN: lanci, ti disconnetti, non tocchi più nulla
nohup /usr/local/bin/ccr-linksafe-reboot --upgrade --auto </dev/null >/dev/null 2>&1 & disown
exit
```

Con `--auto` il ciclo è completamente autonomo (~7 min): update scaricato →
host isolato → scheda aggiornata (1-2 reboot) → link riabilitato → **l'host
si riavvia da solo** → ti riconnetti e trovi tutto su.

---

## 3. Il codice, blocco per blocco

### 3.1 Configurazione (righe 64-84)

```bash
set -u
CARD_IP=${CARD_IP:-192.0.2.148}     # IP management della scheda (ether1, LAN OOB)
CARD_USER=${CARD_USER:-admin}          # utente RouterOS (diritti: ssh+reboot+update)
PASSCMD=${PASSCMD:-}                   # comando che stampa la password; "" = chiave ssh
GW=${GW:-192.168.97.1}                 # gateway LAN dati ("" se MGT direttamente attachata)
CTRL_IF=${CTRL_IF:-nic3}               # NIC di controllo — NON della scheda (nel lab: 10GbE)
ROOTPORT=${ROOTPORT:-00:06.0}          # root port sopra la scheda (scoprire con lspci -t)
CARDPCI=${CARDPCI:-0000:01:00}         # prefisso PCI delle funzioni scheda
BRIDGE=${BRIDGE:-vmbr0}                # bridge host dove sta la porta principale
BRIDGE_PORT=${BRIDGE_PORT:-nic0}       # porta scheda attachata al bridge
CARD_IFS=${CARD_IFS:-"nic0 nic1 nic2 nic5"}   # TUTTE le interfacce della scheda
MTU=${MTU:-1600}                       # MTU da ripristinare (= l2mtu RouterOS)
LOG=${LOG:-/var/log/ccr-linksafe-reboot.log}
AUTO=0; UPGRADE=0
for a in "$@"; do
    case "$a" in
        --auto) AUTO=1 ;;              # reboot finale schedulato dallo script
        --upgrade) UPGRADE=1 ;;        # ciclo update RouterOS + firmware
    esac
done
```

**Perché così:** ogni parametro ha il default del nostro lab ma è
overridabile via ambiente (`CARD_IP=10.0.0.5 ccr-linksafe-reboot ...`) —
su un'altra macchina non si tocca il codice, si passano le variabili.

**Autenticazione (`PASSCMD` vuoto = chiave ssh):** il modo giusto in
produzione è la chiave (nessuna password sul filesystem dell'host):

```bash
# una tantum, sull'host:
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519
scp /root/.ssh/id_ed25519.pub admin@<card>:key.pub
ssh admin@<card> "/user ssh-key import public-key-file=key.pub user=admin"
```

⚠️ **Nota RouterOS 7.24.x:** importare una chiave sull'utente attiva il
default `password-authentication=yes-if-no-key` → la password smette di
funzionare per quell'utente. Se servono entrambe le vie (password dal
laptop + chiave dall'host): `/ip ssh set password-authentication=yes`.

### 3.2 Helper (righe 86-110)

```bash
log() { echo "$(date +%T) [ccr-linksafe] $*" | tee -a "$LOG"; }
```
Ogni passo → console **e** `/var/log/ccr-linksafe-reboot.log` con orario.
Il log sopravvive ai reboot: è la fonte per verificare a posteriori.

```bash
run_on_card() {   # $1 = comando RouterOS, $2 = timeout (default 15s)
    local t=${2:-15}
    if [ -n "$PASSCMD" ]; then
        timeout "$t" sshpass -p "$($PASSCMD)" ssh ... "$CARD_USER@$CARD_IP" "$1" 2>/dev/null
    else
        timeout "$t" ssh ... "$CARD_USER@$CARD_IP" "$1" 2>/dev/null
    fi
}
```
Il canale verso la scheda: la MGT, rete indipendente dall'host — funziona
anche con l'host isolato. Il `timeout` evita che un ssh appeso blocchi lo
script per sempre (lezione della v1.4).

```bash
wait_card() {     # $1 = secondi massimi
    local max=${1:-240} waited=0
    while [ $waited -lt $max ]; do
        sleep 5; waited=$((waited+5))
        if timeout 3 ping -c 1 -W 2 "$CARD_IP" >/dev/null 2>&1; then
            local j=0
            while [ $j -lt 18 ]; do          # ping risponde PRIMA di ssh:
                run_on_card ":put ready" 10 2>/dev/null | grep -q ready && break
                sleep 5; j=$((j+5))          # sonda finché RouterOS è pronto
            done
            sleep 2
            return 0
        fi
    done
    return 1
}
```
**Lezione v1.7:** il ping della scheda torna ~10s prima che il demone ssh
accetti comandi (RouterOS a metà boot). Senza la sonda ssh, il VERIFY
catturava output vuoto.

### 3.3 PHASE A — solo con `--upgrade`: il download PRIMA dell'isolamento

```bash
if [ $UPGRADE -eq 1 ]; then
    if ! timeout 8 ping -c 2 -W 3 "$CARD_IP" >/dev/null 2>&1; then
        log "ERROR: $CARD_IP unreachable before download, abort (nothing was touched)"
        exit 1
    fi
    log "PHASE A: checking for RouterOS updates (link still up)..."
    # (a) rigiro check-for-updates CANCELLA un download già staged:
    #     prima leggo lo status e se è già staged lo TENGO.
    UPD=$(run_on_card "/system package update print" 30)
    if echo "$UPD" | grep -q "Downloaded, please reboot"; then
        log "PHASE A: update already downloaded and staged (keeping it)"
        PKG_UPDATE=1
    else
        run_on_card "/system package update check-for-updates" 30 >/dev/null
        for i in $(seq 1 20); do           # (b) il check è ASINCRONO:
            sleep 3                        #     "finding out latest version..."
            UPD=$(run_on_card "/system package update print" 30)
            echo "$UPD" | grep -q "finding out" || break
        done
        INST=$(echo "$UPD" | awk -F': *' '/installed-version/{v=$2} END{print v}' | tr -d '\r ')
        LATEST=$(echo "$UPD" | awk -F': *' '/latest-version/{v=$2} END{print v}' | tr -d '\r ')
        if [ -z "$LATEST" ] || [ "$INST" = "$LATEST" ]; then
            log "PHASE A: RouterOS $INST is the latest (no package update needed)"
            PKG_UPDATE=0
        else
            log "PHASE A: update $INST -> $LATEST available, downloading (zero-downtime phase)..."
            run_on_card "/system package update download" 60 >/dev/null
            DL=""
            for i in $(seq 1 40); do       # il download è pure asincrono:
                sleep 5                     # poll finché "Downloaded, please reboot"
                DL=$(run_on_card "/system package update print" 30)
                if echo "$DL" | grep -q "Downloaded, please reboot"; then break; fi
            done
            if echo "$DL" | grep -q "Downloaded, please reboot"; then
                log "PHASE A: package downloaded and staged"; PKG_UPDATE=1
            else
                log "PHASE A: download did not complete — abort (nothing touched)"; exit 1
            fi
        fi
    fi
fi
```

**Log reale (run di validazione, 27/9 ore 17:23):**

```
17:23:39 PHASE A: checking for RouterOS updates (link still up)...
17:23:44 PHASE A: update 7.24.3 -> 7.24.4 available, downloading (zero-downtime phase)...
17:23:59 PHASE A: package downloaded and staged
```

**Perché prima:** il download è l'unica parte lenta e va fatta col link
attivo — così il periodo "sensibile" (host isolato, scheda in reboot) è il
più corto possibile. E se il download fallisce, l'abort è pulito: non è
stato toccato NIENTE.

**Lezioni incorporate (costate due run falliti):**
- v1.4: `check-for-updates` è asincrono — leggere subito dopo restituisce
  "finding out latest version..." → parsing vuoto → abort spurizio. Ora:
  polling finché lo status si assesta.
- v1.5/v1.6: rilanciare il check **cancella un download già staged**
  (comportamento RouterOS). Ora: status letto per primo, staged = keep.

### 3.4 STEP 1 — via di controllo + failsafe

```bash
SSH_SRC=${SSH_CLIENT%% *}
if [ -n "$GW" ]; then
    ip route replace default via "$GW" dev "$CTRL_IF"
fi
[ -n "$SSH_SRC" ] && ip route replace "$SSH_SRC" dev "$CTRL_IF"

if ! timeout 8 ping -c 2 -W 3 "$CARD_IP" >/dev/null 2>&1; then
    log "ERROR: $CARD_IP unreachable, abort (nothing was touched)"
    exit 1
fi
log "STEP1 ok: card reachable (mode: $MODE)"

if [ $AUTO -eq 1 ]; then
    shutdown -r +30 "ccr-linksafe-reboot AUTO failsafe" >/dev/null 2>&1
    log "STEP1-pre: +30 min failsafe reboot armed"
fi
```

**Tre cose in questo passo:**

1. **La via di ritorno della tua sessione.** Se sei collegato via SSH su
   una NIC che non è della scheda, le risposte dell'host potrebbero uscire
   comunque dalla scheda (routing asimmetrico) — e il STEP2 ti disconnetterebbe.
   Fix: default route + host route del tuo client ($SSH_CLIENT) pinnate
   sulla NIC di controllo. Prima di procedere, verifica con un ping al
   tuo client.

2. **Il check della scheda:** se non risponde, abort pulito ("nothing was
   touched" — è vero: fin qui abbiamo solo aggiunto route).

3. **Il failsafe `--auto`:** un "reboot host a +30 min" armato ORA e
   cancellato solo sul completamento pulito. Se qualcosa si incatena a
   metà procedura (ssh appeso, scheda che non torna), l'host si riavvia
   comunque da solo — da remoto trovi tutto su, non un host appeso.

**Log reale:**

```
17:24:00 STEP1 ok: card reachable (mode: RouterOS+firmware upgrade, AUTO)
17:24:00 STEP1-pre: +30 min failsafe reboot armed
```

### 3.5 STEP 2-3 — quiesce del driver e remove delle funzioni

```bash
ip link set "$BRIDGE_PORT" nomaster 2>/dev/null
for n in $CARD_IFS; do ip link set "$n" down 2>/dev/null; done
log "STEP2 ok: $BRIDGE_PORT off $BRIDGE, card interfaces down"

sleep 3
for f in 0 1 2 3; do
    if [ -e "/sys/bus/pci/devices/$CARDPCI.$f" ]; then
        echo 1 > "/sys/bus/pci/devices/$CARDPCI.$f/remove"
        log "STEP3: function $CARDPCI.$f removed"
    else
        log "STEP3: function $CARDPCI.$f already absent"
    fi
done
```

**STEP2 (quiesce):** stacca nic0 dal bridge e spegne tutte le interfacce
della scheda. Il driver atl1c resta caricato ma fermo: non tocca più
l'hardware. **Questo passaggio è vitale**: rimuovere funzioni PCI con il
driver attivo = wedge immediato dell'host (test #1 e #2 della matrice).

**STEP3 (remove):** le 4 funzioni 01:00.0-3 escono dal bus via sysfs.
Con driver quiescente è pulito. Il `sleep 3` dà al driver il tempo di
quiescere del tutto.

**Log reale:**

```
17:24:00 STEP2 ok: nic0 off vmbr0, card interfaces down
17:24:03 STEP3: function 0000:01:00.0 removed
17:24:03 STEP3: function 0000:01:00.1 removed
17:24:03 STEP3: function 0000:01:00.2 removed
17:24:04 STEP3: function 0000:01:00.3 removed
```

### 3.6 STEP 4 — IL PASSO CHIAVE: link giù (+ rollback di sicurezza)

```bash
LNKCTL=$(setpci -s "$ROOTPORT" CAP_EXP+10.w)          # LnkCtl attuale (es. 0c40)
log "STEP4: LnkCtl($ROOTPORT) before = 0x$LNKCTL"
NEWVAL=$(printf "0x%04x" $(( 0x$LNKCTL | 0x0010 )))   # set bit 4 = LnkDisable
setpci -s "$ROOTPORT" CAP_EXP+10.w=$NEWVAL
sleep 3
LNKSTA=$(setpci -s "$ROOTPORT" CAP_EXP+12.w)          # LnkSta
DL=$(( 0x$LNKSTA & 0x4000 ))                          # bit 13 = DLActive
if [ $DL -ne 0 ]; then
    log "STEP4 WARN: link still active (LnkSta=0x$LNKSTA) — ROLLBACK, card NOT rebooted"
    setpci -s "$ROOTPORT" CAP_EXP+10.w=0x$LNKCTL     # link ripristinato
    echo 1 > /sys/bus/pci/rescan                      # funzioni recuperate
    cancel_scheduled_reboot
    log "STEP4: rollback done (link restored, functions recovered by rescan)"
    exit 2
fi
log "STEP4 ok: link DISABLED (LnkSta=0x$LNKSTA, DLActive=0)"
```

**Cosa succede fisicamente:** `CAP_EXP+10.w` è il registro LnkCtl della
root port (offset 0x10 nel capability PCI Express). Il bit 4 è LnkDisable:
scriverlo mette il link in stato Disabled — LTSSM giù, nessun traffico,
nessun electrical/link-level event può passare tra scheda e host.
`CAP_EXP+12.w` è LnkSta: il bit 13 (DLActive, mask 0x4000) dice se il Data
Link Layer è attivo. **0 = link davvero giù.**

**Il rollback è la parte più importante:** se il bit non prende (alcune
BIOS/root port potrebbero ignorarlo), lo script NON ordina il reboot della
scheda — ripristina link e funzioni e esce con codice 2. Meglio un
procedura abortita che un host congelato: senza isolamento verificato non
si va avanti.

**Log reale:**

```
17:24:04 STEP4: LnkCtl(00:06.0) before = 0x0c40
17:24:07 STEP4 ok: link DISABLED (LnkSta=0x1043, DLActive=0)
```

(0x1043: bit 13 spento = DLActive 0; il bit 0x2 in più è "correctable
error detected" della root port — innocuo, è lo shock del link-down.)

### 3.7 STEP 5-6 — reboot della scheda (e secondo ciclo firmware)

```bash
if [ $UPGRADE -eq 1 ] && [ "${PKG_UPDATE:-0}" -eq 1 ]; then
    log "STEP5: ordering package update install (card reboot #1: RouterOS)..."
    run_on_card "/system package update install" 120 >/dev/null
    log "STEP5: install ordered (ssh closed at reboot is normal)"
else
    run_on_card "/system reboot" && log "STEP5: card reboot ordered" \
        || log "STEP5: ssh closed at reboot (normal)"
fi

log "STEP6: waiting for card boot #1..."
if wait_card 300; then
    log "STEP6 ok: card back up"
else
    log "STEP6 WARN: card not answering after 300s — continuing anyway"
fi
```

Con `--upgrade`, dopo il primo reboot, il firmware:

```bash
if [ $UPGRADE -eq 1 ]; then
    log "STEP5b: staging firmware upgrade (/system routerboard upgrade)..."
    FW=$(run_on_card "/system routerboard upgrade" 60)
    if echo "$FW" | grep -qi "please reboot\|upgraded"; then
        run_on_card "/system reboot"          # card reboot #2 (firmware)
        ... wait_card 480 ...                 # boot firmware = più lungo
    else
        log "STEP5b: no firmware staging needed (already current)"
    fi
    log "VERIFY: installed RouterOS + firmware:"
    run_on_card "/system package update print; /system routerboard print" 30 | tee -a "$LOG"
fi
```

**Nota su `/system/routerboard/upgrade`:** su RouterOS 7.24 via SSH
non-interattivo NON chiede la y/n (la chiede solo in console interattiva) —
esegue lo staging del firmware e risponde "please reboot", che è il segnale
che serve il secondo reboot della scheda.

**Log reale:**

```
17:24:07 STEP5: ordering package update install (card reboot #1: RouterOS)...
17:24:07 STEP5: install ordered (ssh closed at reboot is normal)
17:24:07 STEP6: waiting for card boot #1...
17:24:38 STEP6 ok: card back up
17:24:38 STEP5b: staging firmware upgrade (/system routerboard upgrade)...
17:24:38 STEP5b: no firmware staging needed (already current)
17:24:38 VERIFY: installed RouterOS + firmware:
```

(Il "no firmware staging needed": in quel run il firmware 7.24.4 era già
stato applicato in un reboot precedente — corretto. In un ciclo pieno qui
comparirebbe "card reboot #2 ordered" + VERIFY con le versioni.)

⚠️ **In questo momento l'host è vivo ma "sordo":** il DMA delle NIC è
wedged dai fault del glitch pre-isolamento (o, con link giù, semplicemente
non c'è traffico verso di lui). Se sei ancora attaccato via SSH su una NIC
della scheda, da qui in poi la sessione muore — per questo la procedura
prevede CTRL_IF e --auto.

### 3.8 STEP 7-9 — riabilitazione link e chiusura

```bash
sleep 10
setpci -s "$ROOTPORT" CAP_EXP+10.w=0x$LNKCTL   # valore originale: LnkDisable=0
log "STEP7: LnkDisable cleared, waiting for retrain..."
for i in $(seq 1 12); do
    sleep 5
    LNKSTA=$(setpci -s "$ROOTPORT" CAP_EXP+12.w)
    DL=$(( 0x$LNKSTA & 0x4000 ))
    [ $DL -ne 0 ] && break
done
```

```bash
echo 1 > /sys/bus/pci/rescan        # tentativo (atteso fallisca: link non allenato)
...
ip link set "$BRIDGE_PORT" mtu "$MTU" up 2>/dev/null   # re-attach (no-op se assente)
ip link set "$BRIDGE_PORT" master "$BRIDGE" 2>/dev/null
log "STEP9: re-attach attempted"
```

**Log reale:**

```
17:24:48 STEP7: LnkDisable cleared, waiting for retrain...
17:25:49 STEP7 WARN: link still down after 60s (LnkSta=0x1041) — expected; the warm reboot closes the procedure
17:25:59 STEP8: rescan #1 failed (expected), retry in 30s
17:26:39 STEP8 FAILED: card not re-enumerated (expected — final warm reboot)
17:26:39 STEP9: re-attach attempted
```

Questi WARN/FALLITO **non sono errori** — sono i limiti card-side
documentati: la root port Intel non rilancia il retrain a caldo (0x1041:
DLActive=0 anche dopo il clear), e la scheda non ri-enumerà mai senza un
power cycle. Lo script li prova comunque (se un giorno MikroTik fixa il
card-side, o su una board diversa il retrain funziona, STEP7/8
diventerebbero verdi e il warm reboot finale sarebbe superfluo).

### 3.9 FINALE — il warm reboot

```bash
if [ $AUTO -eq 1 ]; then
    cancel_scheduled_reboot
    log "DONE (AUTO) — final warm reboot NOW, host returns by itself"
    shutdown -r now "ccr-linksafe-reboot AUTO: completed" >/dev/null 2>&1 || true
else
    log "DONE — host alive; run 'reboot' now for the final warm reboot"
fi
```

**Log reale + esito:**

```
17:26:39 DONE (AUTO) — final warm reboot NOW, host returns by itself
```

Al boot l'host ritrova: scheda enumerata pulita (4 funzioni), driver
patchato attachato, vmbr0 mtu 1600 (persistente), lease MGT della scheda,
route normali. Verifica post-boot:

```
17:31:58 up 4 min   ← l'host è tornato da solo, ~7 min dal lancio
lspci: 4x AR8151 presenti
vmbr0: mtu 1600, UP
scheda: version 7.24.4 (stable)   ← upgrade applicato
```

---

## 4. Il run di validazione completo, riga per riga

Il test finale (27/9, ore 17:23-17:32) — scenario WAN simulato: lancio
`--upgrade --auto`, disconnect immediato, nessun intervento umano:

```
17:23:39  PHASE A: checking for RouterOS updates (link still up)...
17:23:44  PHASE A: update 7.24.3 -> 7.24.4 available, downloading (zero-downtime phase)...
17:23:59  PHASE A: package downloaded and staged          ← 20s di download, link attivo
17:24:00  STEP1 ok: card reachable (mode: RouterOS+firmware upgrade, AUTO)
17:24:00  STEP1-pre: +30 min failsafe reboot armed       ← paracadute aperto
17:24:00  STEP2 ok: nic0 off vmbr0, card interfaces down  ← driver fermo
17:24:03  STEP3: function 0000:01:00.0 removed           ← ×4, funzioni fuori dal bus
17:24:04  STEP4: LnkCtl(00:06.0) before = 0x0c40
17:24:07  STEP4 ok: link DISABLED (LnkSta=0x1043, DLActive=0)  ← ISOLAMENTO VERIFICATO
17:24:07  STEP5: ordering package update install (card reboot #1: RouterOS)...
17:24:38  STEP6 ok: card back up                          ← 31s, RouterOS 7.24.4 ON
17:24:38  STEP5b: staging firmware upgrade ...
17:24:38  STEP5b: no firmware staging needed (already current)
17:24:38  VERIFY: installed RouterOS + firmware:
17:24:48  STEP7: LnkDisable cleared, waiting for retrain...
17:25:49  STEP7 WARN: link still down after 60s — expected  ← limite noto
17:25:59  STEP8: rescan #1 failed (expected), retry in 30s
17:26:39  STEP8 FAILED: card not re-enumerated (expected)   ← limite noto
17:26:39  STEP9: re-attach attempted
17:26:39  DONE (AUTO) — final warm reboot NOW, host returns by itself
─────────────────────────────────────────────────────────────
17:31:58  host up 4 min · scheda 7.24.4 · 4 funzioni · mtu 1600
```

**Totale: 8 minuti dal lancio al ritorno, zero interventi umani, scheda
aggiornata 7.24.3 → 7.24.4.**

---

## 5. Matrice di validazione (tutti i test, 26-27/9)

| # | Sequenza | Esito host |
|---|----------|-----------|
| 1 | `modprobe -r atl1c` driver attivo | wedge immediato |
| 2 | remove PCI driver attivo | wedge immediato |
| 3 | quiesce+remove, link attivo, run 1 | vivo |
| 4 | quiesce+remove, link attivo, run 2 | **freeze silenzioso** (1-in-2) |
| 5 | quiesce+remove+**LnkDisable**, script | vivo |
| 6 | idem, script | vivo |
| 7 | idem, TUTTO A MANO (utente) | vivo |
| 8 | idem + --auto unattended, disconnect | vivo, host torna solo ~6 min |
| 9 | idem, script, utente (v1.2) | vivo |
| 10 | **--upgrade --auto unattended: 7.24.3→7.24.4** | **vivo, upgrade applicato, ~8 min** |

**Link disabilitato = kernel vivo, 6/6. Link attivo = freeze 1-in-2.**

---

## 6. Limiti noti e comportamenti attesi (leggerli prima di panico)

| Log | Significato | Azione |
|---|---|---|
| `STEP7 WARN: link still down` | la root port non riallinea a caldo (limite Intel/card) | nessuna: il warm reboot chiude |
| `STEP8 FAILED: not re-enumerated` | la scheda non torna sul bus senza power cycle | nessuna: idem |
| `STEP5: ssh closed at reboot (normal)` | il reboot chiude la sessione ssh prima del timeout | nessuna |
| `STEP6 WARN: not answering after 300s` | boot scheda insolitamente lento | controllare la scheda via MGT |
| `ERROR: unreachable, abort (nothing was touched)` | prerequisito fallito | risolvere la rete e rilanciare |
| `STEP4 WARN: link still active — ROLLBACK` | LnkDisable non preso | NON riavviare la scheda; investigare la root port |

E i tre livelli di auto-recupero dell'host (da configurare una volta):

```sh
echo 'GRUB_RECORDFAIL_TIMEOUT=5' >> /etc/default/grub
echo 'GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX panic=10"' > /etc/default/grub.d/panic-reboot.cfg
proxmox-boot-tool refresh        # PVE: NON basta update-grub
sed -i 's/^#*RuntimeWatchdogSec=.*/RuntimeWatchdogSec=30/' /etc/systemd/system.conf
sed -i 's/^#*RebootWatchdogSec=.*/RebootWatchdogSec=10/' /etc/systemd/system.conf
```

Con questi, anche uno scenario imprevisto (freeze, panic) si auto-recupera:
GRUB non si ferma al menu, il kernel si riavvia dopo un panic, il watchdog
TCO (lo stesso chip di AMT) resetta l'host dopo 30s di freeze.

---

## 7. Requisiti e prerequisiti

- Host: funzioni PCI della scheda note (`lspci -t` per la root port),
  `setpci` (pacchetto pciutils), ssh + chiave verso la scheda
- Rete: una NIC host NON della scheda come via di controllo (CTRL_IF) +
  la MGT della scheda raggiungibile indipendentemente
- Scheda: utente con diritti ssh/reboot/update; per --upgrade, MGT con
  route verso internet + DNS funzionante (il download avviene dalla scheda)
- Per --auto da remoto: AMT/IPMI come backup o almeno il failsafe +30 min
  (che lo script arma da solo)

**Prima del primo uso su una macchina nuova:** verificare i prerequisiti
in sequenza (ping scheda, ssh dalla chiave, `lspci -t`, valori LnkCtl) e
fare un run senza `--auto`, guardando il log.
