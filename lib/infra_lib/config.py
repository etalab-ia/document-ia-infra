from __future__ import annotations

import os
from dataclasses import dataclass

import pulumi


@dataclass(frozen=True, slots=True)
class InfraContext:
    """Contexte commun partagé par toutes les stacks Pulumi Document IA."""

    env: str
    stack_name: str
    project_id: str
    region: str
    zone: str

    @classmethod
    def from_pulumi(cls) -> InfraContext:
        return cls(
            env=pulumi.get_stack(),
            stack_name=pulumi.get_project(),
            project_id=os.environ.get("SCW_DEFAULT_PROJECT_ID", ""),
            region=os.environ.get("SCW_DEFAULT_REGION", "fr-par"),
            zone=os.environ.get("SCW_DEFAULT_ZONE", "fr-par-1"),
        )

    def resource_name(self, component: str, suffix: str | None = None) -> str:
        """Génère un nom normalisé et isolé par environnement dans le projet unique DocumentIA."""
        parts = ["docia", self.env, component]
        if suffix:
            parts.append(suffix)
        return "-".join(parts).lower()

    def default_tags(self) -> list[str]:
        """Tags Scaleway standards appliqués aux ressources gérées par Pulumi."""
        return [
            "project:document-ia",
            f"env:{self.env}",
            f"stack:{self.stack_name}",
            "managed-by:pulumi",
        ]
