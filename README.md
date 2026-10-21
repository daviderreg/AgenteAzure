# Hermes on Azure Container Apps

Deploy di Hermes Agent su **Azure Container Apps (ACA)** con separazione
tra compute effimero e persistenza applicativa tramite backup su Azure
Blob Storage.

## Architettura

``` text
                         Discord
                            ↕
                 ┌──────────────────────┐
                 │  Azure Container App │
                 │                      │
                 │     Hermes Agent     │
                 │                      │
                 │      /opt/data       │
                 │   runtime state      │
                 └──────────┬───────────┘
                            │
                     Managed Identity
                            │
                            ▼
                 ┌──────────────────────┐
                 │    Azure Blob        │
                 │      Storage         │
                 │                      │
                 │   hermes-backups     │
                 └──────────────────────┘

                 ┌──────────────────────┐
                 │    Log Analytics     │
                 │   Container logs     │
                 └──────────────────────┘
```

### Principio architetturale

``` text
Stateless compute
        +
Application-level persistent state
```

Il filesystem del container ACA è **effimero**. Hermes utilizza
`/opt/data` come `HERMES_HOME`, ma questo filesystem non viene
considerato uno storage persistente.

La persistenza viene realizzata a livello applicativo:

``` text
Hermes runtime
     │
     │ backup
     ▼
Azure Blob Storage
     │
     │ restore
     ▼
Nuova replica ACA
```

Non viene utilizzato Azure Files come filesystem runtime principale di
Hermes.

------------------------------------------------------------------------

# 1. Azure Foundation

La prima fase del progetto è stata completata tramite Terraform.

Risorse Azure principali:

``` text
Resource Group
└── rg-hermes-azure

Storage Account
└── hermesazurestorage2026
    └── hermes-backups

User Assigned Managed Identity
└── hermes-identity
    └── Storage Blob Data Contributor

Log Analytics Workspace
└── hermes-logs

Container Apps Environment
└── hermes-env

Container App
└── hermes-app
    └── Hermes Agent
```

### Container App

Configurazione attuale:

-   `min_replicas = 1`
-   `max_replicas = 1`
-   `revision_mode = Single`
-   workload profile: `Consumption`
-   Managed Identity assegnata
-   Hermes Agent eseguito con `gateway run`
-   `HERMES_HOME=/opt/data`

L'immagine Hermes attualmente utilizzata è:

``` text
nousresearch/hermes-agent:v2026.9.24
```

### Modello

Hermes utilizza Ollama Cloud con:

``` text
Provider: ollama-cloud
Model: nemotron-3-super:cloud
Base URL: https://ollama.com/v1
```

------------------------------------------------------------------------

# 2. Persistence

La seconda fase del progetto implementa la persistenza dello stato
applicativo di Hermes senza dipendere dalla persistenza del filesystem
della replica ACA.

Il runtime utilizza:

``` text
/opt/data
```

come home directory di Hermes (`HERMES_HOME`). Lo stato viene salvato
tramite backup applicativi in Azure Blob Storage:

``` text
Azure Blob Storage
└── hermes-backups
    └── auto/
```

## 2.1 Strategia di persistenza

L'implementazione comprende:

-   backup periodico dello stato Hermes ogni 900 secondi (15 minuti);
-   manifest JSON associato a ogni archivio;
-   checksum SHA-256 e verifica della dimensione;
-   verifica dell'integrità degli archivi ZIP;
-   accesso a Blob Storage tramite User Assigned Managed Identity e
    Azure RBAC;
-   restore automatico durante l'inizializzazione del container;
-   tentativo di fallback al backup precedente se quello più recente non
    è ripristinabile;
-   verifica della presenza e dell'integrità di `state.db`;
-   marker `.azure_restore_complete` per registrare il completamento
    dell'inizializzazione o del restore;
-   supervisione e retry del servizio di backup;
-   gestione best-effort dei segnali di shutdown.

