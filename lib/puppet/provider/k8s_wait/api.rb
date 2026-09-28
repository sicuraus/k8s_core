# frozen_string_literal: true

require_relative '../../../puppet_x/k8s_core/applier'

Puppet::Type.type(:k8s_wait).provide(:api) do
  desc 'Polls the Kubernetes API until a condition holds.'

  include PuppetX::K8sCore::Applier

  # Polls until met; fails on timeout. A noop run checks once.
  def satisfied
    deadline = Time.now + resource[:timeout]
    reason = nil
    loop do
      met, reason = check
      return :true if met
      return :false if noop?

      if Time.now > deadline
        raise PuppetX::K8sCore::Error,
              "#{object_ref}: #{resource[:condition]} not met after #{resource[:timeout]}s (#{reason})"
      end
      Puppet.debug("#{object_ref}: waiting for #{resource[:condition]} (#{reason})")
      sleep resource[:interval]
    end
  end

  def satisfied=(_value)
    # Nothing to change: #satisfied already failed or returned.
  end

  def check
    cond = resource[:condition].to_s
    obj = kind_info ? client.get_object(api_version, kind, namespace, object_name) : nil
    return [obj.nil?, obj ? 'still exists' : 'deleted'] if cond == 'delete'
    return [false, 'does not exist'] if obj.nil?
    return [true, 'exists'] if cond == 'exists'
    return PuppetX::K8sCore::Object.ready(obj) if cond == 'ready'

    if cond.start_with?('jsonpath=')
      expr, want = split_jsonpath(cond.delete_prefix('jsonpath='))
      values = PuppetX::K8sCore::Object.jsonpath(obj, expr)
      return [!values.empty? && values.none?(&:nil?), 'no value'] if want.nil?

      got = values.map { |v| v.is_a?(String) ? v : JSON.generate(v) }
      return [got.include?(want), "#{expr} is #{got.join(',').inspect}"]
    end

    type, status = cond.delete_prefix('condition=').split('=', 2)
    status ||= 'True'
    c = PuppetX::K8sCore::Object.condition(obj, type)
    [c && c['status'].casecmp?(status), c ? "#{type}=#{c['status']}: #{c['message']}" : "no #{type} condition"]
  end

  # "{.a.b}=value" => ["{.a.b}", "value"]; "{.a.b}" => ["{.a.b}", nil]
  def split_jsonpath(s)
    if s.start_with?('{') && (close = s.index('}'))
      rest = s[(close + 1)..]
      [s[0..close], rest.start_with?('=') ? rest[1..] : nil]
    else
      path, want = s.split('=', 2)
      [path, want]
    end
  end
end
