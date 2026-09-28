#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
params = JSON.parse($stdin.read)
lib = params['_installdir'] ? File.join(params['_installdir'], 'k8s_core', 'lib') : File.expand_path('../lib', __dir__)
require File.join(lib, 'puppet_x', 'k8s_core', 'task')

PuppetX::K8sCore::Task.run(params) do |_params, client|
  ns = params.fetch('namespace')
  template = if params['from_cronjob']
               cj = client.get_object('batch/v1', 'CronJob', ns, params['from_cronjob'])
               raise PuppetX::K8sCore::Error, "CronJob #{ns}/#{params['from_cronjob']} not found" unless cj

               cj.dig('spec', 'jobTemplate', 'spec')
             else
               raise ArgumentError, 'give image (and optionally command), or from_cronjob' unless params['image']

               container = { 'name' => 'job', 'image' => params['image'] }
               container['command'] = params['command'] if params['command']
               job_pod = { 'restartPolicy' => 'Never', 'containers' => [container] }
               job_pod['serviceAccountName'] = params['service_account'] if params['service_account']
               { 'backoffLimit' => 0, 'template' => { 'spec' => job_pod } }
             end
  pod_spec = template.dig('template', 'spec')
  pod_spec['containers'].each do |c|
    c['image'] = params['image'] if params['image'] && params['from_cronjob']
    (params['env'] || {}).each { |k, v| (c['env'] ||= []) << { 'name' => k, 'value' => v } }
  end
  prefix = params['name'] || params['from_cronjob'] || 'bolt-job'
  job = {
    'apiVersion' => 'batch/v1', 'kind' => 'Job',
    'metadata' => { 'generateName' => "#{prefix[0, 50]}-", 'namespace' => ns,
                    'labels' => { PuppetX::K8sCore::MANAGED_BY => 'bolt-run-job' }, },
    'spec' => template.merge('ttlSecondsAfterFinished' => params['keep'] ? nil : 600).compact,
  }
  created = client.request(:post, client.resource_path('batch/v1', 'Job', ns), body: job)
  name = created.dig('metadata', 'name')

  deadline = Time.now + params.fetch('timeout', 600)
  status = nil
  stuck = Hash.new(0)
  loop do
    obj = client.get_object('batch/v1', 'Job', ns, name)
    if PuppetX::K8sCore::Object.condition_true?(obj, 'Complete')
      status = 'succeeded'
    elsif PuppetX::K8sCore::Object.condition_true?(obj, 'Failed')
      status = 'failed'
    elsif Time.now > deadline
      status = 'timeout'
    end
    break if status

    # Fail fast on pods that cannot start at all.
    running = client.get("/api/v1/namespaces/#{ns}/pods", query: { 'labelSelector' => "job-name=#{name}" })['items'] || []
    running.each do |pod|
      (pod.dig('status', 'containerStatuses') || []).each do |cs|
        reason = cs.dig('state', 'waiting', 'reason')
        next unless %w[ErrImagePull ImagePullBackOff InvalidImageName CreateContainerConfigError].include?(reason)

        stuck[reason] += 1
        next if stuck[reason] < 3

        client.delete_object('batch/v1', 'Job', ns, name, propagation: 'Background') unless params['keep']
        raise PuppetX::K8sCore::Task::Failure.new("Job #{ns}/#{name} cannot start: #{reason}: #{cs.dig('state', 'waiting', 'message')}",
                                                  'job' => name, 'reason' => reason)
      end
    end

    sleep 2
  end

  pods = client.get("/api/v1/namespaces/#{ns}/pods", query: { 'labelSelector' => "job-name=#{name}" })['items'] || []
  logs = pods.to_h do |p|
    pname = p.dig('metadata', 'name')
    text = begin
      client.request(:get, "/api/v1/namespaces/#{ns}/pods/#{pname}/log", accept: '*/*', raw: true,
                                                                         query: { 'tailLines' => 2000 })
    rescue PuppetX::K8sCore::ApiError => e
      "(logs unavailable: #{e.message})"
    end
    [pname, text]
  end
  exit_codes = pods.flat_map { |p| (p.dig('status', 'containerStatuses') || []).map { |c| c.dig('state', 'terminated', 'exitCode') } }.compact
  client.delete_object('batch/v1', 'Job', ns, name, propagation: 'Background') unless params['keep']

  result = { 'job' => name, 'namespace' => ns, 'status' => status, 'exit_codes' => exit_codes, 'logs' => logs }
  raise PuppetX::K8sCore::Task::Failure.new("Job #{ns}/#{name} #{status}", result) unless status == 'succeeded'

  result
end
