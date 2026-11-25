# Document IA — Architecture Cloud Scaleway (Présentation Équipe)

> **Version synthétique** destinée à la présentation équipe / CTO.  
> Pour les spécifications détaillées, les contrats Pulumi et les ADRs complets, voir [`docs/ARCHITECTURE.md`](ARCHITECTURE.md).

---

## 1. Principes Directeurs

1. **Souveraineté & Résidence (`fr-par`)** : 100 % hébergé sur **Scaleway** (projet `DocumentIA`, Organisation DINUM), sauvegardes locales `backup_same_region=True`, DNS conservé sur **OVH** (migration progressive depuis Scalingo sans risque).
2. **Zéro IP Publique sur le Compute & les Bases** : seuls les points d'entrée HTTPS (`Load Balancer` et `Metabase`) et la `Public Gateway` (NAT sortant) sont exposés. Tous les nœuds Kubernetes, PostgreSQL (`Main` et `Analytics`) et Redis sont **100 % privés**.
3. **Défense en Profondeur** : isolation L3 inter-environnements (`VPC Network ACL` en `DROP` par défaut, épinglée au `/32`), isolation intra-cluster (`Cilium NetworkPolicy`), **7 secrets Kubernetes dédiés par rôle**, et isolation S3 par `BucketPolicy`.
4. **Auto-scaling Natif sans Daemon Custom** : remplacement de `document-ia-auto-scaler` par **KEDA** (sur lag Redis Streams) + **Kapsule Cluster Autoscaler**.
5. **Conformité RGPD native** : alignement strict à **7 jours** sur S3 (lifecycle), `remove-ppi` (J+7) et les sauvegardes `pg-main` ; **30 jours** sur `pg-analytics` (données anonymisées uniquement).

---

## 2. Vue Globale — Big Picture

```mermaid
flowchart LR
    classDef internet fill:#e8f4fd,stroke:#1d6fa5,stroke-width:2px,color:#0d3b66
    classDef gateway fill:#fff3cd,stroke:#d97706,stroke-width:2px,color:#78350f
    classDef privateCompute fill:#e6f4ea,stroke:#1e7e34,stroke-width:2px,color:#14532d
    classDef privateData fill:#f3e8ff,stroke:#7c3aed,stroke-width:2px,color:#4c1d95
    classDef security fill:#fee2e2,stroke:#dc2626,stroke-width:2px,color:#7f1d1d
    classDef scwService fill:#f1f5f9,stroke:#475569,stroke-width:2px,color:#1e293b

    subgraph INBOUND["Internet (Entree)"]
        USERS(["Utilisateurs & Clients API"]):::internet
        DNS["DNS (OVH)"]:::internet
    end

    subgraph ENTRY["Points d'entree Publics"]
        LB["Load Balancer Public<br/>(api.* · console.*)"]:::gateway
        METABASE["Metabase BI<br/>(metabase.*)"]:::gateway
    end

    subgraph VPC["VPC Prive Scaleway — Zero IP Publique"]
        subgraph PN_ENV["Reseau Prive Environnement"]
            KAPSULE["Cluster Kubernetes Kapsule"]:::privateCompute
            PG_MAIN[("PostgreSQL")]:::privateData
            REDIS[("Redis")]:::privateData
        end

        VPC_ACL{{"VPC Network ACL (DROP par defaut)<br/>Autorise uniquement SQL vers Analytics"}}:::security

        subgraph PN_ANA["Reseau Prive Analytics"]
            PG_ANA[("PostgreSQL Analytics")]:::privateData
        end
    end

    subgraph EGRESS["Sortie NAT & Bastion"]
        PGW["Public Gateway<br/>(NAT Sortant · Bastion SSH)"]:::gateway
    end

    subgraph OUTBOUND["Destinations Sortantes"]
        EXT["Services Externes<br/>(Albert · ProConnect · Webhooks)"]:::internet
        S3[("Object Storage S3")]:::scwService
        REG["Container Registry"]:::scwService
        COCKPIT["Cockpit (Observabilite)"]:::scwService
    end

    USERS -->|"HTTPS"| DNS
    DNS -->|"api.* / console.*"| LB
    DNS -->|"metabase.*"| METABASE
    LB --> KAPSULE
    METABASE -->|"Reseau prive"| PG_ANA

    KAPSULE --> PG_MAIN
    KAPSULE --> REDIS
    KAPSULE --> VPC_ACL
    VPC_ACL --> PG_ANA

    KAPSULE -->|"NAT"| PGW
    PGW -->|"HTTPS"| EXT
    PGW --> S3
    PGW --> REG
    PGW --> COCKPIT
```

