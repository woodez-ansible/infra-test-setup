# Deploying your app to the homelab Kubernetes cluster with GitHub Actions

You push to `main` and GitHub Actions builds your container, pushes it to GitHub
Container Registry (GHCR) and deploys it to the cluster. Your app then answers at
`http://<app>.apexkube.xyz/`. This guide covers what you need in your repo and how to
work with the result.

## How it works

```
git push (main)
  └─► build job   (GitHub-hosted runner, ubuntu-latest)
        docker build ─► ghcr.io/woodez/<repo>:<commit-sha>
  └─► deploy job  (runs-on: k8s-deploy, a runner pod inside the cluster)
        kubectl apply k8s/*.yaml ─► kubectl rollout status
                                         │
        http://<app>.apexkube.xyz/ ◄── Gateway 192.168.2.240 ◄── your Pods
```

- **Your app gets its own namespace, named after it.** The pipeline's credentials only
  work there, so it can't affect other apps or the cluster itself.
- **Builds run on GitHub's servers.** Only the short deploy step runs in the cluster,
  on a runner pod that starts fresh for every job and is deleted afterwards.
- **Each image is tagged with the commit it was built from**, e.g. `ghcr.io/woodez/myapp:3f9c2a1b7d4e`.
  You always know what's running, and you roll back by redeploying an older commit.

## 1. Ask an admin to onboard your app

Send them:

- **the repo**, e.g. `woodez/myapp`. It must be in the `woodez` org.
- **the app name**: lowercase letters, digits and `-`, at most 32 characters, e.g.
  `myapp`. It becomes the namespace name and the hostname `myapp.apexkube.xyz`.

The admin runs one playbook. It creates your namespace and adds these to your repo
(Settings → Secrets and variables → Actions):

| Kind | Name | Value |
|---|---|---|
| secret | `KUBE_TOKEN` | deploy token for your namespace |
| secret | `KUBE_CA` | cluster CA certificate |
| variable | `KUBE_NAMESPACE` | your app name |
| variable | `APP_NAME` | your app name |
| variable | `APP_HOSTNAME` | `<app>.apexkube.xyz` |

Don't edit or copy these. If `KUBE_TOKEN` leaks, ask the admin to rotate it.

## 2. Add the files to your repo

Copy these from the infra repo (`infra-test-setup/examples/`):

```
your-repo/
├── Dockerfile                    # yours (see requirements below)
├── .github/workflows/deploy.yml  # copy examples/github-actions/deploy.yml as-is
└── k8s/
    ├── deployment.yaml           # copy examples/github-actions/k8s/*, then adjust
    ├── service.yaml
    └── httproute.yaml
```

Leave the placeholders `__APP__`, `__IMAGE__` and `__HOST__` in the `k8s/*.yaml` files
as they are. The deploy job replaces them on every run. Every `*.yaml` file in `k8s/`
is applied, so you can add more, such as a ConfigMap, a CronJob or a PVC.

