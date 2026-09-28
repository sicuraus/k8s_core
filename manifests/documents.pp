# @summary Declares a `k8s_resource` for each object in a list, e.g. from
#   `k8s_core::yaml_documents` or `k8s_core::helm_template`.
#
# @param documents
#   Kubernetes objects (hashes with apiVersion, kind and metadata.name).
# @param namespace
#   Namespace for namespaced objects that name none. Cluster-scoped kinds
#   listed in `cluster_kinds` never get one.
# @param defaults
#   Extra `k8s_resource` parameters for every object, e.g. `wait` or `managed_by`.
# @param cluster_kinds
#   Kinds that are cluster-scoped, so `namespace` is not applied to them.
#
# @example Vendored manifests
#   k8s_core::documents { 'cert-manager':
#     documents => k8s_core::yaml_documents(file('profile/cert-manager.yaml')),
#   }
#
# @example A vendored chart
#   k8s_core::documents { 'ingress-nginx':
#     namespace => 'ingress-nginx',
#     documents => k8s_core::helm_template("${settings::environmentpath}/${server_facts['environment']}/charts/ingress-nginx",
#       { 'controller' => { 'replicaCount' => 2 } }, { 'namespace' => 'ingress-nginx' }),
#   }
define k8s_core::documents (
  Array[Hash]      $documents,
  Optional[String] $namespace = undef,
  Hash             $defaults  = {},
  Array[String]    $cluster_kinds = [
    'Namespace', 'CustomResourceDefinition', 'ClusterRole', 'ClusterRoleBinding', 'PersistentVolume',
    'StorageClass', 'PriorityClass', 'IngressClass', 'RuntimeClass', 'ValidatingWebhookConfiguration',
    'MutatingWebhookConfiguration', 'ValidatingAdmissionPolicy', 'ValidatingAdmissionPolicyBinding',
    'APIService', 'CSIDriver', 'VolumeSnapshotClass',
  ],
) {
  $documents.each |Hash $doc| {
    $ns = $doc['kind'] in $cluster_kinds ? {
      true    => undef,
      default => $namespace,
    }
    $metadata = $doc['metadata'].filter |$k, $_v| { !($k in ['name', 'namespace']) }
    $body = $doc.filter |$k, $_v| { !($k in ['apiVersion', 'kind', 'metadata']) }
    $content = $metadata.empty ? {
      true    => $body,
      default => $body + { 'metadata' => $metadata },
    }
    k8s_resource { k8s_core::title($doc, $ns):
      api_version => $doc['apiVersion'],
      content     => $content,
      *           => $defaults,
    }
  }
}
