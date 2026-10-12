# The provisioning engine

ISR provisions cloud spokes with **OpenTofu**, shipped inside the image.

## Why OpenTofu and not Terraform

HashiCorp Terraform is licensed **BUSL-1.1** from version 1.6 onward. ISR is
redistributed, so embedding a BUSL binary in its image is the case that licence
restricts — and at minimum it puts a legal review in front of every recipient.

OpenTofu is the **MPL-2.0** fork created for exactly this situation: the same
HCL, the same providers, the same modules. Nothing about how you write or read a
module changes.

ISR **names the engine it found** in every verdict rather than aliasing one tool
to the other. If you install HashiCorp Terraform yourself it is used and
reported as `terraform`; the shipped engine reports as `tofu`. Pretending to be
the other tool is how a licence question becomes invisible.

## One engine, resolved once, for the whole lifecycle

The engine is resolved **before anything billable happens** — discovering there
is no engine *after* an apply has created resources is the worst possible
ordering — and the choice is recorded in the deployment's workspace. `destroy`
then runs whatever ran `apply`. State written by one engine is readable by the
other, but treat that as a courtesy rather than a contract: a hub can be rebuilt
with a different engine than the one that created a spoke, and the recorded
choice is what keeps `destroy` on the engine that wrote the state.

## Where deployment state lives

The workspace holds the `tfstate`, which is the **only** handle that can destroy
a running cloud stack. It lives beside ISR's state database, on the volume you
already persist (`<name>-state:/var/lib/isr`), so it survives a restart of ISR.

For the same reason, a failed `destroy` does not unregister the spoke — that
would drop the last thing in ISR pointing at live infrastructure. ISR reports the
real error and keeps the spoke, so you can fix the cause and retry. `force: true`
unregisters anyway, and says plainly that the infrastructure keeps billing.

## Why an engine at all, rather than cloud SDKs

One integration covers AWS, Azure and GCP.

| | Terraform/OpenTofu | Native cloud SDKs |
| --- | --- | --- |
| Cloud coverage | one integration | three SDKs, three maintenance streams |
| Teardown | `destroy` from recorded state | every inverse operation hand-written |
| Re-run after failure | idempotent | half-applied scripts orphan resources |

## What this changes about credentials

The engine being present is only half of "can ISR act". The other half is a
credential, and the two are reported separately so the blocker is never
ambiguous:

```
can_act : true
engine  : tofu
reason  : Ready to provision from this ISR using tofu. AWS_PROFILE is set in this ISR.
```

```
can_act : false
reason  : Cannot provision from this ISR (tofu is present):
          not signed in to IAM Identity Center — use Sign in on this connection.
```

The second is not a broken toolchain. It is a missing sign-in, and it says so.

## Bundle mode

An air-gapped hub, a policy that forbids the control plane from holding cloud
access, or a cloud ISR cannot reach — all work. ISR emits the complete module
and you apply it elsewhere. Bundle mode is the path ISR **chooses when it cannot
act** directly.
