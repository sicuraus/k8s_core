#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
params = JSON.parse($stdin.read)
lib = params['_installdir'] ? File.join(params['_installdir'], 'k8s_core', 'lib') : File.expand_path('../lib', __dir__)
require File.join(lib, 'puppet_x', 'k8s_core', 'task')

PuppetX::K8sCore::Task.run(params) do |p, client|
  t = PuppetX::K8sCore::Task
  node = p.fetch('node')
  t.merge_patch(client, "/api/v1/nodes/#{node}", 'spec' => { 'unschedulable' => true })
  pods = client.get('/api/v1/pods', query: { 'fieldSelector' => "spec.nodeName=#{node},status.phase!=Succeeded,status.phase!=Failed" })['items']
  skipped = []
  targets = pods.reject do |pod|
    md = pod['metadata']
    owners = md['ownerReferences'] || []
    reason = if md.dig('annotations', 'kubernetes.io/config.mirror') then 'mirror pod'
             elsif owners.any? { |o| o['kind'] == 'DaemonSet' } && p.fetch('ignore_daemonsets', true) then 'DaemonSet'
             elsif !p['delete_emptydir_data'] && (pod.dig('spec', 'volumes') || []).any? { |v| v.key?('emptyDir') }
               raise PuppetX::K8sCore::Error, "#{md['namespace']}/#{md['name']} uses emptyDir; pass delete_emptydir_data=true"
             end
    skipped << "#{md['namespace']}/#{md['name']} (#{reason})" if reason
    reason
  end
  deadline = Time.now + p.fetch('timeout', 600)
  pending = targets.map { |pod| [pod.dig('metadata', 'namespace'), pod.dig('metadata', 'name')] }
  evicted = []
  until pending.empty?
    pending.reject! do |ns, name|
      client.request(:post, "/api/v1/namespaces/#{ns}/pods/#{name}/eviction",
                     body: { 'apiVersion' => 'policy/v1', 'kind' => 'Eviction', 'metadata' => { 'name' => name, 'namespace' => ns } })
      evicted << "#{ns}/#{name}"
      true
    rescue PuppetX::K8sCore::ApiError => e
      next true if e.not_found?
      raise unless e.code == 429 # blocked by a PodDisruptionBudget; retry

      false
    end
    break if pending.empty?
    raise PuppetX::K8sCore::Task::Failure.new("evictions blocked after #{p['timeout']}s", 'pending' => pending.map { |a| a.join('/') }) if Time.now > deadline

    sleep 5
  end
  # Wait for evicted pods to go away.
  evicted.each do |ref|
    ns, name = ref.split('/', 2)
    sleep 2 until client.get_object('v1', 'Pod', ns, name).nil? || Time.now > deadline
  end
  { 'node' => node, 'cordoned' => true, 'evicted' => evicted, 'skipped' => skipped }
end
