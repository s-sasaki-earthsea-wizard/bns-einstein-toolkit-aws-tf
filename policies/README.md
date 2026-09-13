# IAM policies applied by hand

Two documents live here. Neither is applied by Terraform: they describe what
the *human* principal carries, and a credential Terraform authenticates with
cannot be managed by Terraform without the apply that fails half way leaving
nothing to authenticate with.

| File | Attached to | By |
| --- | --- | --- |
| `terraform-operator.json` | the `bns-terraform-operator` **role** | `stacks/bootstrap`, which reads this file |
| `terraform-bootstrap-user.json` | the `bns` **user** | an administrator, by hand |

`terraform-bootstrap-user.json` narrows the user to two things: assuming the
project's roles, and rotating its own access key. It names both roles
explicitly —

```
arn:aws:iam::*:role/bns-terraform-operator
arn:aws:iam::*:role/bns-observer
```

— and not `role/bns-*`. A wildcard there would recreate the escalation
shape this whole arrangement is about: create a role whose name starts with
the prefix, attach more to it, assume it.

(That said, in this account neither entry is what makes the assumption work.
Both trust policies name the user's ARN directly, and a same-account trust
policy that names its principal is sufficient on its own — which is why
`make login` succeeds today against a user policy containing no `sts:` action
at all. The list is here to state the intent, not to carry it.)

The read-only `bns-observer` role itself is not in this directory. It is
created by `stacks/foundation`, with its policy written inline as a Terraform
document, because unlike the two above nothing about it needs an
administrator or a simulation before attachment.

## The operator policy

`terraform-operator.json` is the single policy the Terraform principal needs.
It replaces the AWS managed policies rather than supplementing them — attach
it alone.

Verify it before attaching, and again after:

```bash
make check-permissions-policy    # simulate the document, attached to nothing
make check-permissions PRINCIPAL=arn:aws:iam::<account-id>:user/<operator>
```

Both must end in `OK: all 115 actions permitted`.

## Scoping

Resources are fenced by the `bns-` name prefix wherever AWS supports
resource-level permissions:

| Service | Scope |
| --- | --- |
| S3 | `arn:aws:s3:::bns-*` and its objects |
| ECR | `repository/bns*` |
| IAM | `role/bns-*`, `instance-profile/bns-*` |
| SNS | `bns-*` topics |
| EventBridge | `rule/bns-*` |
| Budgets | `budget/bns-*` |
| SSM parameters | only `/aws/service/ami-amazon-latest/*`, the public AMI index |

Four things cannot be scoped, and are granted on `*` deliberately:

- **EC2.** Its ARNs carry no project name, so no prefix pattern can separate
  this project's VPC from any other. A pattern like
  `arn:aws:ec2:*:*:*/*` looks restrictive but matches every EC2 resource in
  the account — it is `*` written the long way.
- **Cost Explorer.** `ce:*` has no resource-level permissions at all.
- **Session Manager.** `ssm:StartSession` targets an instance ARN, which
  brings back the EC2 problem.
- **`ec2:GetSpotPlacementScores`, `servicequotas:*`, `ecr:GetAuthorizationToken`,
  `s3:ListAllMyBuckets`.** Account-wide queries with no resource to scope to.

## The EC2 guard

Because EC2 cannot be scoped by name, the policy carries an explicit `Deny`
on destructive EC2 actions whose target is not tagged `Project=bns`:

```json
"Condition": { "StringNotEquals": { "aws:ResourceTag/Project": "bns" } }
```

Provider `default_tags` stamps that tag on everything this project creates,
so Terraform can still delete its own resources. An untagged instance, or one
belonging to another project in the same account, returns `explicitDeny` — and
an explicit Deny cannot be overridden by any Allow.

Verified behaviour:

| Target | `ec2:TerminateInstances` |
| --- | --- |
| `Project=bns` | allowed |
| tag absent | explicitDeny |
| `Project=some-other-project` | explicitDeny |

The trade: a resource that somehow ends up untagged becomes undeletable
through this principal, and `terraform destroy` will stop on it. That is the
guard working, not a bug — retag the resource or delete it with another
principal.

## What this policy does not grant

No `iam:AttachUserPolicy`, no `iam:CreatePolicy`, no ability to touch roles
outside `bns-*`. The principal therefore cannot escalate itself to
administrator, which is the property the earlier `IAMFullAccess` arrangement
did not have.

## Attaching it

```bash
aws iam create-policy \
  --policy-name bns-terraform-operator \
  --policy-document file://policies/terraform-operator.json

aws iam attach-user-policy \
  --user-name <operator> \
  --policy-arn arn:aws:iam::<account-id>:policy/bns-terraform-operator

# Detach anything it replaces, including the broad managed policies.
aws iam list-attached-user-policies --user-name <operator>
```

Updating it later means creating a new policy *version*:

```bash
aws iam create-policy-version \
  --policy-arn arn:aws:iam::<account-id>:policy/bns-terraform-operator \
  --policy-document file://policies/terraform-operator.json \
  --set-as-default
```