---

## 3. Isolation Réseau & Sécurité

### 3.1. Isolation Inter-Réseaux (Shared VPC, VPC ACL `/32` & Public Gateway)

```mermaid
flowchart LR
    classDef internet fill:#e8f4fd,stroke:#1d6fa5,stroke-width:2px,color:#0d3b66
    classDef gateway fill:#fff3cd,stroke:#d97706,stroke-width:2px,color:#78350f
    classDef prod fill:#dcfce7,stroke:#15803d,stroke-width:2px,color:#14532d
    classDef nonprod fill:#e0f2fe,stroke:#0369a1,stroke-width:2px,color:#0c4a6e
    classDef analytics fill:#f3e8ff,stroke:#7c3aed,stroke-width:2px,color:#4c1d95
    classDef acl fill:#fee2e2,stroke:#dc2626,stroke-width:2px,color:#7f1d1d
    classDef scwService fill:#f1f5f9,stroke:#475569,stroke-width:2px,color:#1e293b

    subgraph INTERNET_IN["Internet (Entree)"]
        USERS(["Utilisateurs & Clients API"]):::internet
        DNS["DNS (OVH)"]:::internet
    end

    subgraph PUBLIC_IN["Points d'entree Publics"]
        LB["Load Balancer Public<br/>(1 par cluster · api.* / console.*)"]:::gateway
        METABASE["Metabase BI<br/>(metabase.* · Serverless Container)"]:::gateway
    end

    subgraph VPC["VPC Prive Scaleway (docia-shared-vpc · fr-par · Zero IP Publique)"]
        subgraph PN_STG["pn-staging (172.16.4.0/22)"]
            STG_RES["Kapsule + PG Main + Redis"]:::nonprod
        end

        subgraph PN_SBX["pn-sandbox (172.16.8.0/22)"]
            SBX_RES["Kapsule + PG Main + Redis"]:::nonprod
        end

        subgraph PN_PRD["pn-prod (172.16.12.0/22)"]
            PRD_RES["Kapsule + PG Main (HA) + Redis (HA)"]:::prod
        end

        VPC_ACL{{"VPC Network ACL (Stateless · default_policy=DROP)<br/>Bloque tout trafic inter-environnements & Metabase -> env<br/>Autorise UNIQUEMENT pn-* -> 172.16.0.10/32:5432 (+ retour)"}}:::acl

        subgraph PN_ANA["pn-analytics (172.16.0.0/24)"]
            PG_ANA[("PostgreSQL Analytics<br/>IP fixe: 172.16.0.10/32 (:5432)")]:::analytics
        end
    end

    subgraph PUBLIC_OUT["Sortie Public Gateway"]
        PGW["Public Gateway (NAT Sortant)<br/>Couvre aussi l'acces Bastion SSH<br/>(non-prod: ON · prod: break-glass)"]:::gateway
    end

    subgraph DEST_OUT["Internet (Sortie) & Services Manages Scaleway"]
        EXT["Internet — Services Externes<br/>(Albert · ProConnect · Webhooks)"]:::internet
        subgraph MANAGED["Services Manages Scaleway (fr-par)"]
            S3[("Object Storage S3<br/>(BucketPolicy stricte)")]:::scwService
            REG["Container Registry"]:::scwService
            COCKPIT["Cockpit (Loki / Grafana)"]:::scwService
        end
    end

    USERS -->|"HTTPS"| DNS
    DNS -->|"api.* / console.*"| LB
    DNS -->|"metabase.*"| METABASE

    LB --> STG_RES
    LB --> SBX_RES
    LB --> PRD_RES
    METABASE -->|"L2 local pn-analytics (:5432)"| PG_ANA

    STG_RES -.-x|"DROP"| SBX_RES
    SBX_RES -.-x|"DROP"| PRD_RES
    STG_RES -->|"SQL :5432"| VPC_ACL
    SBX_RES -->|"SQL :5432"| VPC_ACL
    PRD_RES -->|"SQL :5432"| VPC_ACL
    VPC_ACL -->|"Autorise /32"| PG_ANA

    STG_RES -->|"NAT"| PGW
    SBX_RES -->|"NAT"| PGW
    PRD_RES -->|"NAT"| PGW

    PGW -->|"HTTPS"| EXT
    PGW --> S3
    PGW --> REG
    PGW --> COCKPIT
```

