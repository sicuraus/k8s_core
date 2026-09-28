# Field-level patches and collection rules, as the compliance classes use them.
$rule_ensure = $facts['release'] ? { 'true' => 'absent', default => 'present' }

['t-comp-a', 't-comp-b', 't-comp-exempt'].each |$n| {
  k8s_resource { "Namespace/${n}":
    api_version => 'v1',
    content     => { 'metadata' => { 'labels' => { 'compliance-test' => 'yes' } } },
  }
}

k8s_collection_rule { 'pss-warn':
  release        => $rule_ensure == 'absent',
  api_version    => 'v1',
  kind           => 'Namespace',
  label_selector => 'compliance-test=yes',
  exclude        => ['t-comp-exempt'],
  action         => 'patch',
  field_manager  => 'sicura',
  patch          => { 'metadata' => { 'labels' => { 'pod-security.kubernetes.io/warn' => 'restricted' } } },
  tag            => ['k8s_restrict_pod_privileges'],
}

k8s_patch { 'kube-public label':
  ensure        => $rule_ensure,
  target        => 'Namespace/kube-public',
  api_version   => 'v1',
  field_manager => 'sicura',
  content       => { 'metadata' => { 'labels' => { 'example.com/audited' => 'true' } } },
}

k8s_patch { 'Namespace/not-there':
  api_version => 'v1',
  content     => { 'metadata' => { 'labels' => { 'x' => 'y' } } },
}

k8s_collection_rule { 'no-anonymous-cluster-admin':
  api_version => 'rbac.authorization.k8s.io/v1',
  kind        => 'ClusterRoleBinding',
  action      => 'report',
  match       => [
    { 'path' => '{.roleRef.name}', 'op' => 'equals', 'value' => 'cluster-admin' },
    { 'path' => '{.subjects[*].name}', 'op' => 'contains', 'value' => 'system:anonymous' },
  ],
}
