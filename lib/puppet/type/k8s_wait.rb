# frozen_string_literal: true

require_relative '../../puppet_x/k8s_core/type_helpers'

Puppet::Type.newtype(:k8s_wait) do
  @doc = <<-DOC
    @summary A readiness gate: waits for a condition on a Kubernetes object.

    Fails the resource when the condition is not met within `timeout`, so
    everything that depends on it is skipped. Use it when the gate is
    something other than the object you just applied; for that, prefer
    `k8s_resource { ...: wait => true }`.

    `condition` takes the forms `kubectl wait --for` accepts:

    * `ready` (default): the built-in readiness rules of `k8s_resource`'s `wait`.
    * `delete`: the object no longer exists. `exists`: it does.
    * `condition=Available` or `condition=Available=False`, or just `Available`.
    * `jsonpath={.status.phase}=Running`, or `jsonpath={.status.loadBalancer.ingress}`
      to wait for the path to have any value.

    @example Wait for a Job created by an operator
      k8s_wait { 'Job/db/migrate-42':
        api_version => 'batch/v1',
        condition   => 'condition=Complete',
        timeout     => 900,
      }
  DOC

  apply_to_all

  newparam(:name, namevar: true) do
    desc 'The object reference, `Kind/namespace/name` or `Kind/name`, or any title with kind and resource_name set.'
  end

  PuppetX::K8sCore::TypeHelpers.reference_params(self)

  newparam(:condition) do
    desc 'What to wait for; see the type description. Default `ready`.'
    defaultto 'ready'
  end

  newparam(:timeout) do
    desc 'Seconds to wait before failing. Default 300.'
    defaultto 300
    munge { |v| Integer(v) }
  end

  newparam(:interval) do
    desc 'Seconds between checks. Default 2.'
    defaultto 2
    munge { |v| Float(v) }
  end

  newproperty(:satisfied) do
    desc 'Internal: whether the condition holds. Do not set.'
    defaultto :true
    newvalues(:true, :false)

    def insync?(is)
      is == :true
    end

    def change_to_s(_from, _to)
      "#{resource[:condition]} not yet met on #{provider.object_ref}"
    end
  end

  def initialize(*args)
    super
    @reference = PuppetX::K8sCore::TypeHelpers.resolve_reference(self, self[:name])
  end

  autorequire(:k8s_resource) do
    catalog.resources.select do |r|
      r.is_a?(Puppet::Type.type(:k8s_resource)) && r[:kind] == self[:kind] &&
        r[:resource_name] == self[:resource_name] && r[:namespace] == self[:namespace]
    end
  end
end
