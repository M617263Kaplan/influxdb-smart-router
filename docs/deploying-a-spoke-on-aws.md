# Deploying an ISR spoke on AWS

ISR provisions a regional spoke one of two ways. With a [cloud account](cloud-accounts.md)
that verifies, the hub applies the module itself with the OpenTofu engine it
ships, acting through the credential reference you named. Without one, or by
choice, it **emits a Terraform bundle you run yourself** from wherever your
credentials already live. Either way the hub holds a reference, never a key.

That is a deliberate trade. A control plane holding static AWS keys has a blast
radius far larger than one that acts through an instance role, an environment
profile, a Secrets Manager reference or a short-lived SSO session, or that hands
you a bundle: compromise it and you have lost the account, not one service. So
the Provision page is a **generator** first, and the apply happens either in the
hub with a verified account or where your credentials already live.

## What ISR emits

`POST /api/isr/cloud/provision/bundle` returns three things:

| Field | Contents |
| --- | --- |
| `files` | The complete Terraform module — every `.tf` plus the cloud-init template |
| `tfvars` | `terraform.tfvars` for your inputs. **Non-secret values only** |
| `commands` | The exact sequence to run, in order |

The module is **embedded in the ISR binary** and version-locked to it, so the
module you run is always the one your ISR was built against. There is nothing
to clone: the bundle's `files` map *is* the module, and it targets AWS.

Secrets are never in the bundle. `TF_VAR_db_password` and
`TF_VAR_influx_admin_token` are read from your environment at apply time.

## How the instance gets ISR

ISR ships as a `docker load` image tarball attached to its GitHub release, so
there is no registry image to pull. The instance loads its image from **its own
S3 bucket**, using the IAM instance role it already has. No GitHub token, no
registry credential, and no static AWS key ever reaches the box.

You stage the tarball *after* `terraform apply`, because the bucket does not
exist until then. Bootstrap accounts for that: it polls S3 for **30 minutes** and
starts the moment the object lands. Apply-then-upload is the natural operator
order, so it heals rather than fails.

The tarball is **SHA256-verified before it is loaded**. An image tarball is
executable content, and on this path a truncated multipart upload is far likelier
than a tampered one — either way, loading it unverified is not worth the risk.

## The sequence

```bash
# 0) Write the module. The bundle's "files" map IS the module.
mkdir -p isr-terraform/templates && cd isr-terraform
#    (save each key as a file; templates/ is a subdirectory)

# 1) Authenticate. <your-profile> is the NAMED PROFILE in ~/.aws/config
aws sso login --profile <your-profile>; export AWS_PROFILE=<your-profile>
aws sts get-caller-identity

# 2) Provide the two secrets via env (never commit them)
export TF_VAR_db_password='<choose-a-strong-postgres-password>'
export TF_VAR_influx_admin_token='apiv3_<your-influxdb-admin-token>'

# 3) Pick your engine. Both read this module unchanged.
TF=tofu   # or: TF=terraform

# 4) Save the generated tfvars as terraform.tfvars here, then:
$TF init
$TF plan      # review what will be created
$TF apply     # creates billable resources

# 5) Stage the image into the bucket the apply just created
BUCKET=$($TF output -raw influx_bucket)
gh release download <TAG> -R M617263Kaplan/influxdb-smart-router -p '*linux-amd64-image.tar.gz' -p SHA256SUMS.txt
aws s3 cp isr-<TAG>-linux-amd64-image.tar.gz s3://$BUCKET/bootstrap/isr-linux-amd64-image.tar.gz
aws s3 cp SHA256SUMS.txt s3://$BUCKET/bootstrap/SHA256SUMS.txt

# 6) Watch it come up
$TF output -raw console_url
```

## Sizing

`root_volume_gb` defaults to **300 GiB** in the bundle, not the 40 GiB a plain
control plane needs. A migration host stores the backup archive *and* the
per-worker unpacked-shard scratch, and line protocol runs **10–22× the size of
the TSM it came from**. A 66 GiB archive does not fit in 40 GiB, and a disk that
fills partway through a multi-hour import fails hours in.

Set `instance_type` for the work, not the idle state: `c6i.4xlarge` for a
migration host, the `m6i.xlarge` default for a routing spoke.

## Getting a backup archive onto the instance

Migration engines read archives **locally, in place** from the import root —
`/var/lib/isr/import` inside the container. Replication moves *points*, and a
backup is opaque TSM, so the archive itself reaches the instance by an
out-of-band copy that you perform.

`/opt/isr/data` on the instance is bind-mounted to `/var/lib/isr`, so archives
land at **`/opt/isr/data/import/`** — on the root EBS volume sized by
`root_volume_gb` (the archive *plus* per-worker unpacked-shard scratch has to
fit; see Sizing above).

The route that scales to tens of GB is the deployment's **own S3 bucket** —
the same one the apply created for image staging. Multipart upload is
resumable (it matters over a home uplink), the hub does not have to stay up,
and the instance's IAM role already covers the download leg. Both legs are
TLS.

Find the bucket name — it is the `influx_bucket` Terraform output:

```sh
# Spoke deployed FROM THE HUB (Fleet → create a spoke): the workspace lives
# inside the hub container. List them, then read the output — a workspace
# left over from a failed attempt has no outputs; the live one answers.
docker exec isr ls /var/lib/isr/deployments/
docker exec isr sh -c 'cd /var/lib/isr/deployments/<workspace> && tofu output -raw influx_bucket'

# Spoke applied from a BUNDLE on your workstation: same output, your directory.
terraform output -raw influx_bucket
```

Stage it (`instance_id` is also a Terraform output):

```sh
# from the machine holding the archive
aws s3 cp <archive>.tar "s3://<bucket>/import/"

# on the instance
aws s3 cp "s3://<bucket>/import/<archive>.tar" /opt/isr/data/import/
cd /opt/isr/data/import && tar xf <archive>.tar && rm <archive>.tar
```

Delete the tar after extracting — keeping both costs the disk you sized for
scratch. The extracted directory appears in the console's backup inventory on
the Migration page with no further registration. The staged copy in the
bucket is billable too — remove it when you tear the deployment down.

## Ports

| Port | Purpose | Ingress variable |
| --- | --- | --- |
| `9800` | Operator console **and** control API — one listener | `console_ingress_cidrs` |
| `8086` | Data plane, v1/v2 write + query | `gateway_ingress_cidrs` |
| `8181` | Data plane, v3 write + FlightSQL | `gateway_ingress_cidrs` |
| `22` | SSH | `console_ingress_cidrs` |

Both CIDR lists default to empty. Set them — an unset list is not a wildcard,
and the apply will not silently open the box to the internet.

## Enrollment is hub-initiated

The hub registers the spoke and **dials it**; spokes never call home. There is
no enrollment token to bake into the instance.

Front the instance with TLS first — the fleet channel requires `https`, and a
plain-HTTP endpoint is refused rather than silently downgraded. Then:

**Fleet → Spokes → Add**, with the spoke's name and its https endpoint.

Once enrolled, `GET /api/isr/fleet/jobs` reports migrations across the hub and
every spoke in one response, so watching a spoke's work never means opening its
console.

## If the console shows "Bundle mode"

That is the expected state, not a failure. A containerised hub ships without
Terraform or cloud CLIs by design, so a toolchain check that reports them missing
is reporting that the design is intact. Press **Generate bundle** and run it
where your AWS session lives.
