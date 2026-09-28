# frozen_string_literal: true

require 'puppet_x/k8s_core'

# An in-memory stand-in for PuppetX::K8sCore::Client: enough of the API for
# provider specs, including server-side apply field ownership in outline.
class FakeK8sClient
  KINDS = {
    'v1/Namespace' => { 'plural' => 'namespaces', 'namespaced' => false },
    'v1/ConfigMap' => { 'plural' => 'configmaps', 'namespaced' => true },
    'v1/Secret' => { 'plural' => 'secrets', 'namespaced' => true },
    'apps/v1/Deployment' => { 'plural' => 'deployments', 'namespaced' => true },
  }.freeze

  attr_reader :objects, :applies, :deletes

  def initialize
    @objects = {}
    @applies = []
    @deletes = []
    @conflicts = {}
  end

  def server
    'https://fake'
  end

  def resource_info(api_version, kind)
    KINDS["#{api_version}/#{kind}"]
  end

  def discovery(refresh: false) # rubocop:disable Lint/UnusedMethodArgument
    KINDS
  end

  def key(api_version, kind, ns, name)
    [api_version, kind, ns.to_s, name]
  end

  def put(obj)
    md = obj['metadata']
    @objects[key(obj['apiVersion'], obj['kind'], md['namespace'], md['name'])] = obj
  end

  def get_object(api_version, kind, ns, name)
    o = @objects[key(api_version, kind, ns, name)]
    o && PuppetX::K8sCore::Object.deep_dup(o)
  end

  # Make the next apply by anyone but `manager` conflict.
  def conflict_on(obj_key, manager)
    @conflicts[obj_key] = manager
  end

  def apply(body, field_manager:, force: false, dry_run: false)
    md = body['metadata']
    k = key(body['apiVersion'], body['kind'], md['namespace'], md['name'])
    if (owner = @conflicts[k]) && owner != field_manager && !force
      raise PuppetX::K8sCore::ApiError.new(409, JSON.generate(
                                                  'message' => "Apply failed with 1 conflict: conflict with \"#{owner}\": .data.x",
                                                  'details' => { 'causes' => [{ 'message' => "conflict with \"#{owner}\"" }] },
                                                ), 'PATCH', '/fake')
    end
    live = @objects[k] || {}
    merged = PuppetX::K8sCore::Object.deep_merge(PuppetX::K8sCore::Object.deep_dup(live), body)
    merged['metadata']['managedFields'] = [{ 'manager' => field_manager, 'operation' => 'Apply' }]
    return merged if dry_run

    @conflicts.delete(k) if force
    @applies << body
    @objects[k] = merged
  end

  def delete_object(api_version, kind, ns, name, propagation: 'Foreground') # rubocop:disable Lint/UnusedMethodArgument
    @deletes << key(api_version, kind, ns, name)
    @objects.delete(key(api_version, kind, ns, name))
  end

  def list_objects(api_version, kind, namespace: nil, label_selector: nil, field_selector: nil) # rubocop:disable Lint/UnusedMethodArgument
    @objects.values.select { |o| o['apiVersion'] == api_version && o['kind'] == kind }
  end

  def close; end
end
