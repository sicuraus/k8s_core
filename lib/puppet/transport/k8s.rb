# frozen_string_literal: true

require_relative '../../puppet_x/k8s_core'

module Puppet::Transport
  # The `k8s` Resource API transport: a connection to one Kubernetes API server,
  # used by `puppet device` and by OpenBolt `remote` targets.
  class K8s
    attr_reader :k8s_client

    def initialize(_context, connection_info)
      settings = connection_info.transform_keys(&:to_s).compact
      @k8s_client = PuppetX::K8sCore::Config.client(settings)
    end

    def verify(_context)
      @k8s_client.version
    end

    def facts(_context)
      k8s = PuppetX::K8sCore::Facts.collect(@k8s_client)
      {
        'operatingsystem' => 'Kubernetes',
        'operatingsystemrelease' => k8s.dig('version', 'git_version'),
        'k8s' => k8s,
      }
    end

    def close(_context)
      @k8s_client.close
    end
  end
end
