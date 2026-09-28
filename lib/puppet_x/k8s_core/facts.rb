# frozen_string_literal: true

module PuppetX
  module K8sCore
    # Builds the `k8s` fact from the API server.
    module Facts
      CLUSTER_INFO_NAMESPACE = 'openvox-system'
      CLUSTER_INFO_NAME = 'cluster-info'

      MANAGED = %w[eks gke aks].freeze

      module_function

      def collect(client)
        version = client.version
        disc = client.discovery
        kinds = disc.keys.sort
        groups = kinds.map { |k| k.split('/')[0..-3].join('/') }.uniq
        {
          'server' => client.server,
          'version' => {
            'git_version' => version['gitVersion'],
            'major' => version['major'].to_s.delete('^0-9'),
            'minor' => version['minor'].to_s.delete('^0-9'),
            'platform' => version['platform'],
          },
          'kinds' => kinds,
          'cluster' => cluster_info(client),
          'identity' => identity(client),
        }.tap do |f|
          dist = distribution(version['gitVersion'].to_s, groups, client)
          f['distribution'] = dist
          f['managed_control_plane'] = MANAGED.include?(dist)
        end
      end

      def distribution(git_version, groups, client)
        return 'harvester' if groups.include?('harvesterhci.io')
        return 'openshift' if groups.include?('config.openshift.io')
        return 'rke2' if git_version.include?('+rke2')
        return 'k3s' if git_version.include?('+k3s')
        return 'eks' if git_version.include?('-eks-')
        return 'gke' if git_version.include?('-gke.')

        node = begin
          client.get('/api/v1/nodes', query: { 'limit' => 1 })['items']&.first
        rescue ApiError
          nil
        end
        return 'unknown' unless node

        provider = node.dig('spec', 'providerID').to_s
        labels = node.dig('metadata', 'labels') || {}
        return 'aks' if provider.start_with?('azure://') || labels.key?('kubernetes.azure.com/cluster')
        return 'eks' if provider.start_with?('aws://') && labels.keys.any? { |k| k.start_with?('eks.amazonaws.com/') }
        return 'gke' if provider.start_with?('gce://') && labels.keys.any? { |k| k.start_with?('cloud.google.com/gke') }
        return 'kind' if provider.start_with?('kind://')

        'unknown'
      end

      # The cluster-info ConfigMap: data.name, data.environment, and its own
      # metadata.labels as the cluster's labels.
      def cluster_info(client)
        cm = client.get("/api/v1/namespaces/#{CLUSTER_INFO_NAMESPACE}/configmaps/#{CLUSTER_INFO_NAME}")
        data = cm['data'] || {}
        {
          'name' => data['name'],
          'environment' => data['environment'],
          'labels' => cm.dig('metadata', 'labels') || {},
        }.merge(data.reject { |k, _| %w[name environment].include?(k) })
      rescue ApiError
        {}
      end

      def identity(client)
        review = client.request(:post, '/apis/authentication.k8s.io/v1/selfsubjectreviews',
                                body: { 'apiVersion' => 'authentication.k8s.io/v1', 'kind' => 'SelfSubjectReview' })
        info = review.dig('status', 'userInfo') || {}
        { 'username' => info['username'], 'groups' => info['groups'] || [] }
      rescue ApiError
        {}
      end
    end
  end
end
