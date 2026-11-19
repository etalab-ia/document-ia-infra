{
  description = "Document IA Infra — Environnement Nix reproductible (Pulumi Python 3.14 + Scaleway)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            name = "document-ia-infra";

            packages = with pkgs; [
              python314
              uv
              pulumi
              pulumiPackages.pulumi-python
              scaleway-cli
              awscli2
              jq
              gnumake
              openssl
              direnv
            ];

            shellHook = ''
              # Résolution de la racine du dépôt (contenant flake.nix)
              _dir="$PWD"
              while [ "$_dir" != "/" ] && [ ! -f "$_dir/flake.nix" ]; do
                _dir="$(dirname "$_dir")"
              done
              if [ -f "$_dir/flake.nix" ]; then
                export PROJECT_ROOT="$_dir"
              else
                export PROJECT_ROOT="$PWD"
              fi
              unset _dir

              # Forcer uv à utiliser le Python 3.14 fourni par Nix (zéro téléchargement externe)
              export UV_PYTHON="${pkgs.python314}/bin/python3.14"
              export UV_PYTHON_DOWNLOADS="never"

              # Synchronisation du virtualenv partagé (.venv à la racine)
              if [ -f "$PROJECT_ROOT/pyproject.toml" ]; then
                if [ -f "$PROJECT_ROOT/uv.lock" ]; then
                  (cd "$PROJECT_ROOT" && uv sync --frozen --quiet) || (cd "$PROJECT_ROOT" && uv sync --quiet)
                else
                  (cd "$PROJECT_ROOT" && uv sync --quiet)
                fi
                if [ -f "$PROJECT_ROOT/.venv/bin/activate" ]; then
                  # shellcheck disable=SC1091
                  source "$PROJECT_ROOT/.venv/bin/activate"
                fi
              fi

              # Chargement isolé des credentials Scaleway, du vault Secret Manager et du backend S3 Pulumi
              # shellcheck disable=SC1091
              source "$PROJECT_ROOT/scripts/load_env.sh"

              # Commande utilitaire pour recharger .env.local + vault sans quitter le shell Nix
              infra-reload() {
                unset SCW_ACCESS_KEY SCW_SECRET_KEY SCW_DEFAULT_PROJECT_ID
                # shellcheck disable=SC1091
                source "$PROJECT_ROOT/scripts/load_env.sh"
              }
            '';
          };
        }
      );
    };
}
