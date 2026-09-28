# frozen_string_literal: true

require_relative '../../puppet_x/k8s_core/type_helpers'

Puppet::Type.newtype(:k8s_patch) do
  @doc = <<-DOC
    @summary Owns specific fields of an existing Kubernetes object.

    Applies only the fields in `content` to an object someone else owns, with
    server-side apply under its own field manager. Unlike `k8s_resource` it:

    * never creates the object: a missing target is reported as not
      applicable, not as a failure;
    * is never labelled or put in a prune inventory, so no prune deletes it;
    * with `ensure => absent`, releases only its own fields (fields no other
      manager owns are removed; the object stays).

    A conflict with another declarative owner (Helm, Argo CD, Flux, an
    operator) fails and names that manager; imperative kubectl edits are
    drift and are taken back (see `drift_managers`).

    Several patches may target one object; the title is free-form.

    @example Label a namespace for Pod Security admission
      k8s_patch { 'Namespace/team-a':
        api_version   => 'v1',
        field_manager => 'sicura',
        content       => { 'metadata' => { 'labels' => {
          'pod-security.kubernetes.io/warn' => 'restricted',
        } } },
      }
  DOC

  apply_to_all

  ensurable do
    desc '`present` applies the fields; `absent` releases them.'
    defaultvalues
    defaultto :present
  end

  newparam(:name, namevar: true) do
    desc 'Any title. When `kind` and `resource_name` are not set it must be `Kind/[namespace/]name`.'
  end

  PuppetX::K8sCore::TypeHelpers.reference_params(self)

  newparam(:target) do
    desc 'The object reference `Kind/[namespace/]name`, when the title is something else.'
  end

  newproperty(:content) do
    desc 'The fields to own, as a partial object body (no apiVersion, kind, or metadata name/namespace).'

    validate do |value|
      raise ArgumentError, 'content must be a Hash' unless value.is_a?(Hash)

      %w[apiVersion kind].each do |k|
        raise ArgumentError, "content must not set #{k}" if value.key?(k)
      end
    end

    munge { |value| PuppetX::K8sCore::Object.plain(value) }

    def insync?(_is)
      provider.content_insync?
    end

    def change_to_s(_old, _new)
      provider.change_summary
    end

    def is_to_s(value)
      value.is_a?(Hash) ? PuppetX::K8sCore::Object.fmt(value) : value.to_s
    end

    def should_to_s(value)
      value.is_a?(Hash) ? PuppetX::K8sCore::Object.fmt(value) : value.to_s
    end
  end

  newparam(:field_manager) do
    desc 'Server-side apply field manager for these fields. Default `openvox-patch`.'
    defaultto 'openvox-patch'
  end

  newparam(:drift_managers, array_matching: :all) do
    desc 'Glob patterns for field managers whose conflicting edits are drift to take back. Default `kubectl*`, `before-first-apply`.'
    defaultto { PuppetX::K8sCore::DEFAULT_DRIFT_MANAGERS.dup }
  end

  def initialize(*args)
    super
    PuppetX::K8sCore::TypeHelpers.resolve_reference(self, self[:target] || self[:name])
    parameters[:content].sensitive = true if PuppetX::K8sCore::Object.secret?(self[:kind]) && parameters[:content]
  end

  autorequire(:k8s_resource) do
    catalog.resources.select do |r|
      r.is_a?(Puppet::Type.type(:k8s_resource)) && r[:kind] == self[:kind] &&
        r[:resource_name] == self[:resource_name] && r[:namespace] == self[:namespace]
    end
  end
end
