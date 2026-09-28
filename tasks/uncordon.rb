#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
params = JSON.parse($stdin.read)
lib = params['_installdir'] ? File.join(params['_installdir'], 'k8s_core', 'lib') : File.expand_path('../lib', __dir__)
require File.join(lib, 'puppet_x', 'k8s_core', 'task')

PuppetX::K8sCore::Task.run(params) do |p, client|
  PuppetX::K8sCore::Task.merge_patch(client, "/api/v1/nodes/#{p.fetch('node')}", 'spec' => { 'unschedulable' => nil })
  { 'node' => p['node'], 'cordoned' => false }
end
