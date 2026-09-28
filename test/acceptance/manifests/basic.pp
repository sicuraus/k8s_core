# Whole-object management: create, idempotence, drift, conflicts, field removal.
$ns = 't-basic'
$want_force = $facts['force'] == 'true'

k8s_resource { "Namespace/${ns}":
  api_version => 'v1',
  content     => { 'metadata' => { 'labels' => { 'team' => 'web' } } },
}

$extra = $facts['extra_key'] ? {
  'yes'   => { 'extra' => 'present' },
  default => {},
}
k8s_resource { "ConfigMap/${ns}/settings":
  api_version     => 'v1',
  force_conflicts => $want_force,
  content         => { 'data' => { 'greeting' => 'hello' } + $extra },
}

k8s_resource { "Secret/${ns}/creds":
  api_version    => 'v1',
  content        => { 'type' => 'Opaque' },
  sensitive_data => Sensitive({ 'password' => 'correct-horse' }),
}

k8s_resource { "Deployment/${ns}/web":
  api_version => 'apps/v1',
  wait        => true,
  require     => K8s_resource["Secret/${ns}/creds"],
  content     => {
    'spec' => {
      'replicas' => 2,
      'selector' => { 'matchLabels' => { 'app' => 'web' } },
      'template' => {
        'metadata' => { 'labels' => { 'app' => 'web' } },
        'spec'     => {
          'containers' => [{
            'name'    => 'web',
            'image'   => 'registry.k8s.io/pause:3.10',
            'envFrom' => [{ 'secretRef' => { 'name' => 'creds' } }],
          }],
        },
      },
    },
  },
}

k8s_resource { "Service/${ns}/web":
  api_version => 'v1',
  content     => { 'spec' => { 'selector' => { 'app' => 'web' }, 'ports' => [{ 'port' => 80, 'targetPort' => 8080 }] } },
}

k8s_wait { "Deployment/${ns}/web":
  api_version => 'apps/v1',
  condition   => 'condition=Available',
  timeout     => 60,
}
