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
Provisioning answers with the engine and image it chose, and Operations →
Object Store shows the store's health.

On Kubernetes, ISR creates the store inside each cluster's namespace on a
PersistentVolumeClaim: RustFS for a new namespace, and the MinIO store a
namespace was created with for one made by an earlier release. See
[Running ISR on Kubernetes](install-kubernetes.md).

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
