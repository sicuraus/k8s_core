# frozen_string_literal: true

require 'puppet/parameter/boolean'
require_relative '../../puppet_x/k8s_core/object'

Puppet::Type.newtype(:k8s_resource) do
  @doc = <<-DOC
    @summary Manages any Kubernetes object with server-side apply.

    The title is `Kind/namespace/name` for namespaced objects and `Kind/name`
    for cluster-scoped ones. Alternatively give any title and set `kind`,
    `namespace` and `resource_name` (the parameter shape of puppet-k8s's
    `kubectl_apply`). One object may be declared only once, whatever its title.

    `content` is the object body without `apiVersion`, `kind`, and
    `metadata.name`/`metadata.namespace`. It is applied with server-side apply;
    drift is detected by a server-side dry-run, so fields the API server
    defaults never show as changes. Fields another field manager owns are a
    conflict, reported with that manager's name, unless `force_conflicts`.

    Every object is labelled `openvox.voxpupuli.org/managed-by` (see
    `managed_by`) and annotated with its Puppet title, which is what
    `k8s_prune` uses to decide what it may delete.

    Namespaced objects autorequire their Namespace, and custom resources
    autorequire their CustomResourceDefinition, when those are in the catalog.

    @example A Deployment that must roll out before dependents run
      k8s_resource { 'Deployment/web/frontend':
        api_version => 'apps/v1',
        wait        => true,
        content     => {
          'spec' => {
            'replicas' => 2,
            'selector' => { 'matchLabels' => { 'app' => 'frontend' } },
            'template' => {
              'metadata' => { 'labels' => { 'app' => 'frontend' } },
              'spec'     => { 'containers' => [{ 'name' => 'web', 'image' => 'nginx:1.29' }] },
            },
          },
        },
      }
  DOC

  apply_to_all

  ensurable do
    desc 'Whether the object should exist.'
    defaultvalues
    defaultto :present
  end

  newparam(:name, namevar: true) do
    desc 'The object reference, `Kind/namespace/name` or `Kind/name`. Normalized to that form.'
  end

  newparam(:kind) do
    desc 'The object kind. Parsed from the title when not given.'
  end

  newparam(:namespace) do
    desc 'The namespace of a namespaced object. Parsed from the title when not given.'
  end

  newparam(:resource_name) do
    desc 'The object name (`metadata.name`). Parsed from the title when not given.'
  end

  newparam(:api_version) do
    desc 'The object apiVersion, e.g. `v1` or `apps/v1`. Required.'
    validate do |value|
      raise ArgumentError, 'api_version must be a String like "v1" or "apps/v1"' unless value.is_a?(String) && !value.empty?
    end
  end

  newproperty(:content) do
    desc <<-DESC
      The object body, without apiVersion, kind and metadata name/namespace.
      `metadata.labels` and `metadata.annotations` may be included.
    DESC
    defaultto({})

    validate do |value|
      raise ArgumentError, 'content must be a Hash' unless value.is_a?(Hash)

      %w[apiVersion kind].each do |k|
        raise ArgumentError, "content must not set #{k}; use the api_version parameter and the title" if value.key?(k)
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

  newparam(:sensitive_data, sensitive: true) do
    desc <<-DESC
      For Secrets: a Sensitive hash of plain-text values merged into `data` at
      apply time. Kept out of reports and diffs.
    DESC
    validate do |value|
      v = value.respond_to?(:unwrap) ? value.unwrap : value
      raise ArgumentError, 'sensitive_data must be a Hash' unless v.is_a?(Hash)
    end
  end

  newparam(:field_manager) do
    desc 'Server-side apply field manager. Default `openvox`, or $K8S_CORE_FIELD_MANAGER.'
    defaultto { PuppetX::K8sCore.default_field_manager }
  end

  newparam(:force_conflicts, boolean: true, parent: Puppet::Parameter::Boolean) do
    desc 'Take ownership of fields another field manager owns. Off by default.'
    defaultto false
  end

  newparam(:drift_managers, array_matching: :all) do
    desc <<-DESC
      Glob patterns for field managers whose edits are drift: a conflict with
      only these managers is taken back instead of failing. Default
      `['kubectl*', 'before-first-apply']`. Set `[]` to treat every conflict as
      a failure.
    DESC
    defaultto { PuppetX::K8sCore::DEFAULT_DRIFT_MANAGERS.dup }
  end

  newparam(:managed_by) do
    desc <<-DESC
      Value of the `openvox.voxpupuli.org/managed-by` label, naming the
      reconciliation scope that owns this object. Default `openvox`, or
      $K8S_CORE_MANAGED_BY (the reconciler sets it per run).
    DESC
    defaultto { PuppetX::K8sCore.default_managed_by }
    validate do |value|
      raise ArgumentError, "managed_by #{value.inspect} is not a valid label value" unless value.to_s.match?(PuppetX::K8sCore::LABEL_VALUE) && !value.to_s.empty?
    end
  end

  newparam(:wait, boolean: true, parent: Puppet::Parameter::Boolean) do
    desc <<-DESC
      Wait until the object is ready before dependents run: Deployments,
      StatefulSets and DaemonSets when rolled out; Jobs when complete; CRDs when
      established; anything else when its Ready condition is true (or it has
      none). A timeout fails the resource, so dependents are skipped.
    DESC
    defaultto false
  end

  newparam(:wait_timeout) do
    desc 'Seconds to wait for readiness (or deletion). Default 300.'
    defaultto 300
    munge { |v| Integer(v) }
  end

  def initialize(*args)
    super
    kind, ns, name = PuppetX::K8sCore::Object.parse_title(self[:name])
    self[:kind] ||= kind if kind
    self[:resource_name] ||= name if name
    self[:namespace] ||= ns unless ns.to_s.empty?
    delete(:namespace) if parameters.include?(:namespace) && self[:namespace].to_s.empty?
    raise Puppet::ResourceError, "#{ref}: title must be Kind/name or Kind/namespace/name, or set kind and resource_name" unless self[:kind] && self[:resource_name]
    raise Puppet::ResourceError, "#{ref}: api_version is required" unless self[:api_version]

    # Canonical name, so one object declared under two titles is a duplicate.
    self[:name] = PuppetX::K8sCore::Object.format_title(self[:kind], self[:namespace], self[:resource_name])
    parameters[:content].sensitive = true if PuppetX::K8sCore::Object.secret?(self[:kind]) && parameters[:content]
  end

  # sensitive_data is a parameter; its values never reach reports or diffs
  # (see the provider), so Puppet's warning about redacting it is noise.
  def set_sensitive_parameters(sensitive_parameters) # rubocop:disable Naming/AccessorMethodName
    super(sensitive_parameters - [:sensitive_data])
  end

  def self.k8s_resources(catalog)
    return [] unless catalog

    catalog.resources.grep(Puppet::Type.type(:k8s_resource))
  end

  # Namespaced objects require their Namespace (or, when both are being
  # removed, are removed before it); custom resources require the CRD that
  # defines them. One block per relationship type: a second would replace it.
  autorequire(:k8s_resource) do
    next [] if self[:ensure] == :absent

    group = PuppetX::K8sCore::Object.group_of(self[:api_version])
    self.class.k8s_resources(catalog).select do |r|
      next false if r[:ensure] == :absent

      if r[:kind] == 'Namespace'
        self[:namespace] && r[:resource_name] == self[:namespace]
      elsif r[:kind] == 'CustomResourceDefinition' && !group.empty? && self[:kind] != 'CustomResourceDefinition'
        spec = (r.should(:content) || {})['spec'] || {}
        spec['group'] == group && spec.dig('names', 'kind') == self[:kind]
      else
        false
      end
    end
  end

  autobefore(:k8s_resource) do
    next [] unless self[:namespace] && self[:ensure] == :absent

    self.class.k8s_resources(catalog).select do |r|
      r[:kind] == 'Namespace' && r[:resource_name] == self[:namespace] && r[:ensure] == :absent
    end
  end
end
