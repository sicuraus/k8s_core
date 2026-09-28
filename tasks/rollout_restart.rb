#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
params = JSON.parse($stdin.read)
lib = params['_installdir'] ? File.join(params['_installdir'], 'k8s_core', 'lib') : File.expand_path('../lib', __dir__)
require File.join(lib, 'puppet_x', 'k8s_core', 'task')

PuppetX::K8sCore::Task.run(params) do |p, client|
  t = PuppetX::K8sCore::Task
  av, kind, name = t.workload(p['workload'])
  ns = p.fetch('namespace')
  at = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  t.merge_patch(client, client.resource_path(av, kind, ns, name),
                'spec' => { 'template' => { 'metadata' => { 'annotations' => { 'kubectl.kubernetes.io/restartedAt' => at } } } })
  result = { 'workload' => "#{kind}/#{ns}/#{name}", 'restarted_at' => at }
  result['status'] = t.wait_ready(client, av, kind, ns, name, p.fetch('timeout', 600)) if p.fetch('wait', true)
  result
end