Il marker viene creato sia dopo un restore riuscito sia quando non
esistono ancora backup e viene consentito il primo avvio. Se il marker è
già presente, il restore iniziale viene saltato: la sua presenza, da
sola, non implica che venga eseguito un nuovo import a ogni avvio.

## 2.2 Backup automatico

Il servizio `container/services/backup.sh` esegue un ciclo con
intervallo predefinito di **900 secondi (15 minuti)**.

Per ogni ciclo:

1.  Hermes crea un archivio tramite `hermes backup`.
2.  Viene generato un manifest JSON con nome del file, dimensione, hash
    SHA-256 e versione dello schema.
3.  Archivio e manifest vengono caricati su Azure Blob Storage tramite
    Managed Identity.
4.  In caso di errore, il servizio registra il problema e riprova al
    ciclo successivo.

Se l'upload fallisce, i file locali vengono conservati per facilitare la
diagnosi. `supervisor.py` tenta di riavviare il servizio di backup se il
processo termina inaspettatamente. Un errore del backup non arresta
direttamente il gateway Hermes.

Lo shutdown è best-effort: non è garantito un backup finale quando il
container viene arrestato. La protezione principale è il backup
periodico.

## 2.3 Download e verifica

`container/scripts/download_backup.py` seleziona i backup candidati in
`hermes-backups/auto/` e verifica, prima del ripristino:

-   presenza del manifest;
-   validità dello schema del manifest;
-   corrispondenza del nome del file;
-   corrispondenza della dimensione in byte;
-   corrispondenza dell'hash SHA-256;
-   integrità dell'archivio ZIP;
-   presenza di `state.db` nell'archivio.

I backup che non superano i controlli vengono scartati. I candidati
validi vengono resi disponibili per il processo di restore.

## 2.4 Ripristino all'avvio

`container/services/start-hermes.sh` avvia
`container/scripts/restore.sh` prima di avviare il gateway.

CONTROLLO INIZIALE DEL CONTAINER
 │
 ├── Esiste .azure_restore_complete?
 │      └── SÌ → Salta il ripristino iniziale
 │
 └── NO
        │
        ├── Interroga Azure Blob Storage
        │
        ├── CASO A: nessun backup disponibile
        │      └── Crea il marker e consente il primo avvio
        │
        └── CASO B: backup disponibili
               │
               ├── Scarica i candidati e i manifest
               ├── Verifica hash SHA-256, dimensione e ZIP
               ├── Importa il backup più recente valido (hermes import --force)
               ├── Verifica warning, state.db e integrità SQLite
               │
               ├── SUCCESSO
               │      └── Crea il marker e prosegue con l'avvio
               │
               └── FALLIMENTO
                      ├── Prova il backup precedente
                      └── Se nessun backup è ripristinabile, interrompe l'avvio

Il flusso è il seguente:

1.  Se `.azure_restore_complete` esiste già, il restore iniziale viene
    saltato.
2.  Se Azure non contiene backup, viene creato il marker e viene
    consentito il primo avvio.
3.  Se sono disponibili backup, lo script scarica i candidati e ne
    verifica l'integrità.
4.  Il backup più recente valido viene importato con
    `hermes import --force`.
5.  Lo script controlla gli eventuali warning di importazione, la
    presenza di `/opt/data/state.db` e l'integrità SQLite.
6.  Se il tentativo fallisce, viene provato il backup precedente
    disponibile.
7.  Se nessun backup può essere ripristinato correttamente, lo script
    termina con errore e impedisce l'avvio normale di Hermes.

I tentativi di importazione non sono isolati in una directory di staging
separata. Se un'importazione parziale modifica `HERMES_HOME` prima di
fallire, il tentativo con il backup precedente avviene nello stesso
ambiente. L'isolamento delle importazioni può essere valutato come
miglioramento futuro.

## 2.5 Supervisione e shutdown

`container/services/supervisor.py` gestisce il gateway Hermes e il
servizio di backup. Se il servizio di backup termina, il supervisor
tenta di riavviarlo; se termina il gateway, il supervisor termina a sua
volta.

