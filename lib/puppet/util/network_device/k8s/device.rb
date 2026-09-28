# frozen_string_literal: true

require 'puppet/resource_api/transport/wrapper'

# Glue so `puppet device` can use the `k8s` transport (device.conf `type k8s`).
module Puppet::Util::NetworkDevice::K8s # rubocop:disable Style/ClassAndModuleChildren
  # The device wrapper for the k8s transport.
  class Device < Puppet::ResourceApi::Transport::Wrapper
    def initialize(url_or_config, _options = {})
      super('k8s', url_or_config)
    end
  end
end