For a complete working example, see the reference repo
[`woodez/k8s-deploy-demo`](https://github.com/woodez/k8s-deploy-demo). It's exactly
these templates plus `examples/demo-app/` (`app.py` + `Dockerfile`), and it deploys in
about 75 seconds.

### Your container must

| Requirement | Why | Change it |
|---|---|---|
| listen on **port 8080** (also passed as `$PORT`) | Service and probes target it | `containerPort` in `deployment.yaml` |
| answer **`GET /healthz`** with 200 when ready | readiness/liveness probes | the probe `path`s |
| run as a **non-root numeric UID** (e.g. `USER 10001`) | `runAsNonRoot: true` | don't remove it; the namespace's security policy expects it |
| be built for **linux/amd64** | cluster nodes are x86_64 | already set in the workflow |
| fit **64 Mi–256 Mi RAM, 50m–500m CPU** per container | namespace quota | `resources` in `deployment.yaml` (see limits below) |

## 3. Push to `main`

```bash
git add Dockerfile .github/workflows/deploy.yml k8s/
git commit -m "Deploy to homelab k8s"
git push origin main
```

Watch it under **Actions → build-and-deploy**. A successful run ends with
`deployment "myapp" successfully rolled out` and a summary line with the image and
URL. The first run takes longer because there's no build cache yet.

Other branches and pull requests can still build, but the deploy job only runs for
`main`. To redeploy without a code change, use **Actions → build-and-deploy → Run
workflow** on `main`.

## 4. Reach your app

The Gateway serves every app on one IP and picks the app by hostname.

- **From the LAN:** once `*.apexkube.xyz` points at `192.168.2.240` in your DNS (router
  override or `/etc/hosts`), browse to `http://myapp.apexkube.xyz/`.
- **Without DNS:**
  ```bash
  curl -H 'Host: myapp.apexkube.xyz' http://192.168.2.240/
  ```
- **Or add one line** to `/etc/hosts` on your machine:
  `192.168.2.240 myapp.apexkube.xyz`

This is plain HTTP on the LAN; the site isn't public on the internet. If you need
public access or HTTPS, ask an admin.

## 5. Working with your deployment

You can inspect your namespace with `kubectl` if the admin gives you a kubeconfig for
it. Otherwise, use the workflow logs and the **Summary** step of each run.

```bash
kubectl -n myapp get deploy,pods,svc,httproute
kubectl -n myapp logs deploy/myapp --tail=100 -f
kubectl -n myapp describe pod <pod>            # why it isn't starting
kubectl -n myapp rollout history deploy/myapp
```

**Roll back**, by either:

- **Reverting the commit and pushing,** which is the preferred way because it keeps
  the pipeline the source of truth.
- **Running the workflow manually on an older commit:** check out the old commit on a
  branch, then merge it to `main`.
- **Using `kubectl -n myapp rollout undo deploy/myapp`.** This is quick, but the next
  push redeploys the latest code.

**Config and secrets:** put non-secret settings in a ConfigMap in `k8s/`. For real
secrets, ask the admin to create a Kubernetes Secret in your namespace, then reference
it with `envFrom` or `env.valueFrom.secretKeyRef`. Never commit secret values to the repo.

**Storage:** a PersistentVolumeClaim in `k8s/` gets a volume on the default
`local-path` storage. It lives on one node and isn't replicated, so treat it as a
cache, not a database of record.

## 6. Limits of your namespace

| Limit | Value |
|---|---|
| Total CPU requests / limits | 1 CPU / 2 CPU |
| Total memory requests / limits | 1 GiB / 2 GiB |
| Pods | 10 |
| Default per container (if you don't set `resources`) | request 50m / 64 Mi, limit 500m / 256 Mi |
| `LoadBalancer` / `NodePort` Services | not allowed; use the HTTPRoute |

Two replicas at the template's limits use 1 CPU and 512 Mi of the limit quota. During
a rolling update, an extra pod runs briefly, which needs headroom. Ask an admin if you
need more.

## 7. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Deploy job stuck at "Waiting for a runner to pick up this job" | runner group doesn't include your repo, the workflow is in a fork, or both runner slots are busy; ask an admin |
| `error: You must be logged in to the server (Unauthorized)` | `KUBE_TOKEN` missing or rotated; ask an admin to re-run onboarding |
| `forbidden: User "system:serviceaccount:myapp:deployer" cannot ...` | the manifest targets another namespace or a cluster-wide resource; keep everything namespaced, with no `namespace:` field |
| `exceeded quota` | lower `resources` or replicas, or ask for more quota |
| `ImagePullBackOff` | image name typo, or the package isn't linked to the repo; check `ghcr.io/woodez/<repo>` exists under the repo's **Packages** |
| `CreateContainerConfigError: container has runAsNonRoot and image will run as root` | add `USER 10001` (numeric) to the Dockerfile |
| `rollout status` times out | pod not becoming Ready: check `/healthz` and port 8080, then `kubectl describe pod` and `logs` |
| `404` from `192.168.2.240` | wrong `Host` header, or the HTTPRoute isn't accepted: `kubectl -n myapp get httproute -o yaml` |
| `denied: permission_denied` on push to ghcr.io | workflow lacks `permissions: packages: write`, or the org restricts package creation |

## Security rules

- Don't add a `pull_request` trigger to the deploy job. Deploys run only from `main`.
- Don't print `KUBE_TOKEN`, or write it anywhere except the runner's temp kubeconfig,
  as the template does.
- Don't change `runs-on: k8s-deploy` for the build job. Builds stay on GitHub-hosted
  runners.
- Use the images from your own repo's package. Base images in your Dockerfile should
  be official or verified publishers.