Alla ricezione di `SIGTERM` o `SIGINT`, il supervisor inoltra i segnali
ai processi figli e attende la loro terminazione; se necessario, forza
la chiusura. La gestione dello shutdown è best-effort e non garantisce
un backup finale.

## 2.6 Verifiche effettuate

La Fase 2 è stata verificata sia con test locali sia nell'ambiente
Azure.

  -------------------------------------------------------------------------------------
  Verifica                              Esito
  ------------------------------------- -----------------------------------------------
  Build dell'immagine Docker e          Superati
  controlli locali degli script         

  Verifica SHA-256, manifest e          Superata
  integrità ZIP                         

  Scarto di backup non validi e         Superato nei test locali
  fallback al backup precedente         

  Gestione degli avvisi di importazione Superata nei test locali
  e dei file saltati                    

  Primo avvio senza backup              Superato nei test locali

  Retry e riavvio del servizio di       Superati nei test locali
  backup                                

  Gestione dei segnali di shutdown      Superata nei test locali

  Upload automatici su Azure Blob       Verificati
  Storage                               

  Integrità di un backup scaricato da   Superata
  Azure, verificata tramite manifest    

  Stop/Start della Container App e      Verificato
  memoria ancora disponibile su Discord 

  Log di importazione su Azure          `Import complete: 662 files restored in 1.2s`

  Database `/opt/data/state.db`         Verificato
  presente dopo l'avvio                 

  Marker                                Verificato
  `/opt/data/.azure_restore_complete`   
  presente dopo l'avvio                 
  -------------------------------------------------------------------------------------

Durante la verifica Azure, il log `latest-import.log` ha riportato 664
file nell'archivio e **662 file ripristinati**, con due file di runtime
(`gateway.lock` e `gateway_state.json`) preservati dalla macchina
corrente. Hermes ha poi ricordato su Discord un'informazione
precedentemente memorizzata.

Queste evidenze confermano che il processo di importazione è stato
eseguito con successo nella replica verificata. Il test Stop/Start, da
solo, non dimostrerebbe il restore; la conferma dell'import deriva dal
log di Hermes.

### Exit condition

La catena di backup e ripristino è stata distribuita e verificata
nell'ambiente Azure: sono stati osservati backup automatici su Blob
Storage, la verifica dell'integrità di un archivio e un'importazione
riuscita durante l'avvio della Container App.

La verifica copre il ciclo testato; non garantisce il recupero di dati
creati dopo l'ultimo backup disponibile né sostituisce test specifici
per ogni possibile scenario di perdita completa del filesystem.

------------------------------------------------------------------------

# 3. Security

L'accesso ad Azure Blob Storage non utilizza API key o connection string
statiche.

Il percorso previsto è:

``` text
Hermes
   │
   ▼
User Assigned Managed Identity
   │
   ▼
Azure RBAC
   │
   ▼
Blob Storage
```

La Managed Identity già presente viene utilizzata per l'accesso allo
storage.

## Secrets

Attualmente i secret applicativi sono gestiti come secret della
Container App:

``` text
Discord Bot Token
Ollama API Key
```

In una fase successiva sarà possibile spostare questi secret in Azure
Key Vault:

``` text
Azure Key Vault
├── Discord token
└── Ollama API key
        ▲
        │
Managed Identity
        │
        ▼
Container App
```

Questo è un miglioramento futuro e non è necessario per la Phase 1.

Blob Storage e secret management rimangono concetti separati:

``` text
Blob access
└── Managed Identity + RBAC

Application secrets
└── Container App Secrets
    └── futuro: Azure Key Vault
```

Gli archivi di backup possono contenere configurazioni, sessioni,
database e altri dati sensibili. Il container Blob deve quindi rimanere
privato e l'accesso deve essere limitato ai soggetti strettamente
necessari.

------------------------------------------------------------------------

# 4. Repository structure

La struttura del repository separa infrastruttura, runtime Hermes e
test:

