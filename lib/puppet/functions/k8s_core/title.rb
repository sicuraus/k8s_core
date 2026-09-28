# frozen_string_literal: true

# @summary The `k8s_resource` title for an object hash: `Kind/namespace/name` or `Kind/name`.
Puppet::Functions.create_function(:'k8s_core::title') do
  # @param object A Kubernetes object with kind and metadata.name.
  # @param namespace Namespace to use when the object names none.
  # @return The title.
  dispatch :title do
    param 'Hash', :object
    optional_param 'Optional[String]', :namespace
    return_type 'String'
  end

  def title(object, namespace = nil)
    md = object['metadata'] || {}
    raise Puppet::ParseError, 'k8s_core::title: object needs kind and metadata.name' unless object['kind'] && md['name']

    ns = md['namespace'] || namespace
    ns.to_s.empty? ? "#{object['kind']}/#{md['name']}" : "#{object['kind']}/#{ns}/#{md['name']}"
  end
end
