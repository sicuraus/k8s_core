# frozen_string_literal: true

require_relative '../../../puppet_x/k8s_core/applier'

Puppet::Type.type(:k8s_patch).provide(:api) do
  desc 'Applies and releases individual fields with server-side apply.'

  include PuppetX::K8sCore::Applier

  def desired_body
    PuppetX::K8sCore::Object.deep_merge(PuppetX::K8sCore::Object.deep_dup(resource.should(:content) || {}), base_body)
  end

  def target_missing?
    return false unless live.nil?

    unless @reported_missing
      resource.notice("#{object_ref} does not exist; not applicable")
      @reported_missing = true
    end
    true
  end

  # Present when this field manager has applied fields to the object. A
  # missing target reads as whatever is wanted, so it never changes.
  def exists?
    return resource[:ensure] != :absent if target_missing?

    (live.dig('metadata', 'managedFields') || []).any? do |mf|
      mf['manager'] == resource[:field_manager] && mf['operation'] == 'Apply'
    end
  end

  def create
    apply_body(desired_body)
    @applied = true
  end

  # An apply with no fields releases everything this manager owns.
  def destroy
    apply_body(base_body)
  end

  def content
    return :absent if live.nil?

    PuppetX::K8sCore::Object.project(PuppetX::K8sCore::Object.normalize(live), resource.should(:content) || {})
  end

  def content=(_value)
    @apply = true
  end

  def content_insync?
    return true if target_missing?

    body_insync?(desired_body)
  end

  def flush
    apply_body(desired_body) if @apply && !@applied && resource[:ensure] != :absent
  end
end
