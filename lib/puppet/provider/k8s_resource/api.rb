# frozen_string_literal: true

require 'base64'
require_relative '../../../puppet_x/k8s_core/applier'

Puppet::Type.type(:k8s_resource).provide(:api) do
  desc 'Manages Kubernetes objects through the API server with server-side apply.'

  include PuppetX::K8sCore::Applier

  def force_conflicts?
    resource[:force_conflicts]
  end

  def desired_body
    content = PuppetX::K8sCore::Object.deep_dup(resource.should(:content) || {})
    body = PuppetX::K8sCore::Object.deep_merge(content, base_body)
    md = body['metadata']
    md['labels'] = (md['labels'] || {}).merge(PuppetX::K8sCore::MANAGED_BY => resource[:managed_by])
    md['annotations'] = (md['annotations'] || {}).merge(PuppetX::K8sCore::TITLE_ANNOTATION => resource.title)
    if (secret = resource[:sensitive_data])
      secret = secret.unwrap if secret.respond_to?(:unwrap)
      encoded = secret.to_h { |k, v| [k.to_s, Base64.strict_encode64(v.to_s)] }
      body['data'] = (body['data'] || {}).merge(encoded)
    end
    body
  end

  def exists?
    !live.nil?
  end

  def create
    apply_body(desired_body)
    @applied = true
  end

  def destroy
    client.delete_object(api_version, kind, namespace, object_name)
    wait_until_gone(resource[:wait_timeout]) if resource[:wait]
    @live = nil
  end

  # The live object, limited to the fields `content` names, for reports.
  def content
    return :absent if live.nil?

    PuppetX::K8sCore::Object.project(PuppetX::K8sCore::Object.normalize(live), resource.should(:content) || {})
  end

  def content=(_value)
    @apply = true
  end

  def content_insync?
    insync = body_insync?(desired_body)
    wait_until_ready(resource[:wait_timeout]) if insync && resource[:wait] && live
    insync
  end

  def flush
    return if @live.nil? && !@apply

    apply_body(desired_body) if @apply && !@applied
    return unless @apply || @applied

    wait_until_ready(resource[:wait_timeout]) if resource[:wait]
    wait_until_ready(60) if kind == 'CustomResourceDefinition' && !resource[:wait]
  end
end
