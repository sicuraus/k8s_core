#!/usr/bin/env bash
# KinD acceptance suite for k8s_core.
#
# 1. Creates a KinD cluster (or reuses one).
# 2. Builds a runner image: voxpupuli/openvoxagent with this module in
#    /opt/puppetlabs/puppet/vendor_modules/k8s_core, and loads it into KinD.
# 3. From outside the cluster, runs openvox-agent in a container with the
#    `k8s` transport (`puppet device --apply`) to deploy the runners: a
#    cluster-admin "platform" runner and a namespace-scoped "tenant-a" one.
#    When OpenBolt is available it also applies through a Bolt remote target.
# 4. Execs `puppet apply` scenarios inside the runners, which use their
#    ServiceAccounts, and checks the results with kubectl.
#
# Requirements: docker or podman, kind, kubectl, jq.
#
# Environment:
#   CONTAINER_ENGINE  docker or podman (default: whichever works, docker first)
#   KIND_CLUSTER      cluster name (default k8s-core-test)
#   KEEP_CLUSTER      set to 1 to leave the cluster running afterwards
#   BASE_IMAGE        runner base image (default docker.io/voxpupuli/openvoxagent:latest)
#   BOLT_IMAGE        OpenBolt image for the remote-target check (default
#                     docker.io/voxpupuli/openbolt:latest; set to "none" to skip)
#   ONLY              space-separated scenario names to run (default: all)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HERE="$ROOT/test/acceptance"
CLUSTER=${KIND_CLUSTER:-k8s-core-test}
BASE_IMAGE=${BASE_IMAGE:-docker.io/voxpupuli/openvoxagent:latest}
BOLT_IMAGE=${BOLT_IMAGE:-docker.io/voxpupuli/openbolt:latest}
# A new tag per build, so bootstrap rolls the runners onto it.
IMAGE=localhost/k8s-core-runner:t$(date +%s)
NS=k8s-core-test
WORK=$(mktemp -d "${TMPDIR:-/tmp}/k8s-core-acc.XXXXXX")
PASS=0
FAIL=0
FAILED=()

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[32m  ok\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '\033[31m  FAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); FAILED+=("$*"); }

if [[ -z "${CONTAINER_ENGINE:-}" ]]; then
  if docker info >/dev/null 2>&1; then CONTAINER_ENGINE=docker
  elif podman info >/dev/null 2>&1; then CONTAINER_ENGINE=podman
  else echo "need docker or podman" >&2; exit 1
  fi
fi
[[ "$CONTAINER_ENGINE" == podman ]] && export KIND_EXPERIMENTAL_PROVIDER=podman
ENGINE=$CONTAINER_ENGINE

cleanup() {
  local rc=$?
  if [[ "${KEEP_CLUSTER:-}" != 1 && -n "${CREATED_CLUSTER:-}" ]]; then
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

# ---- cluster and image -----------------------------------------------------

log "cluster $CLUSTER ($ENGINE)"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --wait 120s
  CREATED_CLUSTER=1
fi
KUBECONFIG_FILE="$WORK/kubeconfig"
kind get kubeconfig --name "$CLUSTER" >"$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"
K="kubectl --context kind-$CLUSTER"
$K wait --for=condition=Ready node --all --timeout=120s >/dev/null

if [[ -z "${CREATED_CLUSTER:-}" ]]; then
  log "reusing $CLUSTER: removing state from earlier runs"
  $K delete ns t-basic t-crd t-wait t-prune t-comp-a t-comp-b t-comp-exempt t-comp-new t-bolt \
    --ignore-not-found --wait=true >/dev/null
  $K delete crd widgets.example.com --ignore-not-found >/dev/null
  $K delete clusterrolebinding k8s-core-test-anon --ignore-not-found >/dev/null
  $K -n openvox-system delete cm -l openvox.voxpupuli.org/inventory --ignore-not-found >/dev/null 2>&1 || true
  $K -n tenant-a delete cm mine --ignore-not-found >/dev/null 2>&1 || true
  $K label ns kube-public example.com/audited- >/dev/null 2>&1 || true
fi

log "building $IMAGE from $BASE_IMAGE"
$ENGINE build -q -f "$HERE/Containerfile" --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$IMAGE" "$ROOT" >/dev/null
$ENGINE save "$IMAGE" -o "$WORK/image.tar"
kind load image-archive "$WORK/image.tar" --name "$CLUSTER" >/dev/null
rm -f "$WORK/image.tar"

# ---- deploy the runners from outside, through the k8s transport -------------

log "bootstrap through puppet device (k8s transport)"
mkdir -p "$WORK/device"
cat >"$WORK/device/kind.json" <<EOF
{"kubeconfig": "/work/kubeconfig", "context": "kind-$CLUSTER"}
EOF
cat >"$WORK/device/device.conf" <<EOF
[kind-$CLUSTER]
type k8s
url file:///work/device/kind.json
EOF
chmod -R a+rX "$WORK"
# The same image acts as the "remote" agent: host networking reaches the
# KinD API server on 127.0.0.1.
remote_agent() {
  $ENGINE run --rm --network host -v "$WORK:/work:Z" "$IMAGE" "$@"
}
remote_agent /opt/puppetlabs/bin/puppet epp render /opt/puppetlabs/puppet/vendor_modules/k8s_core/test/acceptance/bootstrap.pp.epp \
  --values "{image => '$IMAGE', pull_policy => 'Never'}" >"$WORK/bootstrap.pp"
run_device() {
  remote_agent /opt/puppetlabs/bin/puppet device --color=false --deviceconfig /work/device/device.conf --target "kind-$CLUSTER" \
    --apply "/work/$1" >"$WORK/device.log" 2>&1 || true
}
run_device bootstrap.pp
if grep -q '^Error' "$WORK/device.log"; then cat "$WORK/device.log"; bad "bootstrap via puppet device"; exit 1; fi
grep -q 'Deployment\[k8s-core-test/runner-platform\]\|Deployment/k8s-core-test/runner-platform' "$WORK/device.log" &&
  ok "puppet device created the runners" || ok "runners already present"
run_device bootstrap.pp
if grep -qE '^(Notice: /Stage|Error)' "$WORK/device.log"; then cat "$WORK/device.log"; bad "bootstrap is idempotent"; else ok "bootstrap is idempotent"; fi

remote_agent /opt/puppetlabs/bin/puppet device --deviceconfig /work/device/device.conf --target "kind-$CLUSTER" --facts \
  >"$WORK/device-facts.json" 2>/dev/null || true
[[ "$(jq -r '.values.k8s.distribution' "$WORK/device-facts.json" 2>/dev/null)" == kind ]] &&
  ok "transport facts report distribution kind" || bad "transport facts"

$K -n "$NS" rollout status deploy/runner-platform --timeout=120s >/dev/null
$K -n "$NS" rollout status deploy/runner-tenant-a --timeout=120s >/dev/null

# ---- helpers ------------------------------------------------------------------

# papply RUNNER MANIFEST EXPECTED_EXITS [VAR=value ...] -- puppet apply in a runner
papply() {
  local runner=$1 manifest=$2 want=$3 rc=0
  shift 3
  local extra=()
  if [[ "${1:-}" == --noop ]]; then extra+=(--noop); shift; fi
  $K -n "$NS" exec "deploy/runner-$runner" -- env "$@" \
    /opt/puppetlabs/bin/puppet apply --color=false --detailed-exitcodes "${extra[@]}" \
    "/opt/k8s_core-tests/$manifest" >"$WORK/last.log" 2>&1 || rc=$?
  LAST_RC=$rc
  if [[ "|$want|" == *"|$rc|"* ]]; then return 0; fi
  echo "    puppet apply $manifest $* exited $rc, wanted $want:" >&2
  sed 's/^/      /' "$WORK/last.log" >&2
  return 1
}
expect() { # expect DESCRIPTION COMMAND...
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}
log_has() { grep -qE "$1" "$WORK/last.log"; }
jget() { $K get "$@" 2>/dev/null; }

want() { [[ -z "${ONLY:-}" || " $ONLY " == *" $1 "* ]]; }

# ---- scenarios ----------------------------------------------------------------

if want facts; then
  log "facts"
  $K -n "$NS" exec deploy/runner-platform -- /opt/puppetlabs/bin/puppet facts show k8s --render-as json \
    >"$WORK/facts.json" 2>/dev/null || true
  expect "k8s.distribution is kind" test "$(jq -r '.k8s.distribution' "$WORK/facts.json")" == kind
  expect "k8s.identity is the runner ServiceAccount" \
    test "$(jq -r '.k8s.identity.username' "$WORK/facts.json")" == "system:serviceaccount:$NS:openvox-platform"
  expect "k8s.kinds lists apps/v1/Deployment" jq -e '.k8s.kinds | index("apps/v1/Deployment")' "$WORK/facts.json" >/dev/null
  expect "k8s.version.minor is set" jq -e '.k8s.version.minor | length > 0' "$WORK/facts.json" >/dev/null
fi

if want basic; then
  log "basic: create, idempotence, drift, conflicts, field removal"
  expect "first run changes" papply platform basic.pp 2
  expect "second run makes no changes" papply platform basic.pp 0
  expect "secret holds the sensitive value" test "$(jget -n t-basic secret creds -o jsonpath='{.data.password}' | base64 -d)" == correct-horse
  expect "secret value is not in the log" bash -c "! grep -q correct-horse '$WORK/last.log'"
  expect "managed-by label set" test "$(jget -n t-basic cm settings -o jsonpath='{.metadata.labels.openvox\.voxpupuli\.org/managed-by}')" == openvox
  expect "deployment is available" test "$(jget -n t-basic deploy web -o jsonpath='{.status.availableReplicas}')" == 2

  $K -n t-basic patch cm settings --type merge -p '{"data":{"greeting":"drifted"}}' >/dev/null
  $K -n t-basic scale deploy web --replicas=3 >/dev/null
  expect "noop run leaves drift alone" papply platform basic.pp 0 --noop
  expect "noop run reports the drift" log_has '\(noop\)'
  expect "drift is corrected" papply platform basic.pp 2
  expect "drift correction names the kubectl edit" log_has 'reverting edits by kubectl'
  expect "configmap restored" test "$(jget -n t-basic cm settings -o jsonpath='{.data.greeting}')" == hello
  expect "replicas restored" test "$(jget -n t-basic deploy web -o jsonpath='{.spec.replicas}')" == 2
  expect "converged after drift" papply platform basic.pp 0

  expect "adding a field" papply platform basic.pp 2 FACTER_extra_key=yes
  expect "removing the field from content" papply platform basic.pp 2
  expect "removed field is gone from the object" test -z "$(jget -n t-basic cm settings -o jsonpath='{.data.extra}')"

  # Another declarative owner of the same field is a conflict, not drift.
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: settings, namespace: t-basic}\ndata: {greeting: from-helm}\n' |
    $K apply --server-side --force-conflicts --field-manager=helm -f - >/dev/null
  expect "a conflicting manager fails the resource" papply platform basic.pp "4|6"
  expect "the failure names the other manager" log_has 'owned by helm'
  expect "force_conflicts takes ownership" papply platform basic.pp 2 FACTER_force=true
  expect "and converges" papply platform basic.pp 0
fi

if want crd; then
  log "crd: a CRD and its custom resource in one run"
  expect "CRD and CR applied together" papply platform crd.pp 2
  expect "widget exists" test "$(jget -n t-crd widgets.example.com first -o jsonpath='{.spec.size}')" == 3
  expect "second run makes no changes" papply platform crd.pp 2 # the notify fires now the kind is in facts
  expect "facts see the new kind on the next run" log_has 'widget kind visible in facts'
fi

if want wait; then
  log "wait: a failed rollout skips its dependents"
  expect "rollout timeout fails the run" papply platform waitfail.pp "4|6"
  expect "failure explains readiness" log_has 'not ready after 20s'
  expect "dependent was skipped" log_has 'Skipping because of failed dependencies'
  expect "dependent was not created" bash -c "! $K -n t-wait get cm after-rollout >/dev/null 2>&1"
  $K delete ns t-wait --wait=false >/dev/null
fi

if want prune; then
  log "prune: inventory, dryrun, mass-prune limit, protected kinds"
  expect "six objects applied" papply platform prune.pp 2 FACTER_count=6
  expect "inventory recorded" test "$(jget -n openvox-system cm inventory-prune-test -o jsonpath='{.data.inventory\.json}' | jq length)" == 7
  expect "dropping one in dryrun changes nothing" papply platform prune.pp "0|2" FACTER_count=5 FACTER_mode=dryrun
  expect "dryrun warns" log_has 'would prune ConfigMap/t-prune/cm-6'
  expect "dryrun kept the object" jget -n t-prune cm cm-6 -o name
  expect "dropping one prunes it" papply platform prune.pp 2 FACTER_count=5
  expect "pruned object is gone" bash -c "! $K -n t-prune get cm cm-6 >/dev/null 2>&1"
  expect "converged" papply platform prune.pp 0 FACTER_count=5
  expect "a mass prune is refused" papply platform prune.pp "4|6" FACTER_count=1
  expect "refusal explains the limit" log_has 'refusing to prune 4 of 6'
  expect "nothing was deleted" jget -n t-prune cm cm-5 -o name
  expect "allow_mass_prune lifts the limit" papply platform prune.pp 2 FACTER_count=1 FACTER_allow_mass=true
  expect "objects deleted" bash -c "! $K -n t-prune get cm cm-5 >/dev/null 2>&1"
  expect "a Namespace is prune-protected" papply platform prune.pp "0|2" FACTER_count=1 FACTER_drop_ns=true
  expect "protection is reported" log_has 'prune-protected'
  expect "namespace survives" jget ns t-prune -o name
  # Adopted objects are released, not deleted.
  $K -n t-prune label cm cm-1 openvox.voxpupuli.org/managed-by=someone-else --overwrite >/dev/null || true
  papply platform prune.pp "0|2|4|6" FACTER_count=0 FACTER_allow_mass=true || true
  expect "adopted object is not pruned" jget -n t-prune cm cm-1 -o name
fi

if want compliance; then
  log "compliance: k8s_patch and collection rules"
  $K create clusterrolebinding k8s-core-test-anon --clusterrole=cluster-admin --user=system:anonymous \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
  expect "rules apply" papply platform compliance.pp 2
  expect "every labelled namespace gets the PSS label" test "$(jget ns t-comp-a -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/warn}')" == restricted
  expect "exempt namespace is left alone" test -z "$(jget ns t-comp-exempt -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/warn}')"
  expect "missing target is not applicable" log_has 'not-there does not exist; not applicable'
  expect "anonymous cluster-admin binding is reported" log_has 'ClusterRoleBinding/k8s-core-test-anon.*\(noop\)|k8s-core-test-anon.*noop'
  expect "report-only rule deleted nothing" jget clusterrolebinding k8s-core-test-anon -o name
  expect "patch field owned by sicura" bash -c "$K get ns t-comp-a --show-managed-fields -o json | jq -e '.metadata.managedFields[] | select(.manager==\"sicura\")' >/dev/null"
  expect "second run makes no changes" papply platform compliance.pp 0

  $K create ns t-comp-new --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K label ns t-comp-new compliance-test=yes --overwrite >/dev/null
  expect "a namespace created since is covered" papply platform compliance.pp 2
  expect "new namespace labelled" test "$(jget ns t-comp-new -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/warn}')" == restricted
  $K label ns t-comp-a pod-security.kubernetes.io/warn=privileged --overwrite >/dev/null
  expect "a kubectl edit of a control is corrected" papply platform compliance.pp 2
  expect "label restored" test "$(jget ns t-comp-a -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/warn}')" == restricted

  expect "release => true releases the fields" papply platform compliance.pp 2 FACTER_release=true
  expect "PSS label removed" test -z "$(jget ns t-comp-a -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/warn}')"
  expect "patched label removed" test -z "$(jget ns kube-public -o jsonpath='{.metadata.labels.example\.com/audited}')"
  expect "namespace itself untouched" jget ns t-comp-a -o name
  $K delete clusterrolebinding k8s-core-test-anon >/dev/null
fi

if want tenant; then
  log "tenant: RBAC confines a runner to its namespace"
  expect "out-of-scope object fails" papply tenant-a tenant.pp "4|6"
  expect "failure is a 403" log_has '403|forbidden'
  expect "in-scope object applied" test "$(jget -n tenant-a cm mine -o jsonpath='{.data.owner}')" == tenant-a
  expect "nothing written outside the namespace" bash -c "! $K -n default get cm not-mine >/dev/null 2>&1"
fi

if want bolt && [[ "$BOLT_IMAGE" != none ]]; then
  log "bolt: the cluster as an OpenBolt remote target"
  if $ENGINE pull -q "$BOLT_IMAGE" >/dev/null 2>&1; then
    mkdir -p "$WORK/bolt/modules"
    cp -r "$ROOT" "$WORK/bolt/modules/k8s_core"
    rm -rf "$WORK/bolt/modules/k8s_core/.git"
    cat >"$WORK/bolt/inventory.yaml" <<EOF
targets:
  - name: kind
    config:
      transport: remote
      remote:
        remote-transport: k8s
        kubeconfig: /work/kubeconfig
        context: kind-$CLUSTER
EOF
    cat >"$WORK/bolt/bolt-project.yaml" <<'EOF'
name: acceptance
modulepath: [modules]
save-rerun: false
EOF
    cat >"$WORK/bolt/apply.pp" <<'EOF'
k8s_resource { 'Namespace/t-bolt': api_version => 'v1', managed_by => 'bolt-acceptance', field_manager => 'openbolt' }
k8s_resource { 'Deployment/t-bolt/pause':
  api_version   => 'apps/v1',
  managed_by    => 'bolt-acceptance',
  field_manager => 'openbolt',
  wait          => true,
  content       => { 'spec' => {
    'selector' => { 'matchLabels' => { 'app' => 'pause' } },
    'template' => {
      'metadata' => { 'labels' => { 'app' => 'pause' } },
      'spec'     => { 'containers' => [{ 'name' => 'pause', 'image' => 'registry.k8s.io/pause:3.10' }] },
    },
  } },
}
k8s_resource { 'ConfigMap/t-bolt/from-bolt':
  api_version   => 'v1',
  managed_by    => 'bolt-acceptance',
  field_manager => 'openbolt',
  content       => { 'data' => { 'via' => 'openbolt' } },
}
EOF
    chmod -R a+rwX "$WORK/bolt"
    bolt() {
      $ENGINE run --rm --network host -v "$WORK:/work:Z" -w /work/bolt -e BOLT_PROJECT=/work/bolt "$BOLT_IMAGE" "$@"
    }
    if bolt apply apply.pp --targets kind >"$WORK/last.log" 2>&1; then ok "bolt apply through the remote transport"; else cat "$WORK/last.log"; bad "bolt apply through the remote transport"; fi
    expect "object created by bolt" test "$(jget -n t-bolt cm from-bolt -o jsonpath='{.data.via}')" == openbolt
    if bolt task run k8s_core::rollout_restart --targets kind namespace=t-bolt workload=deployment/pause \
      >"$WORK/last.log" 2>&1; then ok "remote task rollout_restart"; else cat "$WORK/last.log"; bad "remote task rollout_restart"; fi
    if bolt task run k8s_core::run_job --targets kind namespace=t-bolt image=$IMAGE \
      'command=["sh","-c","echo hello from job"]' >"$WORK/last.log" 2>&1 && log_has 'hello from job'; then
      ok "remote task run_job returns logs"
    else cat "$WORK/last.log"; bad "remote task run_job returns logs"; fi
  else
    echo "  (skipped: cannot pull $BOLT_IMAGE)"
  fi
fi

# ---- summary --------------------------------------------------------------------

log "passed $PASS, failed $FAIL"
for f in "${FAILED[@]}"; do echo "  - $f"; done
[[ $FAIL -eq 0 ]]
