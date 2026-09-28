# k8s_core

Manage Kubernetes objects from OpenVox: any kind, with server-side apply,
drift detection by server-side dry-run, readiness gates, inventory-based
pruning, and field-level patches for objects someone else owns.

The module follows the layout of the `*_core` modules vendored into
openvox-agent (`cron_core`, `augeas_core`, …): native types and providers,
no gem dependencies (Ruby standard library only, plus the Resource API that
openvox-agent already bundles), and nothing that runs unless you declare it.
The goal is to ship it in `/opt/puppetlabs/puppet/vendor_modules/`.

The same types run three ways:

| How | Credentials | Typical use |
| --- | --- | --- |
| `puppet apply` / `puppet agent` in a pod | the pod's ServiceAccount | an in-cluster reconciler |
| `puppet device` through the `k8s` transport | a kubeconfig or token | an existing agent managing a cluster |
| OpenBolt `remote` target (`remote-transport: k8s`) | a kubeconfig or token | one-off `apply()` blocks and tasks in plans |

## Contents

- [Types](#types): `k8s_resource`, `k8s_wait`, `k8s_prune`, `k8s_patch`, `k8s_collection_rule`
- [Transport](#the-k8s-transport) `k8s` and the [`k8s` fact](#facts)
- [Functions](#functions): `k8s_core::yaml_documents`, `k8s_core::helm_template`, `k8s_core::title`, and the `k8s_core::documents` defined type
- [Bolt tasks](#bolt-tasks): `run_job`, `rollout_restart`, `scale`, `drain`, `uncordon`, `wait_node_ready`
- [Testing](#testing), [vendoring into openvox-agent](#vendoring-into-openvox-agent), [design notes](#design-notes)

Full parameter documentation is in [REFERENCE.md](REFERENCE.md).

## Types

### `k8s_resource`: whole objects

```puppet
k8s_resource { 'Namespace/frontend':
  api_version => 'v1',
  content     => { 'metadata' => { 'labels' => { 'team' => 'web' } } },
}

k8s_resource { 'Secret/frontend/frontend-env':
  api_version    => 'v1',
  content        => { 'type' => 'Opaque' },
  sensitive_data => Sensitive({ 'API_KEY' => $api_key.unwrap }),
}

k8s_resource { 'Deployment/frontend/frontend':
  api_version => 'apps/v1',
  wait        => true,          # dependents run only after the rollout
  require     => K8s_resource['Secret/frontend/frontend-env'],
  content     => {
    'spec' => {
      'replicas' => 2,
      'selector' => { 'matchLabels' => { 'app' => 'frontend' } },
      'template' => {
        'metadata' => { 'labels' => { 'app' => 'frontend' } },
        'spec'     => { 'containers' => [{
          'name'    => 'web',
          'image'   => "registry.example.com/frontend:${image_tag}",
          'envFrom' => [{ 'secretRef' => { 'name' => 'frontend-env' } }],
        }] },
      },
    },
  },
}
```

- **Titles** are `Kind/namespace/name`, or `Kind/name` for cluster-scoped
  kinds. The parameter shape of puppet-k8s's `kubectl_apply` (`kind`,
  `namespace`, `resource_name`, `api_version`, `content`) works too, under any
  title. An object can be declared only once, whatever its title.
- **Apply** is server-side apply with field manager `openvox`.
- **Drift** is a server-side dry-run of the desired body, compared with the
  live object minus `status` and server-maintained metadata. Fields the API
  server defaults never show as changes. A field you remove from `content` is
  removed from the object. The change message lists only the fields that
  change (`spec.replicas: 3 -> 2`), and Secret values are always redacted.
- **Conflicts.** When another field manager owns a field you declare:
  - if it is an imperative edit (`kubectl edit`, `patch`, `scale`, `label`…,
    the `drift_managers` globs, default `kubectl*` and `before-first-apply`),
    that is drift, and the field is taken back;
  - if it is anything else — an HPA, an operator, Helm, Argo CD, Flux — the
    resource fails and names that manager, instead of flapping.
    `force_conflicts => true` opts in to taking ownership.
- **Ownership labels.** Every object gets `openvox.voxpupuli.org/managed-by:
  <managed_by>` (default `openvox`, or `$K8S_CORE_MANAGED_BY`) and an
  `openvox.voxpupuli.org/title` annotation.
- **Autorequires.** Namespaced objects require their `Namespace`, and custom
  resources require their `CustomResourceDefinition`, when those are in the
  catalog. A CRD applied in a run is waited on until it is established, so its
  custom resources can follow in the same run.
- **`wait => true`** polls until the object is ready: Deployments,
  StatefulSets and DaemonSets once rolled out (a `ProgressDeadlineExceeded`
  fails fast), Jobs once complete, CRDs once established, PVCs once bound, and
  anything else once its `Ready` condition is true (or it has none). A timeout
  (`wait_timeout`, default 300s) fails the resource, so its dependents are
  skipped.

### `k8s_wait`: readiness gates

For gating on something other than the object you just applied. `condition`
takes the `kubectl wait --for` forms: `ready`, `delete`, `exists`,
`condition=Available[=False]`, `jsonpath={.status.phase}=Running`.

```puppet
k8s_wait { 'Job/db/migrate-42':
  api_version => 'batch/v1',
  condition   => 'condition=Complete',
  timeout     => 900,
}
```

### `k8s_prune`: deleting what left the catalog

Declare one per scope; its title is the `managed_by` value of the resources
it covers. It runs after all of them, and not at all if any of them failed.

```puppet
k8s_prune { 'platform': prune => 'dryrun' }   # true, false or dryrun
```

It works from a recorded inventory (ConfigMap `inventory-<scope>` in
`openvox-system`, one read per run) rather than a label search across every
kind. Its safety rails:

- It skips objects whose label now names another scope (someone adopted them)
  and objects annotated `openvox.voxpupuli.org/prune: disabled`.
- Namespaces, PVCs, CRDs and CertificateAuthorities are never pruned; delete
  them with `ensure => absent`.
- It refuses to delete more than `max_fraction` (default 20%, at least one) of
  the inventory in a run unless `allow_mass_prune` is set, or
  `$K8S_CORE_ALLOW_MASS_PRUNE=true`.
- It deletes custom resources first, then built-in kinds, then Namespaces and
  CRDs, with foreground propagation.

`prune => dryrun` warns about each object it would delete and keeps it in the
inventory.

### `k8s_patch`: fields, not objects

For objects someone else owns. It applies only the fields in `content`, under
its own field manager. It never creates the object: a missing target is
reported as not applicable. It is never labelled, so it never enters a prune
inventory. `ensure => absent` releases its fields; fields no other manager
owns are removed, and the object stays.

```puppet
k8s_patch { 'Namespace/team-a':
  api_version   => 'v1',
  field_manager => 'sicura',
  content       => { 'metadata' => { 'labels' => { 'pod-security.kubernetes.io/warn' => 'restricted' } } },
}
```

### `k8s_collection_rule`: every object of a kind

For controls like "every Namespace has a Pod Security level". At apply time
it lists the kind (optionally narrowed by `namespace`, `label_selector`,
`field_selector`, `exclude` and `match` conditions) and generates one child
resource per object. Each object therefore appears in the report as its own
resource, tagged with the rule's tags.

- `action => patch`: a `k8s_patch` onto each object.
- `action => report`: the same, but noop, so non-compliant objects are
  reported and nothing changes. Without `patch`, each matching object is
  reported as a violation.
- `action => delete`: each matching object is deleted, except objects this
  catalog declares.
- `action => create` with a `template`: builds a `k8s_resource` per object,
  with `%{name}` and `%{namespace}` substituted. Use it for "a default-deny
  NetworkPolicy in every Namespace". The generated objects join the run's
  prune inventory, so turning the rule off, or excluding a namespace, prunes
  them. `action => report` with a `template` reports the missing objects
  instead of creating them. Those report-only children have `inventory =>
  false`, so they don't keep alive objects an earlier `create` run made. The
  objects are pruned once the rule falls back to reporting.
- `release => true`: releases the fields the rule's patches own. Use it when a
  control is switched off; removing the rule from the catalog leaves its
  fields in place.

```puppet
k8s_collection_rule { 'no-anonymous-cluster-admin':
  api_version => 'rbac.authorization.k8s.io/v1',
  kind        => 'ClusterRoleBinding',
  action      => 'report',
  match       => [
    { 'path' => '{.roleRef.name}', 'op' => 'equals', 'value' => 'cluster-admin' },
    { 'path' => '{.subjects[*].name}', 'op' => 'contains', 'value' => 'system:anonymous' },
  ],
}
```

## The `k8s` transport

A Resource API transport, so `puppet device` and OpenBolt can manage a cluster
from outside it. Its connection settings are `kubeconfig` and `context`, or
`server` with `token`/`token_file` and `ca_file`, plus
`insecure_skip_tls_verify` and `timeout`. Kubeconfig exec credential plugins
(EKS, GKE, AKS) are supported.

`puppet device`:

```ini
# device.conf
[prod-east]
type k8s
url file:///etc/puppetlabs/puppet/devices/prod-east.json
```

```json
{ "kubeconfig": "/etc/puppetlabs/puppet/devices/prod-east.kubeconfig", "context": "prod-east" }
```

OpenBolt:

```yaml
# inventory.yaml
groups:
  - name: clusters
    targets:
      - name: harvester-east
        config: { remote: { context: harvester-east } }
    config:
      transport: remote
      remote:
        remote-transport: k8s
        kubeconfig: ~/.kube/config
```

```puppet
apply('clusters') {
  k8s_resource { 'ConfigMap/tools/maintenance':
    api_version   => 'v1',
    managed_by    => 'bolt-maintenance',   # never in a reconciler's inventory
    field_manager => 'openbolt',
    content       => { 'data' => { 'window' => 'now' } },
  }
}
```

Without a transport (`puppet apply` or `puppet agent`), credentials come from
the in-cluster ServiceAccount when there is one; otherwise from the kubeconfig
named by `$K8S_CORE_KUBECONFIG` (with `$K8S_CORE_CONTEXT`), `$KUBECONFIG`, or
`~/.kube/config`.

## Facts

`$facts['k8s']`:

| Key | Contents |
| --- | --- |
| `version` | `git_version`, `major`, `minor`, `platform` |
| `kinds` | every served `group/version/Kind`, e.g. `monitoring.coreos.com/v1/ServiceMonitor` (core kinds are `v1/Pod`) |
| `distribution` | `harvester`, `openshift`, `rke2`, `k3s`, `eks`, `gke`, `aks`, `kind` or `unknown` |
| `managed_control_plane` | true for EKS, GKE and AKS |
| `cluster` | `name`, `environment` and any other keys from the `openvox-system/cluster-info` ConfigMap; `labels` are that ConfigMap's own labels |
| `identity` | the API server's view of who is running (SelfSubjectReview) |
| `server` | API server URL |

```puppet
if 'monitoring.coreos.com/v1/ServiceMonitor' in $facts['k8s']['kinds'] { ... }
```

Under `puppet device` and OpenBolt the transport provides the fact. Otherwise
it resolves only inside a pod with a ServiceAccount token, or when
`$K8S_CORE_KUBECONFIG` is set. An ordinary node never contacts an API server,
which matters for a vendored module. Set `K8S_CORE_FACTS=false` to turn it off.

## Functions

- `k8s_core::yaml_documents($yaml)` splits multi-document YAML (and `kind:
  List`) into object hashes.
- `k8s_core::helm_template($chart, $values, $options)` runs `helm template` on
  a chart vendored in the control repo (never a remote chart) at compile time,
  so every rendered object is in the catalog and covered by pruning and
  reporting. Chart hooks become ordinary objects; there is no Helm release
  history.
- `k8s_core::title($object, $namespace)` returns the `k8s_resource` title for
  an object hash.
- `k8s_core::documents` (defined type) declares a `k8s_resource` for each
  object in a list:

```puppet
k8s_core::documents { 'ingress-nginx':
  namespace => 'ingress-nginx',
  documents => k8s_core::helm_template("${module_dir}/charts/ingress-nginx",
    { 'controller' => { 'replicaCount' => 2 } }, { 'namespace' => 'ingress-nginx' }),
}
```

## Bolt tasks

All are `remote: true`. Against a `remote` target they use its `k8s` transport
settings; run locally (for example in a pod with `transport: local`) they use
the ServiceAccount or a kubeconfig. They write as field manager `openbolt`.

| Task | What it does |
| --- | --- |
| `k8s_core::run_job` | Runs a Job from an image and command, or from a CronJob's template. It waits, returns logs and exit codes, then deletes the Job. It fails fast on image-pull errors. |
| `k8s_core::rollout_restart` | Restarts a Deployment, StatefulSet or DaemonSet and waits for the rollout. |
| `k8s_core::scale` | Scales a workload. It refuses when another declarative manager (such as a reconciler) owns `spec.replicas`, unless `force`. |
| `k8s_core::drain` / `uncordon` | Cordons a node and evicts its pods, retrying while a PodDisruptionBudget blocks them; `uncordon` makes the node schedulable again. |
| `k8s_core::wait_node_ready` | Waits for a node to report Ready. |

## Testing

```bash
bundle exec rake spec                  # unit tests (Ruby 3.2+)
test/acceptance/run.sh                 # KinD acceptance, docker or podman
CONTAINER_ENGINE=podman KEEP_CLUSTER=1 ONLY="basic prune" test/acceptance/run.sh
```

The acceptance suite, locally and in GitHub Actions:

1. creates a KinD cluster;
2. builds a runner image, `voxpupuli/openvoxagent` with this module in
   `vendor_modules/k8s_core`;
3. runs openvox-agent from outside the cluster with `puppet device` and the
   `k8s` transport, to deploy a cluster-admin runner and a namespace-scoped
   tenant runner;
4. execs `puppet apply` scenarios in those runners, covering: create and
   idempotence; drift correction and noop; conflicts with another manager;
   field removal; a CRD and its CR in one run; failing readiness gates;
   pruning with dryrun, the mass-prune limit, protected kinds and adoption;
   patches and collection rules; and RBAC confinement;
5. applies and runs tasks through an OpenBolt `remote` target.

It needs docker or podman, `kind`, `kubectl` and `jq`.

## Vendoring into openvox-agent

The module is laid out for openvox-agent's vanagon `_base-module.rb`, which
copies the tree to `vendor_modules/<name>` and drops dotfiles:

```ruby
# configs/components/module-sicura-k8s_core.rb
component "module-sicura-k8s_core" do |pkg, settings, platform|
  pkg.load_from_json("configs/components/module-sicura-k8s_core.json")
  instance_eval File.read("configs/components/_base-module.rb")
end
```

```json
{"url":"https://github.com/sicuraus/k8s_core.git","ref":"refs/tags/v0.1.0"}
```

## Design notes

- **Naming.** Types, facts and the transport are global names in Puppet, so
  they share the `k8s` prefix. Everything namespaced is `k8s_core::`. puppet-k8s
  owns `kubectl_apply`, `kubeconfig`, the `k8s::` function namespace and
  `lib/puppet/util/k8s.rb`, so this module stays out of those
  (its Ruby lives in `puppet_x/k8s_core/`). It defines no `k8s_*` type
  puppet-k8s has, but that prefix is the most likely future collision.
- **Kubernetes-side names** use the openvox-operator API group,
  `openvox.voxpupuli.org/…`, for labels and annotations.
- **Why server-side dry-run for drift?** The API server applies its own
  defaulting, admission and field ownership. Asking it what an apply would
  change is the only comparison that does not produce perpetual diffs. The cost
  is one extra request per object per run.
- **Why the drift-manager rule?** Declining every conflict makes a hand edit
  un-correctable (`kubectl scale` takes ownership of `spec.replicas`), and
  forcing every conflict flaps against HPAs and operators. Imperative kubectl
  managers are treated as drift, everything else as an owner. This matches how
  Flux treats kubectl.
- **Classic types, Resource API transport.** Classic types work under a plain
  `puppet apply` in a pod and under `puppet device`. The Resource API
  supplies only the transport that `puppet device` and OpenBolt need.

## License

Apache-2.0