### 3.2. Isolation Intra-Cluster (`Cilium NetworkPolicy` & Secrets par rôle)

```mermaid
flowchart LR
    classDef ingress fill:#fff3cd,stroke:#d97706,stroke-width:2px,color:#78350f
    classDef app fill:#e6f4ea,stroke:#1e7e34,stroke-width:2px,color:#14532d
    classDef cron fill:#e0f2fe,stroke:#0369a1,stroke-width:2px,color:#0c4a6e
    classDef data fill:#f3e8ff,stroke:#7c3aed,stroke-width:2px,color:#4c1d95
    classDef egress fill:#f1f5f9,stroke:#475569,stroke-width:2px,color:#1e293b

    LB["Scaleway LB (Public)<br/>1 par cluster · TCP 80/443 · PPv2"]:::ingress

    subgraph KAPSULE["Cluster Kapsule du sous-reseau pn-&lt;env&gt;"]
        TRAEFIK["Traefik + cert-manager<br/>(Namespace systeme du cluster)"]:::ingress

        subgraph NS["Namespace docia-&lt;env&gt; (Cilium Default-Deny + 7 Secrets dedies)"]
            EVALS["Console: document-ia-evals (:8501)<br/>Secret: docia-evals-secret<br/>(Aucun acces DB / Redis)"]:::app
            CORE["Core Runtime: API · Worker · KEDA<br/>Secrets: docia-api / worker / keda-redis<br/>(Aucun acces PG Analytics)"]:::app
            CRON_PPI["CronJob: remove-ppi (03:00)<br/>Secret: docia-cron-ppi-secret"]:::cron
            CRON_REPL["CronJob: replicate-analytics (05:00)<br/>Secret: docia-cron-analytics-secret"]:::cron
            CRON_DBT["CronJob: dbt-transform (05:30)<br/>Secret: docia-cron-dbt-secret<br/>(Aucun acces PG Main)"]:::cron
        end
    end

    subgraph TARGETS["Destinations Autorisees (Loki :443 autorise pour tous)"]
        NAT_EXT["NAT Egress (:443)<br/>ProConnect · S3 · Albert · Webhooks"]:::egress
        REDIS[("Redis (:6379 TLS + CA)<br/>API · Worker · KEDA")]:::data
        PG_MAIN[("PG Main (:5432)<br/>API · Worker · PPI · Replicate")]:::data
        PG_ANA[("PG Analytics (:5432)<br/>172.16.0.10/32")]:::data
    end

    LB -->|"PPv2"| TRAEFIK
    TRAEFIK -->|"console.*"| EVALS
    TRAEFIK -->|"api.*"| CORE

    EVALS -->|"HTTP :8000"| CORE
    EVALS -->|"ProConnect :443"| NAT_EXT

    CORE -->|"S3 / Albert / Webhooks"| NAT_EXT
    CORE -->|"TLS :6379"| REDIS
    CORE -->|"SQL :5432"| PG_MAIN

    CRON_PPI -->|"SQL :5432"| PG_MAIN
    CRON_REPL -->|"Read :5432"| PG_MAIN
    CRON_REPL -->|"Write :5432"| PG_ANA
    CRON_DBT -->|"Transform :5432"| PG_ANA
```

**Points clés Sécurité** :
* **VPC ACL épinglée `/32`** : empêche Metabase (qui partage `pn-analytics`) de joindre `pn-prod` / `non-prod` en spoofing port source `5432`.
* **Bastion SSH *break-glass* en `prod`** : `bastion_enabled=False` par défaut en prod (activable ponctuellement + `bastion_allowed_ips`).
* **Moindre privilège sur les secrets** : 7 `core.v1.Secret` K8s dédiés par composant ; `document-ia-api` n'a **aucun accès** à `pg-analytics` (`auto_migrate_analytics()` est joué par le CronJob `replicate-analytics`).
* **S3 par environnement** : IAM App sans policy projet-globale + `BucketPolicy` stricte sur le bucket de l'environnement uniquement.
* **Cockpit / Loki** : datasource applicative dédiée (`observability.Source`) + token **write-only** (`write_logs=True`, zéro droit de lecture/admin) ; lecture Grafana via SSO Scaleway IAM.

