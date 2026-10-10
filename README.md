# Hermes on Azure Container Apps

Deploy di Hermes Agent su **Azure Container Apps (ACA)** con separazione tra compute effimero e persistenza applicativa tramite backup su Azure Blob Storage.

## Architettura

```text
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

```text
Stateless compute
        +
Application-level persistent state
```

Il filesystem del container ACA è **effimero**. Hermes utilizza `/opt/data` come `HERMES_HOME`, ma questo filesystem non viene considerato uno storage persistente.

La persistenza viene realizzata a livello applicativo:

```text
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

Non viene utilizzato Azure Files come filesystem runtime principale di Hermes.

---

# 1. Azure Foundation

La prima fase del progetto è stata completata tramite Terraform.

Risorse Azure principali:

```text
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

* `min_replicas = 1`
* `max_replicas = 1`
* `revision_mode = Single`
* workload profile: `Consumption`
* Managed Identity assegnata
* Hermes Agent eseguito con `gateway run`
* `HERMES_HOME=/opt/data`

L'immagine Hermes attualmente utilizzata è:

```text
nousresearch/hermes-agent:v2026.9.24
```

### Modello

Hermes utilizza Ollama Cloud con:

```text
Provider: ollama-cloud
Model: nemotron-3-super:cloud
Base URL: https://ollama.com/v1
```

---

# 2. Persistence

La seconda fase del progetto riguarda la persistenza dello stato applicativo di Hermes.

L'obiettivo è evitare di dipendere dalla persistenza del filesystem della replica ACA.

Il runtime utilizzerà:

```text
/opt/data
```

come home directory di Hermes.

Lo stato prodotto da Hermes verrà successivamente salvato tramite backup applicativo in:

```text
Azure Blob Storage
└── hermes-backups
```

La strategia prevista comprende:

* backup periodico dello stato Hermes;
* checksum SHA-256;
* manifest JSON;
* restore automatico all'avvio;
* fallback all'ultimo backup valido;
* verifica dello stato restaurato;
* marker di restore completato;
* gestione best-effort del shutdown.

L'implementazione di questi componenti costituisce la **Phase 2**.

---

# 3. Security

L'accesso ad Azure Blob Storage non utilizza API key o connection string statiche.

Il percorso previsto è:

```text
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

La Managed Identity già presente viene utilizzata per l'accesso allo storage.

## Secrets

Attualmente i secret applicativi sono gestiti come secret della Container App:

```text
Discord Bot Token
Ollama API Key
```

In una fase successiva sarà possibile spostare questi secret in Azure Key Vault:

```text
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

```text
Blob access
└── Managed Identity + RBAC

Application secrets
└── Container App Secrets
    └── futuro: Azure Key Vault
```

---

# 4. Repository structure

La struttura del repository è organizzata per separare infrastruttura, runtime Hermes e test:

```text
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
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── bootstrap.py
│   └── requirements.txt
│
└── tests/
    └── ...
```

La directory `modal/` non fa parte dell'implementazione corrente.

L'esecuzione sandbox e Claude Code appartengono a fasi successive del progetto.

---

# 5. Roadmap

## Phase 1 — Azure Foundation

**Status: completed**

* [x] Terraform
* [x] Azure Resource Group
* [x] Storage Account
* [x] Private Blob container `hermes-backups`
* [x] User Assigned Managed Identity
* [x] Blob RBAC
* [x] Log Analytics
* [x] Container Apps Environment
* [x] Container App
* [x] Single revision
* [x] One replica
* [x] Hermes Agent running on ACA
* [x] Discord connectivity
* [x] Ollama Cloud configuration

### Exit condition

Hermes Agent runs successfully on Azure Container Apps and the infrastructure is reproducible with Terraform.

---

## Phase 2 — Hermes Persistence

**Status: next**

Planned components:

* [ ] `container/bootstrap.py`
* [ ] backup scheduler
* [ ] periodic backup
* [ ] SHA-256 checksums
* [ ] manifest JSON
* [ ] automatic restore
* [ ] fallback to one previous valid backup
* [ ] restore marker
* [ ] `state.db` verification
* [ ] Managed Identity based Blob access
* [ ] SIGTERM best-effort backup
* [ ] restore-cycle test

### Exit condition

A new ACA replica can start from an empty `/opt/data`, restore the latest valid Hermes state from Blob Storage, and continue with the previously persisted application state.

---

## Phase 3 — Cloud Sandbox

Future phase.

Hermes terminal execution will be delegated to an isolated cloud sandbox instead of executing arbitrary workloads directly inside the ACA runtime.

Possible technology:

```text
Hermes
   ↓
Cloud sandbox
   ↓
isolated workspace
```

The specific implementation will be defined in Phase 3.

---

## Phase 4 — Claude Code

Future phase.

Claude Code will run inside the isolated sandbox rather than directly inside the Hermes Container App.

---

# 6. Final target architecture

The final architecture is intended to evolve toward:

```text
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

```text
ACA
└── Hermes runtime

Blob
└── persistent application state

Sandbox
└── isolated code execution
```

This keeps the Hermes runtime reproducible while moving persistence and arbitrary code execution outside the ephemeral container filesystem.
