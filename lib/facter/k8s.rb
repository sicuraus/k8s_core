# frozen_string_literal: true

# The `k8s` fact describes the Kubernetes cluster this agent manages.
#
# It resolves only where a run is clearly about a cluster: inside a pod with a
# ServiceAccount token, or when K8S_CORE_KUBECONFIG names a kubeconfig. An
# ordinary node never contacts an API server. Set K8S_CORE_FACTS=false to
# disable it. Under `puppet device` the transport supplies this fact instead.
Facter.add(:k8s) do
  confine do
    next false if ENV['K8S_CORE_FACTS'].to_s == 'false'

    (!ENV['KUBERNETES_SERVICE_HOST'].to_s.empty? &&
      File.exist?('/var/run/secrets/kubernetes.io/serviceaccount/token')) ||
      !ENV['K8S_CORE_KUBECONFIG'].to_s.empty?
  end

  setcode do
    require_relative '../puppet_x/k8s_core'
    begin
      PuppetX::K8sCore::Facts.collect(PuppetX::K8sCore::Config.client(timeout: 10))
    rescue StandardError => e
      Facter.debug("k8s fact: #{e.message}")
      nil
    end
  end
end
