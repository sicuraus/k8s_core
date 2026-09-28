# frozen_string_literal: true

require_relative 'object'

module PuppetX
  module K8sCore
    # Shared parameter handling for types that reference one object.
    module TypeHelpers
      module_function

      # Fills kind/namespace/resource_name from a `Kind/[namespace/]name`
      # reference unless given explicitly. Returns the canonical reference.
      def resolve_reference(res, ref)
        kind, ns, name = Object.parse_title(ref)
        res[:kind] ||= kind if kind
        res[:resource_name] ||= name if name
        res[:namespace] ||= ns unless ns.to_s.empty?
        res.delete(:namespace) if res.parameters.include?(:namespace) && res[:namespace].to_s.empty?
        raise Puppet::ResourceError, "#{res.ref}: title must be Kind/name or Kind/namespace/name, or set kind and resource_name" unless res[:kind] && res[:resource_name]
        raise Puppet::ResourceError, "#{res.ref}: api_version is required" unless res[:api_version]

        Object.format_title(res[:kind], res[:namespace], res[:resource_name])
      end

      def reference_params(type)
        type.newparam(:kind) { desc 'The object kind. Parsed from the title when not given.' }
        type.newparam(:namespace) { desc 'The namespace of a namespaced object. Parsed from the title when not given.' }
        type.newparam(:resource_name) { desc 'The object name. Parsed from the title when not given.' }
        type.newparam(:api_version) do
          desc 'The object apiVersion, e.g. `v1` or `apps/v1`. Required.'
          validate do |value|
            raise ArgumentError, 'api_version must be a String like "v1" or "apps/v1"' unless value.is_a?(String) && !value.empty?
          end
        end
      end
    end
  end
end
