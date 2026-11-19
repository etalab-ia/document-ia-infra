from __future__ import annotations

import pulumi
from outputs import TestStackOutput

from infra_lib import STACK_DATA_KEY, InfraContext

ctx = InfraContext.from_pulumi()
config = pulumi.Config()
message = config.get("message") or f"hello-document-ia-{ctx.env}"

# -----------------------------------------------------------------------------
# Exemple de ressource Scaleway (à décommenter dès réception des droits DINUM)
# -----------------------------------------------------------------------------
# import pulumiverse_scaleway as scaleway
#
# test_bucket = scaleway.object.Bucket(
#     ctx.resource_name("test-bucket"),
#     name=ctx.resource_name("test-bucket"),
#     project_id=ctx.project_id,
#     region=ctx.region,
#     tags={tag.split(":")[0]: tag.split(":")[1] for tag in ctx.default_tags()},
# )

output: TestStackOutput = {
    "env": ctx.env,
    "stack_name": ctx.stack_name,
    "region": ctx.region,
    "sample_resource_name": ctx.resource_name("sample"),
    "tags": ctx.default_tags(),
    "message": message,
}

pulumi.export(STACK_DATA_KEY, output)
