# Document IA — Infrastructure as Code (Pulumi Python 3.14 + Scaleway + Nix)

Dépôt d'Infrastructure as Code (**IaC**) pour le projet **Document IA**, déployé sur le projet Scaleway **`DocumentIA`** (Organisation DINUM).

* **Nix Flakes** : environnement 100 % reproductible (`python314`, `uv`, `pulumi`, `scaleway-cli`, `awscli2`, `jq`, `make`, `openssl`, `gitleaks`, `pre-commit`).
* **Isolation totale de votre machine** : aucune lecture ni écriture dans `~/.pulumi`, `~/.config/scw` ou `~/.aws`.
* **Zéro secret ni identifiant interne dans Git** : ni clés, ni UUID de projet DINUM, ni nom de bucket de state ne sont versionnés.
* **Traçabilité individuelle (Audit Trail / Cockpit Grafana)** : chaque développeur utilise sa propre clé API IAM Scaleway.
* **Pulumi multi-stacks Python 3.14 (`uv` + Pyright + Ruff)** : un seul `.venv` partagé à la racine et une librairie commune `infra_lib`.

> **Documentation technique détaillée (en anglais)** :
> * [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — Architecture globale, diagrammes et décisions techniques (ADRs).
> * [docs/SECURITY_AND_SECRETS.md](docs/SECURITY_AND_SECRETS.md) — Modèle de sécurité, matrice d'isolation locale et matrice IAM Scaleway.
> * [docs/VULNERABILITY_MANAGEMENT_POLICY.md](docs/VULNERABILITY_MANAGEMENT_POLICY.md) — Politique CI/CD de sécurité : OSV-Scanner (Politique D7), Gitleaks, Dependabot et Branch Protection.

---

## Onboarding d'un nouveau développeur (Setup en 5 minutes)

### Étape 1 — Prérequis : Installer Nix et activer les Flakes

Si Nix n'est pas encore installé sur votre machine (macOS ou Linux) :

```bash
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --daemon
```

Fermez puis rouvrez votre terminal, puis activez les Flakes dans `~/.config/nix/nix.conf` :

```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

*(Optionnel)* Si vous utilisez **`direnv`**, il est inclus dans le flake et permettra d'activer l'environnement automatiquement dès que vous entrez dans le répertoire.

---

### Étape 2 — Créer votre clé API IAM personnelle Scaleway

1. Connectez-vous à la [console Scaleway](https://console.scaleway.com) (Organisation DINUM).
2. Vérifiez auprès de l'équipe / admin DINUM que vous avez accès au projet **`DocumentIA`** avec au minimum :
   * `ObjectStorageFullAccess` (pour le backend d'état Pulumi S3 et les buckets applicatifs)
   * `SecretManagerReadOnly` (pour lire `/pulumi/config`)
   * Les droits sur les services provisionnés par les stacks (Kapsule, RDB, VPC, etc.)
   * Le droit côté Organisation de définir le *Preferred Project* de votre clé API (ou demandez à l'admin DINUM de le positionner sur votre clé).
3. Allez dans **IAM & API Keys → API Keys → Generate API key** :
   * **API key bearer** : **Yourself** (clé personnelle, jamais partagée).
   * **Preferred Project for Object Storage** *(obligatoire)* : sélectionnez **`DocumentIA`**.
4. Conservez temporairement :
   * `SCW_ACCESS_KEY` (`SCW...`)
   * `SCW_SECRET_KEY` (UUID)
   * L'UUID du projet **`DocumentIA`** (`SCW_DEFAULT_PROJECT_ID`, visible dans **Project Settings**).

---

### Étape 3 — Cloner le dépôt et lancer `nix develop`

```bash
git clone <url-du-repo>
cd document-ia-infra
nix develop
```

Au premier lancement, le shell Nix fait tout automatiquement :
1. Installe tous les outils nécessaires (Python 3.14, `uv`, Pulumi, `scw`, `awscli2`, etc.) sans toucher à votre système.
2. Synchronise le virtualenv partagé `.venv` via `uv sync`.
3. Isole `PULUMI_HOME` (`.pulumi/`), `SCW_CONFIG_PATH` et `~/.aws`.
4. Vous demande `SCW_ACCESS_KEY` et `SCW_SECRET_KEY` (saisie masquée), tente d'auto-découvrir `SCW_DEFAULT_PROJECT_ID` (ou vous le demande), et propose de les sauver dans **`.env.local`** (`chmod 600`, ignoré par Git).
5. Charge automatiquement depuis **Scaleway Secret Manager** (`/pulumi/config`) :
   * `PULUMI_CONFIG_PASSPHRASE` (écrite dans un fichier temporaire `chmod 600` hors dépôt via `PULUMI_CONFIG_PASSPHRASE_FILE`)
   * `PULUMI_STATE_BUCKET` (utilisé pour configurer `PULUMI_BACKEND_URL`).

Vous devez obtenir :

```text
✅ Environnement Document IA Infra prêt :
   • Python  : Python 3.14.x (venv: .venv)
   • Pulumi  : v3.x.x (PULUMI_HOME=.pulumi)
   • Backend : Scaleway Object Storage (fr-par, profil éphémère)
   • Vault   : PULUMI_CONFIG_PASSPHRASE_FILE (depuis PULUMI_CONFIG_PASSPHRASE) PULUMI_STATE_BUCKET
```

*(Optionnel — activation automatique avec `direnv`)* :
```bash
cp .envrc.example .envrc
direnv allow
```

---

### Étape 4 — Vérifier votre installation

Dans le shell `nix develop` :

```bash
# Installer les hooks locaux pre-commit et pre-push (Ruff + Gitleaks) — une fois par clone
pre-commit install
bash scripts/pre-push

# Vérifier le linting (Ruff), le formatage, le typage strict (Pyright) et les tests (Pytest)
make check

# Vérifier l'absence de secrets dans l'historique Git et exécuter les sondes Gitleaks
make gitleaks

# Vérifier l'accès au backend S3 et à la stack de test (lecture seule)
make preview stack=test env=dev
```

Si `make preview` affiche le plan sans erreur, votre environnement est 100 % opérationnel.

---

## Bootstrap initial (une seule fois par un admin du projet)

> **Les nouveaux développeurs n'ont PAS à exécuter cette étape** si le projet est déjà initialisé sur Scaleway.

Lors de la toute première mise en place sur le projet Scaleway `DocumentIA` (avec les droits `ObjectStorageFullAccess` + `SecretManagerFullAccess`) :

```bash
nix develop
make bootstrap
infra-reload
make up stack=test env=dev
```

Le script idempotent [scripts/bootstrap.sh](scripts/bootstrap.sh) :
1. Crée le bucket Object Storage de state dans `fr-par` et active le **versioning**.
2. Crée le secret protégé `/pulumi/config` (`type=key_value`, `protected=true`) dans **Scaleway Secret Manager** contenant `PULUMI_STATE_BUCKET` et une `PULUMI_CONFIG_PASSPHRASE` aléatoire de 256 bits.

---

## Utilisation quotidienne

Le shell Nix est unique et agnostique de l'environnement : **Pulumi gère les environnements via ses stacks (`dev`, `preprod`, `prod`)**.

```bash
# Afficher toutes les cibles disponibles
make help

# Prévisualiser les changements d'une stack
make preview stack=test env=dev

# Déployer une stack
make up stack=test env=dev

# Consulter les outputs JSON d'une stack
make output stack=test env=dev

# Détruire une stack
make destroy stack=test env=dev

# Recharger le vault / .env.local sans quitter le shell Nix
infra-reload

# Contrôles qualité & tests (Ruff + format + Pyright + Pytest)
make check

# Tests unitaires seuls
make test

# Scan Gitleaks (historique complet + sondes synthétiques)
make gitleaks
```

### Mode hors-ligne (sans accès Scaleway)

Pour éditer du code ou lancer `make check` sans contacter Scaleway :

```bash
INFRA_SKIP_VAULT=1 nix develop
```

### Ajouter un secret propre à un environnement Pulumi

Les secrets applicatifs d'une stack sont chiffrés dans `stacks/<nom>/Pulumi.<env>.yaml` à l'aide de `PULUMI_CONFIG_PASSPHRASE_FILE` :

```bash
pulumi -C stacks/test config set --stack dev --secret ma_cle "ma_valeur"
```

### Ajouter une nouvelle stack

1. Créez `stacks/<nom>/` avec :
   * `Pulumi.yaml` pointant vers le virtualenv partagé :
     ```yaml
     name: <nom>
     description: Description de la stack
     runtime:
       name: python
       options:
         toolchain: uv
         virtualenv: ../../.venv
         typechecker: pyright
     ```
   * `__main__.py` utilisant `InfraContext.from_pulumi()` (`infra_lib`) pour le nommage (`ctx.resource_name(...)`) et les tags (`ctx.default_tags()`).
   * `outputs.py` définissant un `TypedDict` exporté sous `STACK_DATA_KEY` (`stack_data`) et un helper `get_<nom>_stack_output(env)`.
2. Vérifiez avec `make check` puis `make preview stack=<nom> env=dev`.

---

## Structure du dépôt

```text
.
├── flake.nix                  # Environnement Nix reproductible (Python 3.14 + Pulumi + scw)
├── infra.env                  # Config publique générique (région, zone, chemin du secret vault)
├── .env.local.example         # Modèle des clés API personnelles (copié en .env.local, gitignored)
├── .envrc.example             # Modèle direnv (`use flake`)
├── Makefile                   # Commandes opérationnelles (bootstrap, preview, up, destroy, check)
├── pyproject.toml             # Dépendances Python 3.14 (uv), Ruff, Pyright & package infra_lib
├── .github/
│   ├── dependabot.yml         # Mises à jour hebdomadaires uv & github-actions (cooldown 7j)
│   └── workflows/
│       ├── document-ia-infra-ci.yml  # CI : uv lock, uv build, Ruff, Pyright, Pytest, Gitleaks
│       └── osv-scanner.yml    # Scan vulnérabilités OSV-Scanner & Politique D7 (bloquant)
├── .gitleaks.toml             # Règles Gitleaks (Scaleway, Document IA, exclusion .env.local.example)
├── .osv-scanner.toml          # Exceptions temporaires OSV (Politique D7, <= 30j)
├── .pre-commit-config.yaml    # Hooks locaux pre-commit / pre-push (Ruff, Gitleaks, uv lock)
├── docs/
│   ├── ARCHITECTURE.md                  # Architecture détaillée, diagrammes Mermaid & ADRs
│   ├── SECURITY_AND_SECRETS.md          # Modèle de sécurité, isolation locale & matrice IAM Scaleway
│   └── VULNERABILITY_MANAGEMENT_POLICY.md # Politique CI/CD sécurité (OSV/D7, Gitleaks, Dependabot)
├── scripts/
│   ├── load_env.sh                      # Isolation locale + chargement Scaleway Vault + profil S3 éphémère
│   ├── bootstrap.sh                     # Initialisation unique (bucket S3 versionné + secret vault)
│   ├── check_vulnerability_policy.py    # Validateur Politique D7 & déduplication Union-Find OSV
│   ├── verify_gitleaks_synthetic.sh     # Sondes synthétiques Gitleaks & contrôle .env.local.example
│   ├── pre-push                         # Wrapper hook Git pre-push multi-références
│   └── gitleaks_pre_push.sh             # Scan Gitleaks des commits sortants
├── lib/infra_lib/             # Helpers communs (InfraContext, nommage, tags, StackReference typées)
├── tests/                     # Suite de tests Pytest (infra_lib, Politique D7, sonde Gitleaks)
└── stacks/
    └── test/                  # Stack de test initiale (validation backend S3 & Pyright)
```

---

## Dépannage (Troubleshooting)

* **`AccessDenied` sur `ListBuckets` / `CreateBucket` / `ListObjectsV2` alors que la console Scaleway fonctionne** :
  Votre clé API IAM personnelle n'a pas **`DocumentIA`** comme **Preferred Project for Object Storage** (`default_project_id`). Corrigez-le dans la console Scaleway (**IAM & API Keys → API Keys → votre clé → Edit**) ou demandez à l'admin DINUM de l'appliquer.
* **`Secret '/pulumi/config' introuvable ou inaccessible`** :
  * Si le projet n'a jamais été initialisé : lancez `make bootstrap` puis `infra-reload`.
  * Sinon vérifiez `SCW_DEFAULT_PROJECT_ID` dans `.env.local` et que votre compte dispose bien de `SecretManagerReadOnly` sur `DocumentIA`.
* **Nix ignore un fichier nouvellement créé (`error: path ... does not exist`)** :
  Dans un dépôt Git, Nix Flakes ne voit que les fichiers suivis par Git. Ajoutez le fichier avec `git add <fichier>`.
* **Modifier vos identifiants `.env.local`** :
  Éditez `.env.local` (conservez `chmod 600`) puis lancez `infra-reload` dans votre shell Nix.
