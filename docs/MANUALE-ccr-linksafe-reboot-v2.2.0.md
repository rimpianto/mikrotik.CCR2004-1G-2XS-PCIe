# ccr-linksafe-reboot.fish v2.2.0 — manuale

Riavvio e aggiornamento della scheda **MikroTik CCR2004-1G-2XS-PCIe** dentro un host
**Proxmox VE**, con il **link PCIe disabilitato** per tutta la durata del reset della
scheda. È la versione fish della procedura bash v1.7, con le correzioni emerse dalla
revisione della v2.1.0.

> Repository: **questo** ([rimpianto/mikrotik.CCR2004-1G-2XS-PCIe](https://github.com/rimpianto/mikrotik.CCR2004-1G-2XS-PCIe)).
> La versione bash storica è `scripts/ccr-linksafe-reboot` (v1.7, manuale in `docs/MANUALE-ccr-linksafe-reboot-v1.7.md`);
> la fish **v2.2.0** è `scripts/ccr-linksafe-reboot.ver.2.2.0.fish`.
> Contesto hardware e test anche in [rimpianto/minisforum.ms-02-ultra](https://github.com/rimpianto/minisforum.ms-02-ultra).

---

## 1. Perché esiste

La CCR2004-PCIe, mentre si resetta (reboot RouterOS, upgrade firmware), disturba il
**bus PCIe** dell'host. Il disturbo non passa dalle funzioni PCI: rimuoverle dal bus
**non basta** — nei test 1 run su 2 congelava comunque l'intera piattaforma, in
silenzio (zero log kernel, spente anche NIC su altre root port, vivo solo il chip
Intel ME).

Il disturbo viaggia sul **link fisico**. La specifica PCIe offre il rimedio:
il bit **LnkDisable** (LnkCtl, bit 4) sulla root port. Con il link disabilitato la
scheda può glitchare quanto vuole: non c'è nulla di collegato da disturbare.

```
  CPU ── root port 00:06.0 ═══ LINK ═══ scheda CCR2004 (4x AR8151)
                             ↑
                LnkDisable=1 → link GIÙ durante il reset
```

Conseguenza accettata e verificata: la root port Intel **non riallinea il link a
caldo** e il DMA dell'host resta wedged. La procedura finisce **sempre** con un
**warm reboot dell'host** (pianificato, non un'emergenza).

---

## 2. La sequenza, passo per passo

Lo script non tocca niente finché il preflight non è tutto verde.

### Preflight
- deve girare come root; verifica la presenza di `setpci`, `ip`, `ssh`, `ping`,
  `timeout`, `awk`, `seq`;
- la NIC di controllo (`CTRL_IF`, default `nic3`) deve esistere **e avere link**
  (`operstate=up`): è la via di ritorno quando le NIC della scheda vengono spente;
- la root port deve rispondere a `setpci -s <ROOTPORT> CAP_EXP+10.w`;
- la scheda deve essere raggiungibile **sul percorso attuale**, prima di qualsiasi
  modifica.

### PHASE A — solo con `--upgrade`
Il download del pacchetto RouterOS avviene **con il link ancora su**, cioè a costo
zero di rischio:

1. legge `/system package update print` **prima** di fare altro: se c'è già un
   `Downloaded, please reboot` lo tiene (rilanciare `check-for-updates` cancellerebbe
   il download già staged — comportamento di RouterOS);
2. altrimenti lancia `check-for-updates` e **aspetta** che lo stato si assesti
   (`finding out latest version...` è asincrono), poi confronta installed/latest;
3. se c'è una versione nuova, `download` e polling finché non è `Downloaded, please reboot`;
4. se il download non completa, **abortisce senza aver toccato niente**.

### STEP 1 — via di controllo e paracadute
- verifica che il gateway sia raggiungibile **attraverso** `CTRL_IF`
  (`ping -I <CTRL_IF> <GW>`); se non lo è, si ferma: spostare la default route su
  una NIC senza percorso sarebbe un lockout immediato;
- salva la default route e la rotta verso la MGT (`192.0.2.0/24`), poi le sposta
  su `CTRL_IF`;
- aggiunge una host route verso il client SSH (`$SSH_CLIENT`) sempre su `CTRL_IF`;
- verifica con `ip route get <client>` che la sessione esca davvero da `CTRL_IF`;
- riverifica la scheda sul nuovo percorso;
- **solo con `--auto`**: arma `shutdown -r +30` come failsafe. Se qualcosa si
  incastra a metà, l'host torna su da solo. Il failsafe viene cancellato alla fine
  (successo o abort).

### STEP 2 — quiesce del driver
Stacca `nic0` dal bridge e mette **DOWN** tutte le interfacce della scheda
(`nic0 nic1 nic2 nic5`). Il driver `atl1c` resta caricato ma fermo.
Questo passo è obbligatorio: rimuovere le funzioni PCI con il driver attivo =
wedge immediato (test #1 e #2 della matrice).

### STEP 3 — rimozione delle funzioni PCI
`echo 1 > /sys/bus/pci/devices/0000:01:00.N/remove` per N=0..3. Le funzioni già
assenti vengono **loggate** (non ignorate in silenzio).

### STEP 4 — il passo chiave: link giù (+ rollback)
```
LnkCtl  = setpci -s 00:06.0 CAP_EXP+10.w      # es. 0c40
nuovo   = LnkCtl | 0x0010                     # bit 4 = LnkDisable
LnkSta  = setpci -s 00:06.0 CAP_EXP+12.w
DLActive= LnkSta & 0x4000                     # bit 13
```
Se **DLActive resta 1**, il bit non ha preso: lo script **ripristina** LnkCtl, fa un
rescan, cancella il failsafe ed **esce con codice 2 senza riavviare la scheda**.
Meglio una procedura abortita che un host congelato.

### STEP 5 — reboot della scheda (+ conferma)
Con `--upgrade` e un pacchetto staged: `/system package update install`; altrimenti
`/system reboot`.

L'exit code di SSH **non è una prova**: `ssh` esce 255 anche per autenticazione
fallita o host irraggiungibile. Per questo, dopo l'invio, lo script verifica che la
scheda **smetta di rispondere al ping** entro 60 s. Se continua a rispondere, lo
scrive a lettere maiuscole nel log (`reboot NOT confirmed`) e prosegue: a quel punto
le funzioni PCI sono già state rimosse, quindi l'host ha comunque bisogno del suo
warm reboot.

### STEP 6 — attesa del boot
Polling ICMP; quando la scheda risponde, **sonda anche SSH** (`:put ready`) perché il
ping torna ~10 s prima che sshd accetti comandi. Timeout 300 s.

### STEP 5b/6b — solo con `--upgrade`: firmware
`/system routerboard upgrade` → se risponde `please reboot`, secondo reboot della
scheda e attesa fino a 480 s (il boot post-firmware è più lento). Poi stampa le
versioni installate (`package update print`, `routerboard print`) nel log.

### STEP 7 — link di nuovo su
Ripristina il valore **originale** di LnkCtl e aspetta fino a 60 s il retrain.
Sul firmware di questa scheda il retrain **non avviene**: il WARN è atteso e non è
un errore.

### STEP 8 — rescan
`echo 1 > /sys/bus/pci/rescan`, due tentativi a 30 s di distanza. Su questa
piattaforma la scheda **non si ri-enumera** senza power cycle: il messaggio
"not re-enumerated (expected)" è la norma, e il warm reboot finale è ciò che la
riporta sul bus.

### STEP 9 — re-attach
Se `nic0` esiste: MTU (`1600`) + `up` + `master vmbr0`. Se non esiste, lo dice
esplicitamente invece di dichiarare un successo falso.

### Fine
- `--auto`: cancella il failsafe e lancia `shutdown -r now` ("the host returns by itself");
- altrimenti: lascia l'host vivo e stampa `run 'reboot' now`.

> **Le rotte restano su `CTRL_IF` di proposito** quando la procedura arriva in fondo:
> `vmbr0` non ha più porte fino al reboot, ripristinare la default su `vmbr0`
> taglierebbe l'unica via di management. Sui percorsi di abort **prima** del quiesce,
> invece, le rotte vengono ripristinate ai valori originali.

---

## 3. Opzioni

| Opzione | Effetto |
|---|---|
| *(nessuna)* | reboot semplice della scheda; chiede conferma su TTY; **non** riavvia l'host da solo |
| `--dry` | simula tutto: nessuna rotta, nessun link, nessun PCI, nessuno shutdown. Anche `--upgrade` non fa chiamate alla scheda |
| `--auto` | unattended: failsafe `+30 min` armato a STEP 1, reboot finale dell'host eseguito dallo script, failsafe cancellato sul successo |
| `--upgrade` | ciclo completo RouterOS + firmware (2 reboot della scheda, PHASE A compresa) |
| `--card-ip <IP>` | override dell'IP di management della scheda |
| `--gw <IP>` | override del gateway della LAN dati |
| `-h`, `--help` | usage e valori rilevati, esce 0 |

Combinazioni tipiche:

```sh
# lab, guardando il log
./ccr-linksafe-reboot.ver.2.2.0.fish

# lab, ciclo completo RouterOS + firmware
./ccr-linksafe-reboot.ver.2.2.0.fish --upgrade

# da remoto/WAN: lanci, ti disconnetti, torna tutto da solo
./ccr-linksafe-reboot.ver.2.2.0.fish --upgrade --auto
```

---

## 4. Variabili d'ambiente

Tutte hanno un default per questo host e si sovrascrivono senza toccare il codice.

| Variabile | Default | Significato |
|---|---|---|
| `CARD_IP` | `192.0.2.148` | IP di management della scheda (ether1, LAN OOB) |
| `CARD_USER` | `admin` | utente RouterOS (serve ssh + reboot + update) |
| `PASSCMD` | *(vuota)* | comando che **stampa** la password (es. `cat /root/.ccrpass`). Vuota = chiave ssh |
| `CTRL_IF` | `nic3` | NIC host usata come via di controllo — **non** deve appartenere alla scheda |
| `ROOTPORT` | `00:06.0` | indirizzo PCI della root port sopra la scheda (`lspci -t`) |
| `CARDPCI` | `0000:01:00` | prefisso PCI delle 4 funzioni della scheda |
| `BRIDGE` | `vmbr0` | bridge a cui è agganciata la porta principale |
| `BRIDGE_PORT` | `nic0` | porta della scheda agganciata al bridge |
| `CARD_IFS` | `nic0 nic1 nic2 nic5` | **tutte** le interfacce della scheda |
| `MTU` | `1600` | MTU da ripristinare (= l2mtu di RouterOS) |
| `LOG` | `/var/log/ccr-linksafe-reboot.log` | log (stesso nome della v1.7) |

Esempio su un'altra macchina:

```sh
CARD_IP=10.0.0.5 CTRL_IF=ens18 ROOTPORT=00:1c.0 ./ccr-linksafe-reboot.ver.2.2.0.fish --dry
```

---

## 5. Autenticazione: chiave SSH

Lo script **non contiene credenziali**. Usa la chiave SSH dell'host verso la scheda,
con `BatchMode=yes` (nessun prompt, nessuna password su disco).

Verifica una volta sola, prima del primo run:

```sh
ssh -o BatchMode=yes -o StrictHostKeyChecking=no admin@192.0.2.148 ":put ready"
# deve stampare: ready
```

Se non funziona, installa la chiave:

```sh
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519        # se non esiste
scp /root/.ssh/id_ed25519.pub admin@192.0.2.148:key.pub
ssh admin@192.0.2.148 "/user ssh-key import public-key-file=key.pub user=admin"
ssh admin@192.0.2.148 "/file remove key.pub"
```

> RouterOS 7.24: importando una chiave, il default diventa
> `password-authentication=yes-if-no-key` — la password smette di funzionare per
> quell'utente. Se serve anche la password (WebFig, altri client), imposta
> `/ip ssh set password-authentication=yes`.

Se davvero servisse una password, **non scriverla nello script**: un file fuori dal
repo, leggibile solo da root, e `PASSCMD="cat /root/.ccrpass"`.
Una password in chiaro in un repo pubblico resta pubblica anche se poi la rimuovi:
la storia git conserva il commit.

---

## 6. Codici di uscita

| Codice | Significato | Cosa fare |
|---|---|---|
| 0 | completato (o dry-run) | con `--auto` l'host si sta già riavviando |
| 1 | scheda irraggiungibile prima delle modifiche, o dopo il cambio di rotte | controllare rete/MGT; **niente è stato toccato** (primo caso) |
| 2 | STEP 4: il link non è sceso, rollback eseguito, scheda **non** riavviata | investigare la root port; l'host richiede comunque un reboot per ripristinare `vmbr0` |
| 3 | STEP 5b: comando firmware fallito | verificare SSH/permessi sulla scheda |
| 64 | opzione sconosciuta | `--help` |
| 77 | non root | rilanciare come root |
| 78 | comando mancante | installare `pciutils`/`iproute2`/`openssh-client` |
| 79 | `CTRL_IF` assente o senza link | sistemare la via di controllo |
| 80 | `setpci` non legge la root port | verificare `ROOTPORT` |
| 81 | gateway non raggiungibile via `CTRL_IF` | correggere `--gw` o il cablaggio |
| 82 | la rotta del client non esce da `CTRL_IF` | non procedere: sarebbe un lockout |
| 83 | nessun TTY per la conferma | usare `--auto` (o lanciare da terminale) |

Gli abort passano sempre da una funzione di cleanup: link ripristinato (se era stato
disabilitato), rotte rimesse a posto (se il quiesce non è ancora avvenuto), failsafe
cancellato.

---

## 7. Come leggere il log

Ogni riga è `HH:MM:SS [v2.2.0] messaggio` e va anche in append su `$LOG`.

| Riga | Significato |
|---|---|
| `Preflight: LnkCtl(00:06.0) = 0x0c40` | la root port risponde; valore atteso su questa macchina |
| `STEP1 ok: client route via nic3 verified` | la sessione SSH esce dalla NIC di controllo |
| `STEP1-failsafe: +30 min host reboot armed` | paracadute aperto (solo `--auto`) |
| `STEP2 ok: nic0 detached from vmbr0...` | driver quiescato |
| `STEP3: function ... removed / already absent` | funzioni PCI fuori dal bus |
| `STEP4 ok: PCIe link DISABLED (DLActive=0)` | **isolamento verificato** |
| `STEP5 ok: card stopped answering — reboot confirmed` | la scheda è andata giù davvero |
| `STEP5 ERROR: card still answering after 60 s — reboot NOT confirmed` | il reboot non è partito (auth? IP?) |
| `STEP6 ok: card back up` | la scheda è tornata |
| `STEP7 WARN: link still down after 60 s — expected` | limite noto, chiude il warm reboot |
| `STEP8: card not re-enumerated (expected...)` | limite noto, idem |
| `STEP9: nic0 absent — nothing to re-attach` | atteso prima del reboot |
| `DONE (AUTO): final warm reboot NOW` | l'host si riavvia da solo |
| `DONE: ... Run 'reboot' now` | run interattivo: il reboot lo dai tu |

I WARN di STEP 7/8 **non sono errori**: sono il comportamento della piattaforma.

---

## 8. Prerequisiti

- root sull'host; `pciutils`, `iproute2`, `openssh-client`, `fish`;
- chiave SSH host → scheda funzionante (`:put ready`);
- una NIC di controllo **non** appartenente alla scheda, con link (qui `nic3`, 10GbE);
- MGT della scheda raggiungibile indipendentemente dall'host;
- per `--upgrade`: la scheda deve avere route verso internet e DNS funzionante
  (il download lo fa lei);
- una via di recovery fuori banda se l'host non è presidiato: AMT (`amt-power cycle`,
  ~45 s) o accesso fisico. Con `--auto` il failsafe a +30 min copre i casi in cui lo
  script si incastra.

Prima del primo uso su una macchina nuova: `--dry`, poi un run senza `--auto`
guardando il log.

---

## 9. Verifica dopo il run

```sh
uptime                                  # l'host è tornato?
lspci -nn | grep -i 1969:1083           # 4 funzioni AR8151 della scheda
ip -br addr show vmbr0                  # IP di management
ip -br addr show nic3                   # via di controllo
ssh -o BatchMode=yes admin@192.0.2.148 "/system package update print; /system routerboard print"
```

Dopo un `--upgrade` il log contiene anche il blocco `VERIFY:` con le versioni.

---

## 10. Recovery

| Situazione | Rimedio |
|---|---|
| lo script si incastra dopo il quiesce, `--auto` | il failsafe `+30 min` riavvia l'host da solo |
| lo script si incastra dopo il quiesce, interattivo | `amt-power cycle` da un'altra macchina, o reboot fisico |
| STEP 4 non riesce a scendere il link | lo script fa rollback da solo; l'host va comunque riavviato per ripristinare `vmbr0` |
| la scheda non torna su | console KVM AMT/SOL; la scheda è indipendente dall'host |

---

## 11. Limiti noti

- il link **non** riallinea a caldo: il warm reboot finale è parte della procedura;
- la scheda **non** si ri-enumera finché l'host resta acceso: serve il reboot;
- KVM AMT richiede un display HDMI collegato (dummy plug), altrimenti la sessione
  video non parte; SOL e power funzionano comunque;
- `--upgrade` applica **un** pacchetto RouterOS per volta (il flusso è quello di
  RouterOS: install → reboot → firmware → reboot).

---

## 12. Differenze rispetto alle versioni precedenti

| Aspetto | v1.7 (bash) | v2.1.0 (fish) | **v2.2.0 (fish)** |
|---|---|---|---|
| Password | via `PASSCMD`, mai hardcoded | **hardcoded** | **nessuna**, solo chiave |
| Failsafe | +30 min a STEP 1 | +4 min a STEP 5 | +30 min a STEP 1 |
| Conferma reboot scheda | exit code | "expected" sempre | ping che smette + exit code |
| `--upgrade` | sì | **no** | sì |
| Rollback rotte | no | no | sì (solo pre-quiesce) |
| Verifica percorso di ritorno | parziale | no | ping GW + `ip route get` |
| Log | `/var/log/ccr-linksafe-reboot.log` | altro nome | stesso nome di v1.7 |
| `--dry` | no | sì (non totale) | sì, nessuna modifica |

---

## 13. File

| Percorso | Ruolo |
|---|---|
| `scripts/ccr-linksafe-reboot.ver.2.2.0.fish` | lo script |
| `/var/log/ccr-linksafe-reboot.log` | log append, sopravvive ai reboot |
| `docs/MANUALE-ccr-linksafe-reboot-v2.2.0.md` | questo manuale |

Licenza: come il resto del repo. Nessuna credenziale nel repository.
