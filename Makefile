env ?= dev
stack ?= test

.PHONY: help bootstrap stack-init preview up destroy output lint typecheck check
.DEFAULT_GOAL := help

help: ## Affiche cette aide
	@echo "Usage: make <target> [stack=<nom_stack>] [env=<dev|preprod|prod>]"
	@echo ""
	@echo "Variables par défaut : stack=$(stack) | env=$(env)"
	@echo ""
	@echo "Cibles disponibles :"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

bootstrap: ## Initialise une 1ère fois le bucket S3 de state + le secret Scaleway Vault
	@bash scripts/bootstrap.sh

stack-init: ## Crée ou sélectionne la stack Pulumi (stack=$(stack), env=$(env))
	@echo "--> Init/Select stacks/$(stack) ($(env))"
	@pulumi -C stacks/$(stack) stack select $(env) --create

preview: ## Lance un pulumi preview sur stacks/$(stack) pour $(env)
	@echo "--> Preview stacks/$(stack) ($(env))"
	@pulumi -C stacks/$(stack) stack select $(env) --create
	@pulumi -C stacks/$(stack) preview --stack $(env) --diff

up: ## Déploie stacks/$(stack) pour $(env)
	@echo "--> Deploy stacks/$(stack) ($(env))"
	@pulumi -C stacks/$(stack) stack select $(env) --create
	@pulumi -C stacks/$(stack) up --stack $(env)

destroy: ## Détruit les ressources de stacks/$(stack) pour $(env)
	@echo "--> Destroy stacks/$(stack) ($(env))"
	@pulumi -C stacks/$(stack) destroy --stack $(env)

output: ## Affiche les outputs de stacks/$(stack) pour $(env)
	@pulumi -C stacks/$(stack) stack output --stack $(env) --json

lint: ## Vérifie le formatage et le linting Python avec Ruff
	@uv run ruff check lib stacks

typecheck: ## Vérifie le typage statique Python avec Pyright
	@uv run pyright

check: lint typecheck ## Exécute tous les contrôles statiques (ruff + pyright)