---

## 4. Cluster Kubernetes Kapsule & Auto-Scaling

```mermaid
flowchart LR
    classDef ingress fill:#fff3cd,stroke:#d97706,stroke-width:2px,color:#78350f
    classDef control fill:#e0e7ff,stroke:#4338ca,stroke-width:2px,color:#1e1b4b
    classDef sys fill:#f1f5f9,stroke:#475569,stroke-width:2px,color:#1e293b
    classDef app fill:#e6f4ea,stroke:#1e7e34,stroke-width:2px,color:#14532d
    classDef worker fill:#dcfce7,stroke:#15803d,stroke-width:2px,color:#14532d
    classDef cron fill:#e0f2fe,stroke:#0369a1,stroke-width:2px,color:#0c4a6e
    classDef data fill:#f3e8ff,stroke:#7c3aed,stroke-width:2px,color:#4c1d95

    LB["Scaleway Load Balancer<br/>TCP 80/443 · Proxy Protocol v2"]:::ingress

    subgraph KAPSULE["Scaleway Kubernetes Kapsule (Control Plane Manage · CNI Cilium)"]
        CP["Managed Control Plane<br/>API Server · Scheduler · Cluster Autoscaler"]:::control

        subgraph POOL_SYS["Node Pool: api-system (Prive · 2x PRO2-S en Prod)"]
            subgraph NS_SYS["Namespaces Systeme"]
                TRAEFIK["Traefik Ingress<br/>TLS 1.3"]:::ingress
                CERTMGR["cert-manager<br/>Let's Encrypt HTTP-01"]:::sys
                KEDA_OP["KEDA Operator<br/>Poll Redis Lag (30s)"]:::sys
            end

            subgraph NS_APP_SYS["Namespace docia-&lt;env&gt; — Services & CronJobs"]
                EVALS["document-ia-evals<br/>Streamlit :8501 · ProConnect"]:::app
                API["document-ia-api<br/>FastAPI :8000 · 1Gi"]:::app
                CRONS["3 CronJobs<br/>remove-ppi (03:00)<br/>replicate-analytics (05:00)<br/>dbt-transform (05:30)"]:::cron
            end
        end

        subgraph POOL_WRK["Node Pool: workers (Prive · Autoscaling 1..5x PRO2-S en Prod)"]
            subgraph NS_APP_WRK["Namespace docia-&lt;env&gt; — Traitement IA/OCR"]
                KEDA_SO["KEDA ScaledObject + TriggerAuth<br/>lagCount=10 · +1/2min · -1/5min"]:::sys
                WORKERS["document-ia-worker<br/>2Gi RAM/pod · ~2 pods/PRO2-S<br/>1 thread CPU (semaphore) + 7 HTTP I/O<br/>Graceful drain 180s + XAUTOCLAIM"]:::worker
            end
        end
    end

    subgraph PN_DATA["Services Prives (pn-&lt;env&gt; & pn-analytics)"]
        REDIS[("Redis (:6379 TLS)<br/>event_stream · webhook_stream")]:::data
        PG_MAIN[("PG Main (:5432)<br/>event_store · api_key")]:::data
        PG_ANA[("PG Analytics (:5432)<br/>172.16.0.10/32")]:::data
    end

    LB -->|"PPv2"| TRAEFIK
    CERTMGR -.->|"Certificats TLS 1.3"| TRAEFIK
    TRAEFIK -->|"console.*"| EVALS
    TRAEFIK -->|"api.*"| API
    EVALS -->|"HTTP :8000"| API

    KEDA_OP --> KEDA_SO
    KEDA_SO -.->|"Scale 1..N pods"| WORKERS
    WORKERS -.->|"Pod Pending -> Ajoute VM PRO2-S"| CP

    API -->|"XADD / Quotas"| REDIS
    API -->|"SQL :5432"| PG_MAIN
    CRONS -->|"SQL :5432"| PG_MAIN
    CRONS -->|"SQL :5432"| PG_ANA
    WORKERS -->|"XREADGROUP / XACK"| REDIS
    WORKERS -->|"SQL :5432"| PG_MAIN
    KEDA_OP -->|"XINFO GROUPS (TLS+CA)"| REDIS
```

