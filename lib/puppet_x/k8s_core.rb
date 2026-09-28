# frozen_string_literal: true

require_relative 'k8s_core/client'
require_relative 'k8s_core/config'
require_relative 'k8s_core/object'
require_relative 'k8s_core/facts'

module PuppetX
  # Shared code for the k8s_core types, transport, facts, functions and tasks.
  module K8sCore
    # The client for the current run.
    #
    # Under `puppet device` or an OpenBolt `remote` target, the Resource API
    # transport is the current network device and supplies the connection.
    # Otherwise (`puppet apply` in a pod, or on a workstation), credentials are
    # resolved from the environment; see Config.resolve.
    def self.client
      dev = defined?(Puppet::Util::NetworkDevice) ? Puppet::Util::NetworkDevice.current : nil
      return dev.transport.k8s_client if dev.respond_to?(:transport) && dev.transport.respond_to?(:k8s_client)

      @client ||= Config.client
    end

    # Used by tests and long-lived processes to drop cached connections.
    def self.reset!
      @client&.close
      @client = nil
    end

    def self.default_managed_by
      v = ENV['K8S_CORE_MANAGED_BY'].to_s
      v.empty? ? 'openvox' : v
    end

    def self.default_field_manager
      v = ENV['K8S_CORE_FIELD_MANAGER'].to_s
      v.empty? ? 'openvox' : v
    end
  end
end
