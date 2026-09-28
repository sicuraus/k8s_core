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
  obj = client.get_object(av, kind, ns, name)
  raise PuppetX::K8sCore::Error, "#{kind} #{ns}/#{name} not found" unless obj

  replica_owners = (obj.dig('metadata', 'managedFields') || []).select do |mf|
    mf.dig('fieldsV1', 'f:spec', 'f:replicas') && mf['manager'] != t::FIELD_MANAGER
  end
  owners = replica_owners.map { |mf| mf['manager'] }
  declarative = owners.reject { |m| m.start_with?('kubectl') || m == 'kube-controller-manager' }
  if !declarative.empty? && !p['force']
    raise PuppetX::K8sCore::Task::Failure.new(
      "spec.replicas of #{kind} #{ns}/#{name} is owned by #{declarative.join(', ')}; change it there, or pass force=true",
      'owners' => declarative,
    )
  end
  before = obj.dig('spec', 'replicas')
  client.request(:patch, "#{client.resource_path(av, kind, ns, name)}/scale",
                 body: { 'spec' => { 'replicas' => p.fetch('replicas') } },
                 content_type: 'application/merge-patch+json', query: { 'fieldManager' => t::FIELD_MANAGER })
  result = { 'workload' => "#{kind}/#{ns}/#{name}", 'from' => before, 'to' => p['replicas'] }
  result['status'] = t.wait_ready(client, av, kind, ns, name, p.fetch('timeout', 600)) if p.fetch('wait', true)
  result
end
