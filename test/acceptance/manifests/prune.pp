# Inventory pruning. $facts: count (objects to declare), mode, allow_mass, drop_ns.
$ns = 't-prune'
$n = Integer($facts['count'].lest || { '6' })
$prune_mode = $facts['mode'].lest || { 'true' }

unless $facts['drop_ns'] == 'true' {
  k8s_resource { "Namespace/${ns}": api_version => 'v1', managed_by => 'prune-test' }
}
Integer($n).each |$j| {
  $i = $j + 1
  k8s_resource { "ConfigMap/${ns}/cm-${i}":
    api_version => 'v1',
    managed_by  => 'prune-test',
    content     => { 'data' => { 'index' => String($i) } },
  }
}
k8s_prune { 'prune-test':
  prune            => $prune_mode,
  allow_mass_prune => $facts['allow_mass'] == 'true',
}