---

## 5. Synthèse des Décisions d'Architecture Cloud

| Domaine | Choix retenu | Justification clé |
|---|---|---|
| **Compute** | **Scaleway Kapsule** (Control Plane gratuit, CNI Cilium) | 2 Node Pools privés : `api-system` (`2x PRO2-S` en prod pour HA/upgrades sans coupure) + `workers` (`1..5x PRO2-S`, ~2 workers `2Gi`/nœud calibrés pour ~26k fichiers/j). |
| **Ingress & TLS** | **Traefik + `cert-manager`** (Let's Encrypt HTTP-01) | Remplace `ingress-nginx` (EOL 2026) ; 1 seul Load Balancer par cluster sur IP statique réservée (`Proxy Protocol v2` + `scw-loadbalancer-use-hostname=true`). |
| **DNS** | **Zone conservée sur OVH** | 7 entrées statiques (`api.*`, `console.*` en `A`, `metabase.*` en `CNAME`) pour une bascule progressive environnement par environnement depuis Scalingo. |
| **Auto-scaling** | **KEDA (`redis-streams`) + HPA `behavior`** | Parité 1:1 avec `document-ia-auto-scaler` (`lagCount=10`, `+1/2min`, `-1/5min` après 5 min de calme), `TriggerAuthentication` TLS+CA, `terminationGracePeriodSeconds: 180` + `XAUTOCLAIM`. |
| **Analytics & dbt** | **PG Analytics 100 % privé + `dbt-transform` CronJob** | Remplace dbt Cloud par `dbt-core` en CronJob K8s (05h30 UTC, juste après `replicate-analytics`) $\rightarrow$ zéro IP publique sur la base Analytics et 100 % souverain. |
| **BI (Metabase)** | **Scaleway Serverless Container (`min_scale=1`)** | Découplé des clusters K8s, attaché directement à `pn-analytics`, image pinnée `@sha256` dans le Registry Scaleway, TLS managé. |
| **Backups & RGPD** | **Snapshots natifs Scaleway (`fr-par`)** | `pg-main` prod : HA 2 nœuds + snapshots 6h–12h conservés **7 jours** (aligné `remove-ppi` & S3 7j). `pg-analytics` : **30 jours** (zéro PPI). `protect=True` en prod. |
| **Observabilité** | **Scaleway Cockpit (Loki + Grafana + AlertManager)** | Dashboards Grafana JSON et règles d'alertes versionnés en code dans une stack dédiée (`stacks/observability`), zéro impact sur le réseau lors des modifications. |

---

## 6. Points d'Arbitrage Équipe / CTO avant Déploiement

1. **Topologie des clusters (Option A vs Option B)** :
   * **Option A (3 clusters symétriques)** : `staging`, `sandbox`, `prod` 100 % isolés physiquement.
   * **Option B (2 clusters : `non-prod` + `prod`)** : `staging` et `sandbox` partagent un cluster (isolés par Namespaces + Cilium, bases/S3 dédiés) $\rightarrow$ **~30–35 % moins cher sur la non-prod**, `prod` 100 % identique et isolée.
2. **Authentification Metabase OSS & Dashboards Publics** :
   * Metabase OSS ne supporte **pas** OpenID Connect (ProConnect) nativement (licence Pro/Enterprise requise).
   * Baseline proposée : auth native email/mot de passe fort + *Public Sharing links* pour les dashboards publics (à valider avec le CTO).
3. **Passage de `document-ia-api` en Multi-Réplicas (`prod`)** :
   * Lancement avec **1 réplica API (`1Gi`)** (identique à la prod actuelle) car `AUTO_MIGRATE=true` au démarrage risque une *race condition* Alembic en multi-pods.
   * Évolution à planifier dans `document-ia` (`pg_advisory_lock` ou `initContainer` de migration) pour passer à $\ge 2$ réplicas + `PodDisruptionBudget`.
