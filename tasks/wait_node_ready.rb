#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
params = JSON.parse($stdin.read)
lib = params['_installdir'] ? File.join(params['_installdir'], 'k8s_core', 'lib') : File.expand_path('../lib', __dir__)
require File.join(lib, 'puppet_x', 'k8s_core', 'task')

PuppetX::K8sCore::Task.run(params) do |p, client|
  deadline = Time.now + p.fetch('timeout', 900)
  loop do
    node = client.get_object('v1', 'Node', nil, p.fetch('node'))
    break { 'node' => p['node'], 'ready' => true, 'kubelet' => node.dig('status', 'nodeInfo', 'kubeletVersion') } if node && PuppetX::K8sCore::Object.condition_true?(node, 'Ready')
    raise PuppetX::K8sCore::Error, "node #{p['node']} not Ready after #{p['timeout'] || 900}s" if Time.now > deadline

    sleep 5
  end
end
