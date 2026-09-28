# Run by the tenant-a runner: its own namespace works, anything else is a 403.
k8s_resource { 'ConfigMap/tenant-a/mine':
  api_version => 'v1',
  managed_by  => 'tenant-a',
  content     => { 'data' => { 'owner' => 'tenant-a' } },
}
k8s_resource { 'ConfigMap/default/not-mine':
  api_version => 'v1',
  managed_by  => 'tenant-a',
  content     => { 'data' => { 'owner' => 'tenant-a' } },
}
