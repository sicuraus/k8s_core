# A CRD and its first custom resource in the same run.
k8s_resource { 'CustomResourceDefinition/widgets.example.com':
  api_version => 'apiextensions.k8s.io/v1',
  content     => {
    'spec' => {
      'group'    => 'example.com',
      'scope'    => 'Namespaced',
      'names'    => { 'plural' => 'widgets', 'singular' => 'widget', 'kind' => 'Widget' },
      'versions' => [{
        'name'    => 'v1',
        'served'  => true,
        'storage' => true,
        'schema'  => { 'openAPIV3Schema' => {
          'type'       => 'object',
          'properties' => { 'spec' => { 'type' => 'object', 'properties' => { 'size' => { 'type' => 'integer' } } } },
        } },
      }],
    },
  },
}
k8s_resource { 'Namespace/t-crd': api_version => 'v1' }
k8s_resource { 'Widget/t-crd/first':
  api_version => 'example.com/v1',
  content     => { 'spec' => { 'size' => 3 } },
}
if 'example.com/v1/Widget' in $facts['k8s']['kinds'] {
  notify { 'widget kind visible in facts': }
}
