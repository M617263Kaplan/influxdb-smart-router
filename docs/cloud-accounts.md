# Cloud accounts

A **cloud account** is a named cloud identity ISR can provision through. It
stores a credential **reference** — never a key — and it can be re-checked, so
"can ISR act as this account?" has an answer *before* anything is created.

## Why not just take the keys

The alternative is typing an access key, a secret and a session token into the
deploy form, per deploy. Two problems, and the second is worse than the first.

A long-lived secret sits in a web form and travels in a request body. And cloud
credentials **go stale invisibly**: an SSO session that expired an hour ago looks
exactly like a working one. You find out when `terraform apply` is already
running and half a stack is standing — the most expensive moment to discover it,
and the hardest to unwind.

## What a reference looks like

| Reference | Meaning |
| --- | --- |
| `instance-role` | ISR runs on an instance with an IAM role. **No secret exists anywhere.** Verified against the instance metadata service, so it is refused rather than assumed on a host that has no role |
| `env:NAME` | The named environment variable holds the value or profile. ISR checks it is actually set **in its own environment** — not the operator's shell |
| `secretmanager:arn:…` | Terraform resolves it at apply time. ISR reports it as unverified rather than implying it checked |
| `AKIA…` | **Refused at the API.** A connection must never become a place secrets live |

**Refresh** re-probes on demand. Run it before a deploy if your session may
have rolled.

## The verdict decides the path

Provisioning directly from ISR needs **two** things: a resolvable credential
**and** a provisioning engine in the ISR process. A control plane holding your
cloud credentials has a far larger blast radius than one that hands you a
bundle, so a hub that lacks either simply hands you the bundle.

So the verdict is one of:

- **● Ready** — ISR provisions directly.
- **○ Bundle mode** — ISR emits Terraform for you to apply where the toolchain
  and credentials already live.

Bundle mode is a **supported path, not a failure**. A deploy against a
connection that cannot act returns the reason, points at the bundle, and
creates nothing; the console hands the bundle over with your inputs carried
across so nothing is retyped.

That is the point of the connection: the direct-vs-bundle split becomes
something ISR decides and explains, instead of two pages an operator has to
know to choose between.

The verdict always carries a **reason**. A bare yes/no sends an operator
hunting — the reason is what tells them whether to fix something or accept the
bundle path.

## Using one

1. **Connections → Cloud accounts.** Name, provider, default region, and a
   credential reference.
2. Read the verdict. It tells you which path a deploy will take.
3. **Fleet → create a spoke.** Pick the account; the picker repeats the verdict
   before you commit.

## Instance roles

An ISR running **on EC2 with an instance role** reports ● Ready with no secret
stored anywhere, which makes spoke creation genuinely one-click. A laptop hub
takes the bundle path by design: putting a provisioning engine and your cloud
keys inside a container on a workstation is a worse trade than generating a
bundle.
