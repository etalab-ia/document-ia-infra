from __future__ import annotations

from typing import TypedDict, cast

import pulumi

from infra_lib import get_stack_data


class TestStackOutput(TypedDict):
    env: str
    stack_name: str
    region: str
    sample_resource_name: str
    tags: list[str]
    message: str


def get_test_stack_output(env: str) -> pulumi.Output[TestStackOutput]:
    """Récupère les outputs typés de la stack `test` pour un environnement donné."""
    return cast(pulumi.Output[TestStackOutput], get_stack_data("test", env))
