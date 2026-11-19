from __future__ import annotations

from typing import Any

import pulumi

STACK_DATA_KEY = "stack_data"


def get_stack_reference(project_name: str, env: str) -> pulumi.StackReference:
    """Retourne une StackReference pour le backend S3 auto-hébergé (préfixe 'organization')."""
    return pulumi.StackReference(f"organization/{project_name}/{env}")


def get_stack_data(project_name: str, env: str) -> pulumi.Output[Any]:
    """Récupère l'output standard `stack_data` exporté par une autre stack."""
    return get_stack_reference(project_name, env).require_output(STACK_DATA_KEY)
