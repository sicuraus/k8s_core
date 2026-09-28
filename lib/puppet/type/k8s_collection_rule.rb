# frozen_string_literal: true

require 'puppet/parameter/boolean'
require_relative '../../puppet_x/k8s_core'

Puppet::Type.newtype(:k8s_collection_rule) do
  @doc = <<-DOC
    @summary Applies one rule to every object of a kind, as it exists at apply time.

    For controls like "every Namespace has a Pod Security level", where the set
    of objects changes between runs. At apply time the rule lists objects of
    `kind` (optionally limited by `namespace`, `label_selector` and
    `field_selector`), drops the `exclude`d ones, keeps those matching every
    `match` condition, and generates one child resource per object, so each
    object appears as its own resource in the report:

    * `action => patch`: a `k8s_patch` of `patch` onto each object.
    * `action => report`: the same, but noop, so non-compliant objects are
      reported and nothing changes. Without `patch`, every matching object is
      reported as a violation (a noop `k8s_resource` absent).
    * `action => delete`: each matching object is deleted. Objects declared
      by a `k8s_resource` in this catalog are never deleted.

    Children inherit the rule's tags, so a report ties every change back to
    the rule (and, with the Compliance Engine, to its check and controls).

    `match` conditions are hashes of `path` (a JSONPath like
    `{.roleRef.name}` or `{.subjects[*].name}`), `op` and `value`. `op` is
    one of `equals`, `not_equals`, `contains` (any value at the path equals
    `value`), `present`, `absent`, `matches` and `not_matches` (regex).

    @example Warn on restricted Pod Security in every namespace but kube-system
      k8s_collection_rule { 'pod-security-warn':
        api_version => 'v1',
        kind        => 'Namespace',
        exclude     => ['kube-system'],
        action      => 'patch',
        patch       => { 'metadata' => { 'labels' => { 'pod-security.kubernetes.io/warn' => 'restricted' } } },
      }

    @example Report bindings that grant cluster-admin to anonymous users
      k8s_collection_rule { 'no-anonymous-cluster-admin':
        api_version => 'rbac.authorization.k8s.io/v1',
        kind        => 'ClusterRoleBinding',
        action      => 'report',
        match       => [
          { 'path' => '{.roleRef.name}', 'op' => 'equals', 'value' => 'cluster-admin' },
          { 'path' => '{.subjects[*].name}', 'op' => 'contains', 'value' => 'system:anonymous' },
        ],
      }
  DOC

  apply_to_all

  newparam(:name, namevar: true) do
    desc 'The rule name.'
  end

  newparam(:release, boolean: true, parent: Puppet::Parameter::Boolean) do
    desc <<-DESC
      Release the fields this rule's patches own on every object in scope
      (generated `k8s_patch` resources with `ensure => absent`). Declare the
      rule this way when a control is switched off: removing it from the
      catalog leaves its fields in place. Default false.
    DESC
    defaultto false
  end

  newparam(:api_version) do
    desc 'apiVersion of the kind, e.g. `v1`. Required.'
  end

  newparam(:kind) do
    desc 'The kind the rule covers. Required.'
  end

  newparam(:namespace) do
    desc 'For namespaced kinds: only this namespace. Default all namespaces.'
  end

  newparam(:label_selector) do
    desc 'A label selector string, e.g. `app!=legacy,tier in (web,api)`.'
  end

  newparam(:field_selector) do
    desc 'A field selector string.'
  end

  newparam(:exclude, array_matching: :all) do
    desc 'Object names (glob patterns) to skip; for namespaced kinds, `namespace/name` or a bare name.'
    defaultto []
    munge { |value| Array(value) }
  end

  newparam(:exclude_namespaces, array_matching: :all) do
    desc 'For namespaced kinds: namespaces (glob patterns) to skip entirely.'
    defaultto []
    munge { |value| Array(value) }
  end

  newparam(:match, array_matching: :all) do
    desc 'Conditions an object must meet (all of them) to be in scope.'
    defaultto []
    validate do |value|
      ops = %w[equals not_equals contains present absent matches not_matches]
      Array(value).each do |m|
        raise ArgumentError, 'each match condition must be a Hash with path and op' unless m.is_a?(Hash) && m['path'] && m['op']
        raise ArgumentError, "match op must be one of #{ops.join(', ')}" unless ops.include?(m['op'])
      end
    end
    munge { |value| Array(value) }
  end

  newparam(:action) do
    desc '`report`, `patch` or `delete`. Default `report`.'
    newvalues(:report, :patch, :delete)
    defaultto :report
  end

  newparam(:patch) do
    desc 'For `patch` and `report`: the fields every object must have, as a partial body.'
    validate { |value| raise ArgumentError, 'patch must be a Hash' unless value.is_a?(Hash) }
    munge { |value| PuppetX::K8sCore::Object.plain(value) }
  end

  newparam(:field_manager) do
    desc 'Field manager for patches. Default `openvox-patch`.'
    defaultto 'openvox-patch'
  end

  newparam(:drift_managers, array_matching: :all) do
    desc 'Passed to generated `k8s_patch` resources.'
    defaultto { PuppetX::K8sCore::DEFAULT_DRIFT_MANAGERS.dup }
  end

  validate do
    raise ArgumentError, 'api_version and kind are required' unless self[:api_version] && self[:kind]
    raise ArgumentError, 'action patch requires patch' if self[:action] == :patch && !self[:patch]
  end

  # Objects of this kind declared in the catalog (e.g. a Namespace created in
  # this run) are in place before the rule lists them.
  autorequire(:k8s_resource) do
    catalog.resources.select do |r|
      r.is_a?(Puppet::Type.type(:k8s_resource)) && r[:kind] == self[:kind] && r[:ensure] != :absent
    end
  end

  def excluded?(obj, namespaced)
    md = obj['metadata'] || {}
    name = md['name'].to_s
    ns = md['namespace'].to_s
    return true if namespaced && self[:exclude_namespaces].any? { |p| File.fnmatch?(p, ns) }

    self[:exclude].any? { |p| File.fnmatch?(p, name) || (namespaced && File.fnmatch?(p, "#{ns}/#{name}")) }
  end

  def matches?(obj)
    self[:match].all? do |m|
      values = PuppetX::K8sCore::Object.jsonpath(obj, m['path']).map { |v| v.is_a?(String) ? v : v.to_s }
      want = m['value'].to_s
      case m['op']
      when 'equals' then !values.empty? && values.all? { |v| v == want }
      when 'not_equals' then values.none? { |v| v == want }
      when 'contains' then values.include?(want)
      when 'present' then !values.empty?
      when 'absent' then values.empty?
      when 'matches' then values.any? { |v| v.match?(Regexp.new(want)) }
      when 'not_matches' then values.none? { |v| v.match?(Regexp.new(want)) }
      end
    end
  end

  def declared_keys
    catalog.resources.grep(Puppet::Type.type(:k8s_resource)).to_h do |r|
      [PuppetX::K8sCore::Object.key(r[:api_version], r[:kind], r[:namespace], r[:resource_name]), true]
    end
  end

  def eval_generate
    client = PuppetX::K8sCore.client
    info = client.resource_info(self[:api_version], self[:kind])
    unless info
      notice("#{self[:api_version]} #{self[:kind]} is not served; rule not applicable")
      return []
    end

    objs = client.list_objects(self[:api_version], self[:kind], namespace: self[:namespace],
                                                                label_selector: self[:label_selector],
                                                                field_selector: self[:field_selector])
    objs = objs.reject { |o| excluded?(o, info['namespaced']) }.select { |o| matches?(o) }
    debug("#{objs.size} #{self[:kind]} objects in scope")
    declared = declared_keys
    objs.map { |o| child_for(o, declared) }.compact
  end

  def child_for(obj, declared)
    md = obj['metadata'] || {}
    ref = PuppetX::K8sCore::Object.format_title(self[:kind], md['namespace'], md['name'])
    common = {
      title: "#{self[:name]}: #{ref}",
      api_version: self[:api_version],
      kind: self[:kind],
      resource_name: md['name'],
    }
    common[:namespace] = md['namespace'] if md['namespace']
    common[:noop] = true if self[:noop]

    if self[:action] == :delete || (self[:action] == :report && !self[:patch])
      return nil if self[:release]

      key = PuppetX::K8sCore::Object.key(self[:api_version], self[:kind], md['namespace'], md['name'])
      if declared[key]
        warning("#{ref} matches but is declared in this catalog; leaving it alone")
        return nil
      end
      opts = common.merge(ensure: :absent)
      opts[:noop] = true if self[:action] == :report
      return Puppet::Type.type(:k8s_resource).new(opts)
    end

    opts = common.merge(ensure: self[:release] ? :absent : :present, content: self[:patch], field_manager: self[:field_manager],
                        drift_managers: self[:drift_managers])
    opts[:noop] = true if self[:action] == :report
    Puppet::Type.type(:k8s_patch).new(opts)
  end
end
