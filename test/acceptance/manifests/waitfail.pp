# A rollout that never becomes ready fails, and its dependents are skipped.
$ns = 't-wait'
k8s_resource { "Namespace/${ns}": api_version => 'v1' }
k8s_resource { "Deployment/${ns}/broken":
  api_version  => 'apps/v1',
  wait         => true,
  wait_timeout => 20,
  content      => {
    'spec' => {
      'selector' => { 'matchLabels' => { 'app' => 'broken' } },
      'template' => {
        'metadata' => { 'labels' => { 'app' => 'broken' } },
        'spec'     => { 'containers' => [{ 'name' => 'x', 'image' => 'registry.invalid/nope:1' }] },
      },
    },
  },
}
k8s_resource { "ConfigMap/${ns}/after-rollout":
  api_version => 'v1',
  require     => K8s_resource["Deployment/${ns}/broken"],
  content     => { 'data' => { 'ok' => 'yes' } },
}
