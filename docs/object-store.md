# The object store behind your cluster

InfluxDB 3 Enterprise keeps its data, catalogue and write-ahead log in an
object store, and every node of a cluster shares it. ISR either runs that store
for you or uses one you already have.

## The store ISR runs for you

On Docker, Getting Started and **Time to Awesome** bring up a managed
S3-compatible store on the same host, make the bucket, and point every node at
it. Nothing needs configuring.

| Situation | What ISR runs |
| :-- | :-- |
| A new install | **RustFS** (Apache-2.0), a MinIO-compatible S3 server, on a Docker volume |
| RustFS's image cannot be pulled | **VersityGW** (Apache-2.0), from a different publisher, so one project withdrawing an image cannot stop an install |
| You gave ISR a MinIO AIStor licence | **MinIO AIStor**, with your licence |
| An install whose store MinIO already wrote | A MinIO server, so that data stays readable; ISR never points a different server at it |
| You named an image | That image, and only that image |

The store keeps the name `isr-minio` and port 9000 on the cluster network
whatever runs in it, so clusters and nodes created earlier keep finding it.
Provisioning answers with the engine and image it chose, and Monitor →
Object Store shows the store's health.

On Kubernetes, ISR creates the store inside each cluster's namespace on a
PersistentVolumeClaim: RustFS for a new namespace, and the MinIO store a
namespace was created with for one made by an earlier release. See
[Running ISR on Kubernetes](install-kubernetes.md).

## Encrypting the link to the store

Every write-ahead log, Parquet file and catalogue change a node writes travels
to the object store. **Security → Cluster TLS, Step 5** encrypts that link for
every cluster on the host in one switch:

- ISR issues the store a certificate from the same authority that signs your
  node certificates, and restarts the store on HTTPS. Its data, credentials and
  server stay as they were.
- ISR then recreates each node on the store, one at a time and compactor last,
  trusting that authority and with plain HTTP switched off, so no node can fall
  back to an unencrypted connection.
- ISR's write queue holds writes that arrive while the store restarts and
  delivers them when it is back.
- **Verify** checks the result the way a client would: trusting only ISR's
  authority the store answers; trusting only public roots, or over plain HTTP,
  it refuses; and every node is checked for its settings.
- Nodes added later, by scaling, an upgrade or a Cluster TLS change, start on
  HTTPS too.

**Turn off encryption** reverses it the same way. To start a new install with
the link already encrypted, set `ISR_OBJECT_STORE_TLS=on` on the ISR container
before the store is first provisioned.

This applies to the store ISR runs on Docker, with InfluxDB 3 Enterprise 3.10.3
or later on every node; ISR checks each node's image before it switches. If a
container ISR did not launch uses the store, the switch stops and names it:
recreate that container yourself afterwards with `isr-ca.crt` named by
`INFLUXDB3_OBJECT_STORE_TLS_CA`, or pass `{"force": true}` to
`POST /api/isr/object-store-tls/enable`.

## Watching the store

**Monitor → Object Store** opens with a Store card: the server and its
version, its drives, capacity with a time-to-full, healing, objects and
per-bucket usage. ISR reads them from RustFS or MinIO every minute with the
credentials it provisioned the store with. VersityGW and a store you bring are
checked for reachability; their request traffic is in the node counters below
the card.

| Condition | Alert |
| :-- | :-- |
| The store does not answer | Critical, until it does |
| The store answers but cannot take writes, for example after losing a drive (it gives the reasons) | Warning |
| A drive is not healthy or is offline | Error |
| A drive is 80% full | Warning |
| A drive is 90% full, or will be full within a day at the current rate | Error |
| Fewer than 5% of a drive's inodes are free | Warning |
| Healing has run for more than 30 minutes | Warning |
| The drives' error counters are rising | Warning |
| ISR cannot read the store's health | Warning |

Each alert resolves on its own when the condition clears. A store ISR restarts
on purpose, for example while encrypting the link, raises nothing.

Request latency comes from the nodes' own measurements: GET and PUT at the
50th and 95th percentile, and time to first byte, over the last five minutes.
The Command Center's storage view shows PUT p95, GET p95 and the errors of the
last hour, and ISR's `/metrics` exports `isr_objectstore_*` for your own
dashboards.

## Choosing the server yourself

Set these on the ISR container (with `-e` on `docker run`, or `extraEnv` in the
Helm chart). ISR reads them when it next provisions the store.

| Variable | Effect |
| :-- | :-- |
| `ISR_OBJECT_STORE_IMAGE` | Run this S3-compatible image instead, for example a copy in your own registry. ISR does not fall back from an image you named; if it cannot be pulled, provisioning says so. |
| `ISR_OBJECT_STORE_ENGINE` | `versitygw`, `rustfs` or `minio`, when the image name does not say which server it is, so ISR passes the right settings. |
| `ISR_AISTOR_LICENSE_FILE` | Path, inside the ISR container, to a MinIO AIStor licence file. ISR then runs `quay.io/minio/aistor/minio` with it. |
| `ISR_AISTOR_LICENSE` | The licence text itself, instead of a file. |

### MinIO AIStor

AIStor is MinIO's current server. You never need it: the default store needs
no licence. AIStor needs a licence file to serve requests; without one it starts
but refuses every S3 call, so ISR only runs it when you provide one. MinIO's
Free tier licence covers a single host, which is what the managed store is.
Download the licence, mount it into the ISR container, and point ISR at it:

```bash
docker run -d --name isr … \
  -v "$HOME/minio/minio.license:/etc/isr/minio.license:ro" \
  -e ISR_AISTOR_LICENSE_FILE=/etc/isr/minio.license \
  isr:v<version>-arm64 --config /etc/isr/config.yaml
```

ISR keeps a copy of the licence beside the store's credentials and starts
AIStor with `--license`. An install whose store MinIO already wrote can move to
AIStor the same way, because AIStor reads MinIO's data.

## Bringing your own store

Getting Started's object-store step also takes AWS S3, any S3-compatible
endpoint (an on-premises appliance, a NAS, another cloud), Azure Blob or Google
Cloud Storage. ISR validates the credentials and makes the bucket before the
first node is launched, and names the endpoint when the bucket cannot be made.
A cloud spoke on AWS defaults to S3 through its instance profile.

## If provisioning fails

The express path keeps your administrator account and offers **Retry from this
step**; fix the cause and press it, and the path carries on from where it
stopped. Getting Started is available as well. The error says which images were
tried, and when the store already holds MinIO data, which variable to set to
keep it.