``` text
hermes-azure/
│
├── .gitignore
├── README.md
│
├── terraform/
│   ├── main.tf
│   ├── providers.tf
│   ├── variables.tf
│   ├── versions.tf
│   ├── terraform.tfvars.example
│   └── ...
│
├── container/
│   ├── .dockerignore
│   ├── Dockerfile
│   ├── scripts/
│   │   ├── check_sqlite.py
│   │   ├── create-manifest.sh
│   │   ├── download_backup.py
│   │   ├── restore.sh
│   │   ├── upload_blob.py
│   │   └── verify-manifest.sh
│   └── services/
│       ├── backup.sh
│       ├── start-hermes.sh
│       └── supervisor.py
│
└── tests/
    └── ...
```

La directory `modal/` non fa parte dell'implementazione corrente.

L'esecuzione sandbox e Claude Code appartengono a fasi successive del
progetto.

------------------------------------------------------------------------

# 5. Roadmap

## Phase 1 --- Azure Foundation

**Status: completed**

-   [x] Terraform
-   [x] Azure Resource Group
-   [x] Storage Account
-   [x] Private Blob container `hermes-backups`
-   [x] User Assigned Managed Identity
-   [x] Blob RBAC
-   [x] Log Analytics
-   [x] Container Apps Environment
-   [x] Container App
-   [x] Single revision
-   [x] One replica
-   [x] Hermes Agent running on ACA
-   [x] Discord connectivity
-   [x] Ollama Cloud configuration

### Exit condition

Hermes Agent runs successfully on Azure Container Apps and the
infrastructure is reproducible with Terraform.

------------------------------------------------------------------------

## Phase 2 --- Hermes Persistence

**Status: completed and verified in Azure**

-   [x] Periodic backup service (15-minute interval)
-   [x] SHA-256 checksums
-   [x] Manifest JSON
-   [x] Automatic restore during initialization
-   [x] Fallback to one previous valid backup
-   [x] Restore/initialization marker
-   [x] `state.db` and SQLite integrity verification
-   [x] Managed Identity based Blob access
-   [x] Backup retry and supervision
-   [x] Best-effort process shutdown
-   [x] Local restore-cycle tests
-   [x] Automatic backup upload to Azure Blob Storage verified
-   [x] Backup integrity verified in Azure
-   [x] Successful import verified from Azure Container App logs
-   [x] Stop/Start memory-retention test on Discord

### Exit condition

The backup and restore flow is deployed in Azure, and a successful
import from a backup has been observed and verified in the Container
App.

A new ACA replica can start from an empty /opt/data, restore the latest valid Hermes state from Blob Storage, and continue with the previously persisted application state.

------------------------------------------------------------------------

## Phase 3 --- Cloud Sandbox

Future phase.

Hermes terminal execution will be delegated to an isolated cloud sandbox
instead of executing arbitrary workloads directly inside the ACA
runtime.

Possible technology:

``` text
Hermes
   ↓
Cloud sandbox
   ↓
isolated workspace
```

The specific implementation will be defined in Phase 3.

------------------------------------------------------------------------

## Phase 4 --- Claude Code

Future phase.

Claude Code will run inside the isolated sandbox rather than directly
inside the Hermes Container App.

------------------------------------------------------------------------

# 6. Final target architecture

The final architecture is intended to evolve toward:

``` text
                         Discord
                            ↕
                 ┌──────────────────────┐
                 │  Azure Container App │
                 │                      │
                 │     Hermes Agent     │
                 │      /opt/data       │
                 └──────────┬───────────┘
                            │
                  Managed Identity
                            │
                            ▼
                 ┌──────────────────────┐
                 │    Azure Blob        │
                 │   hermes-backups     │
                 └──────────────────────┘

                            │
                            │ terminal jobs
                            ▼

                 ┌──────────────────────┐
                 │   Isolated Sandbox   │
                 │                      │
                 │ Python / Node / Git  │
                 │    Claude Code       │
                 └──────────────────────┘
```

The important boundary is:

``` text
ACA
└── Hermes runtime

Blob
└── persistent application state

Sandbox
└── isolated code execution
```

This keeps the Hermes runtime reproducible while moving persistence and
arbitrary code execution outside the ephemeral container filesystem.
