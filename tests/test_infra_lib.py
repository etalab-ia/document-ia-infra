from __future__ import annotations

from dataclasses import FrozenInstanceError
from typing import Any, cast
from unittest.mock import MagicMock

import pulumi
import pytest

import infra_lib
from infra_lib import (
    STACK_DATA_KEY,
    InfraContext,
    get_stack_data,
    get_stack_reference,
)


def test_public_exports() -> None:
    """Vérifie que l'interface publique de `infra_lib` expose tous les symboles attendus."""
    assert set(infra_lib.__all__) == {
        "InfraContext",
        "STACK_DATA_KEY",
        "get_stack_data",
        "get_stack_reference",
    }
    assert STACK_DATA_KEY == "stack_data"


def test_infra_context_from_pulumi_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    """`from_pulumi` applique les valeurs par défaut sans variables Scaleway."""
    monkeypatch.setattr(pulumi, "get_stack", lambda: "dev")
    monkeypatch.setattr(pulumi, "get_project", lambda: "network")
    monkeypatch.delenv("SCW_DEFAULT_PROJECT_ID", raising=False)
    monkeypatch.delenv("SCW_DEFAULT_REGION", raising=False)
    monkeypatch.delenv("SCW_DEFAULT_ZONE", raising=False)

    ctx = InfraContext.from_pulumi()

    assert ctx == InfraContext(
        env="dev",
        stack_name="network",
        project_id="",
        region="fr-par",
        zone="fr-par-1",
    )


def test_infra_context_from_pulumi_with_env_vars(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """`from_pulumi` lit les variables d'environnement Scaleway définies."""
    monkeypatch.setattr(pulumi, "get_stack", lambda: "prod")
    monkeypatch.setattr(pulumi, "get_project", lambda: "storage")
    monkeypatch.setenv("SCW_DEFAULT_PROJECT_ID", "11111111-2222-3333-4444-555555555555")
    monkeypatch.setenv("SCW_DEFAULT_REGION", "nl-ams")
    monkeypatch.setenv("SCW_DEFAULT_ZONE", "nl-ams-2")

    ctx = InfraContext.from_pulumi()

    assert ctx.env == "prod"
    assert ctx.stack_name == "storage"
    assert ctx.project_id == "11111111-2222-3333-4444-555555555555"
    assert ctx.region == "nl-ams"
    assert ctx.zone == "nl-ams-2"


@pytest.mark.parametrize(
    ("env", "component", "suffix", "expected"),
    [
        ("dev", "bucket", None, "docia-dev-bucket"),
        ("preprod", "Bucket", "State", "docia-preprod-bucket-state"),
        ("PROD", "DB", "", "docia-prod-db"),
        ("dev", "vpc", "private-01", "docia-dev-vpc-private-01"),
    ],
)
def test_infra_context_resource_name(
    env: str,
    component: str,
    suffix: str | None,
    expected: str,
) -> None:
    """`resource_name` génère un identifiant normalisé en minuscules et isolé par environnement."""
    ctx = InfraContext(
        env=env,
        stack_name="core",
        project_id="proj-id",
        region="fr-par",
        zone="fr-par-1",
    )
    assert ctx.resource_name(component, suffix=suffix) == expected


def test_infra_context_default_tags() -> None:
    """`default_tags` retourne les tags Scaleway standards avec l'environnement et la stack."""
    ctx = InfraContext(
        env="preprod",
        stack_name="database",
        project_id="proj-id",
        region="fr-par",
        zone="fr-par-1",
    )
    assert ctx.default_tags() == [
        "project:document-ia",
        "env:preprod",
        "stack:database",
        "managed-by:pulumi",
    ]


def test_infra_context_is_frozen() -> None:
    """`InfraContext` est immuable (`frozen=True`)."""
    ctx = InfraContext(
        env="dev",
        stack_name="test",
        project_id="",
        region="fr-par",
        zone="fr-par-1",
    )
    with pytest.raises(FrozenInstanceError):
        cast(Any, ctx).env = "prod"


def test_get_stack_reference_uses_organization_prefix(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """`get_stack_reference` construit la référence `organization/<project>/<env>`."""
    fake_ref = MagicMock(name="stack_ref")
    stack_ref_cls = MagicMock(return_value=fake_ref)
    monkeypatch.setattr(pulumi, "StackReference", stack_ref_cls)

    ref = get_stack_reference("network", "prod")

    stack_ref_cls.assert_called_once_with("organization/network/prod")
    assert ref is fake_ref


def test_get_stack_data_requires_standard_output_key(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """`get_stack_data` récupère la clé d'output standard `stack_data` sur la StackReference."""
    fake_output = MagicMock(name="stack_data_output")
    fake_ref = MagicMock(name="stack_ref")
    fake_ref.require_output.return_value = fake_output
    stack_ref_cls = MagicMock(return_value=fake_ref)
    monkeypatch.setattr(pulumi, "StackReference", stack_ref_cls)

    output = get_stack_data("database", "preprod")

    stack_ref_cls.assert_called_once_with("organization/database/preprod")
    fake_ref.require_output.assert_called_once_with(STACK_DATA_KEY)
    assert output is fake_output
