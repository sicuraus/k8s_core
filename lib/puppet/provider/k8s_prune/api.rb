# frozen_string_literal: true

require 'json'
require_relative '../../../puppet_x/k8s_core'

Puppet::Type.type(:k8s_prune).provide(:api) do
  desc 'Prunes from a ConfigMap inventory.'

  # Not constants: a constant in this block would land in the top-level namespace.
  def o
    PuppetX::K8sCore::Object
  end

  def client
    PuppetX::K8sCore.client
  end

  def scope
    resource[:name]
  end

  def cm_name
    "inventory-#{scope}"
  end

  def entry_key(e)
    o.key(e['apiVersion'], e['kind'], e['namespace'], e['name'])
  end

  def entry_ref(e)
    o.format_title(e['kind'], e['namespace'], e['name'])
  end

  # Objects this catalog declares for the scope.
  def current
    @current ||= begin
      declared = resource.catalog.resources.select do |r|
        r.is_a?(Puppet::Type.type(:k8s_resource)) && r[:managed_by] == scope && r[:ensure] != :absent && r[:inventory]
      end
      declared.map do |r|
        { 'apiVersion' => r[:api_version], 'kind' => r[:kind], 'namespace' => r[:namespace],
          'name' => r[:resource_name], 'title' => r.title, }.compact
      end
    end
  end

  def previous
    return @previous if defined?(@previous)

    @inventory_cm = client.get_object('v1', 'ConfigMap', resource[:inventory_namespace], cm_name)
    raw = @inventory_cm&.dig('data', PuppetX::K8sCore::INVENTORY_KEY)
    @previous = raw ? JSON.parse(raw) : []
  rescue JSON::ParserError => e
    raise PuppetX::K8sCore::Error, "#{resource[:inventory_namespace]}/#{cm_name}: unreadable inventory: #{e.message}"
  end

  def rank(e)
    group = o.group_of(e['apiVersion'])
    return 2 if %w[Namespace CustomResourceDefinition].include?(e['kind'])
    return 1 if group.empty? || group.end_with?('.k8s.io') || PuppetX::K8sCore::BUILTIN_GROUPS.include?(group)

    0
  end

  # Works out what this run would delete and record.
  def plan
    return @plan if @plan

    current_keys = current.to_h { |e| [entry_key(e), true] }
    delete = []
    keep = []
    notes = []
    previous.reject { |e| current_keys[entry_key(e)] }.each do |e|
      live = begin
        client.resource_info(e['apiVersion'], e['kind']) &&
          client.get_object(e['apiVersion'], e['kind'], e['namespace'], e['name'])
      rescue PuppetX::K8sCore::ApiError => err
        raise unless err.forbidden?

        notes << "#{entry_ref(e)}: cannot read (#{err.message}); keeping it in the inventory"
        keep << e
        next
      end
      next if live.nil? # already gone

      labels = live.dig('metadata', 'labels') || {}
      annotations = live.dig('metadata', 'annotations') || {}
      if labels[PuppetX::K8sCore::MANAGED_BY] != scope
        notes << "#{entry_ref(e)}: now managed by #{labels[PuppetX::K8sCore::MANAGED_BY].inspect}; releasing it"
      elsif annotations[PuppetX::K8sCore::PRUNE_ANNOTATION] == 'disabled'
        notes << "#{entry_ref(e)}: pruning disabled by annotation; releasing it"
      elsif resource[:protected_kinds].include?(e['kind'])
        notes << "#{entry_ref(e)}: #{e['kind']} is prune-protected; delete it with ensure => absent"
        keep << e
      else
        delete << e
      end
    end

    mode = resource[:prune]
    record = current.dup
    case mode
    when :true then record.concat(keep)
    when :dryrun then record.concat(keep).concat(delete)
    end
    record = record.uniq { |e| entry_key(e) }.sort_by { |e| entry_key(e) }
    would_delete = (mode == :dryrun) ? delete : []
    delete = [] unless mode == :true

    @plan = { delete: delete.sort_by { |e| [rank(e), entry_key(e)] }, record: record, notes: notes,
              would_delete: would_delete, }
  end

  def inventory
    p = plan
    p[:notes].each { |n| resource.notice(n) }
    p[:would_delete].each { |e| resource.warning("would prune #{entry_ref(e)} (dryrun)") }
    recorded = previous.sort_by { |e| entry_key(e) }
    (p[:delete].empty? && recorded == p[:record]) ? :current : :stale
  end

  def inventory=(_value)
    p = plan
    limit = [(resource[:max_fraction] * previous.size).ceil, 1].max
    if p[:delete].size > limit && !resource[:allow_mass_prune]
      raise PuppetX::K8sCore::Error,
            "refusing to prune #{p[:delete].size} of #{previous.size} objects (limit #{limit}): " \
            "#{p[:delete].map { |e| entry_ref(e) }.join(', ')}. Set allow_mass_prune to proceed."
    end

    p[:delete].each do |e|
      client.delete_object(e['apiVersion'], e['kind'], e['namespace'], e['name'])
      resource.notice("pruned #{entry_ref(e)}")
    end
    write_inventory(p[:record])
  end

  def change_summary
    p = plan
    parts = []
    parts << "pruned #{p[:delete].size}: #{p[:delete].map { |e| entry_ref(e) }.join(', ')}" unless p[:delete].empty?
    parts << "inventory #{cm_name} records #{p[:record].size} objects"
    parts.join('; ')
  end

  def write_inventory(entries)
    body = {
      'apiVersion' => 'v1', 'kind' => 'ConfigMap',
      'metadata' => { 'name' => cm_name, 'namespace' => resource[:inventory_namespace],
                      'labels' => { PuppetX::K8sCore::INVENTORY_LABEL => scope }, },
      'data' => { PuppetX::K8sCore::INVENTORY_KEY => JSON.pretty_generate(entries) },
    }
    client.apply(body, field_manager: 'openvox-inventory', force: true)
  end
end
