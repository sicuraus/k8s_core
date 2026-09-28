# frozen_string_literal: true

require 'puppet/parameter/boolean'
require_relative '../../puppet_x/k8s_core/object'

Puppet::Type.newtype(:k8s_prune) do
  @doc = <<-DOC
    @summary Deletes objects a scope managed before but no longer declares.

    Declare one per reconciliation scope; the title is the scope, which is the
    `managed_by` value of the `k8s_resource`s it covers. It runs after all of
    them, and not at all if any of them failed.

    After each run it records the scope's objects in the ConfigMap
    `inventory-<scope>` in `inventory_namespace`. Candidates for deletion are
    objects in the previous inventory that are not in this catalog. A
    candidate is skipped when its live `openvox.voxpupuli.org/managed-by`
    label no longer names this scope (someone adopted it) or it carries the
    annotation `openvox.voxpupuli.org/prune: disabled`.

    Safety rails:

    * `protected_kinds` (Namespaces, PVCs, CRDs and CertificateAuthorities by
      default) are never pruned; remove them with `ensure => absent`.
    * No more than `max_fraction` of the inventory is deleted in one run
      unless `allow_mass_prune` is set.
    * `prune => dryrun` reports what would be deleted and keeps it in the
      inventory; `prune => false` only records the inventory.

    Deletion order is custom resources, then built-in kinds, then Namespaces
    and CRDs, with foreground propagation.

    @example
      k8s_prune { 'platform': prune => 'dryrun' }
  DOC

  apply_to_all

  newparam(:name, namevar: true) do
    desc 'The scope: the `managed_by` value of the resources it covers.'
    validate do |value|
      raise ArgumentError, "#{value.inspect} is not a valid label value" unless value.to_s.match?(PuppetX::K8sCore::LABEL_VALUE) && !value.to_s.empty?
    end
  end

  newparam(:prune) do
    desc '`true` deletes, `dryrun` reports, `false` only records the inventory. Default true.'
    newvalues(:true, :false, :dryrun)
    defaultto :true
  end

  newparam(:inventory_namespace) do
    desc 'Namespace of the inventory ConfigMap. Default `openvox-system`.'
    defaultto 'openvox-system'
  end

  newparam(:max_fraction) do
    desc 'Largest share of the previous inventory deleted in one run (at least one object). Default 0.2.'
    defaultto 0.2
    munge { |v| Float(v) }
  end

  newparam(:allow_mass_prune, boolean: true, parent: Puppet::Parameter::Boolean) do
    desc 'Lift the max_fraction limit for this run. Defaults to $K8S_CORE_ALLOW_MASS_PRUNE.'
    defaultto { ENV['K8S_CORE_ALLOW_MASS_PRUNE'].to_s == 'true' }
  end

  newparam(:protected_kinds, array_matching: :all) do
    desc 'Kinds never pruned.'
    defaultto %w[Namespace PersistentVolumeClaim CustomResourceDefinition CertificateAuthority]
  end

  newproperty(:inventory) do
    desc 'Internal: `current` when nothing is left to prune or record. Do not set.'
    defaultto :current
    newvalues(:current, :stale)

    def insync?(is)
      is == :current
    end

    def change_to_s(_old, _new)
      provider.change_summary
    end
  end

  # Runs after collection rules, whose generated objects join the inventory.
  autorequire(:k8s_collection_rule) do
    catalog.resources.grep(Puppet::Type.type(:k8s_collection_rule))
  end

  # Runs after every resource of its scope.
  autorequire(:k8s_resource) do
    catalog.resources.select do |r|
      r.is_a?(Puppet::Type.type(:k8s_resource)) &&
        (r[:managed_by] == self[:name] || (r[:kind] == 'Namespace' && r[:resource_name] == self[:inventory_namespace]))
    end
  end
end
