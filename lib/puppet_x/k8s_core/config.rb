# frozen_string_literal: true

require 'yaml'
require 'base64'
require_relative 'client'

module PuppetX
  module K8sCore
    # Resolves API credentials into Client options.
    #
    # Explicit settings win (a `server`, or a `kubeconfig`/`context` pair), which
    # is what `puppet device` and OpenBolt pass through the transport. With no
    # settings, the in-cluster ServiceAccount is used when present, then the
    # kubeconfig named by K8S_CORE_KUBECONFIG, KUBECONFIG or ~/.kube/config.
    module Config
      module_function

      def in_cluster?
        !ENV['KUBERNETES_SERVICE_HOST'].to_s.empty? && File.exist?(File.join(Client::SA_DIR, 'token'))
      end

      def resolve(settings = {})
        s = (settings || {}).transform_keys(&:to_s)
        opts = if !s['server'].to_s.empty?
                 explicit(s)
               elsif !s['kubeconfig'].to_s.empty? || !s['context'].to_s.empty?
                 from_kubeconfig(s['kubeconfig'], s['context'])
               elsif in_cluster?
                 in_cluster
               else
                 from_kubeconfig(nil, ENV.fetch('K8S_CORE_CONTEXT', nil))
               end
        opts[:timeout] = s['timeout'].to_i if s['timeout']
        opts
      end

      def client(settings = {})
        Client.new(**resolve(settings))
      end

      def explicit(s)
        token = s['token']
        token = token.unwrap if token.respond_to?(:unwrap)
        {
          server: s['server'],
          token: token,
          token_file: s['token_file'],
          ca_file: s['ca_file'],
          ca_data: s['ca_data'],
          insecure: truthy(s['insecure_skip_tls_verify']),
          description: s['server'],
        }
      end

      def in_cluster
        host = ENV.fetch('KUBERNETES_SERVICE_HOST', nil)
        host = "[#{host}]" if host.include?(':')
        {
          server: "https://#{host}:#{ENV['KUBERNETES_SERVICE_PORT'] || 443}",
          token_file: File.join(Client::SA_DIR, 'token'),
          ca_file: File.join(Client::SA_DIR, 'ca.crt'),
          description: 'in-cluster ServiceAccount',
        }
      end

      def kubeconfig_paths(path)
        list = if path && !path.empty?
                 [path]
               elsif !ENV['K8S_CORE_KUBECONFIG'].to_s.empty?
                 ENV['K8S_CORE_KUBECONFIG'].split(File::PATH_SEPARATOR)
               elsif !ENV['KUBECONFIG'].to_s.empty?
                 ENV['KUBECONFIG'].split(File::PATH_SEPARATOR)
               else
                 [File.join(Dir.home, '.kube', 'config')]
               end
        list.map { |p| File.expand_path(p) }.select { |p| File.file?(p) }
      end

      # Merges kubeconfig files the way kubectl does: first definition wins.
      def load_kubeconfig(path)
        files = kubeconfig_paths(path)
        raise Error, "No Kubernetes credentials: not in a cluster and no kubeconfig found (#{path || 'default paths'})" if files.empty?

        merged = { 'clusters' => [], 'users' => [], 'contexts' => [] }
        files.each do |f|
          doc = YAML.safe_load(File.read(f)) || {}
          merged['current-context'] ||= doc['current-context']
          %w[clusters users contexts].each do |k|
            (doc[k] || []).each do |entry|
              merged[k] << entry.merge('_dir' => File.dirname(f)) unless merged[k].any? { |e| e['name'] == entry['name'] }
            end
          end
        end
        merged
      end

      def from_kubeconfig(path, context_name)
        cfg = load_kubeconfig(path)
        ctx_name = context_name.to_s.empty? ? cfg['current-context'] : context_name
        ctx = cfg['contexts'].find { |c| c['name'] == ctx_name }
        raise Error, "kubeconfig context '#{ctx_name}' not found" unless ctx

        cluster = cfg['clusters'].find { |c| c['name'] == ctx.dig('context', 'cluster') }&.fetch('cluster', {})
        raise Error, "kubeconfig cluster for context '#{ctx_name}' not found" unless cluster

        user_entry = cfg['users'].find { |u| u['name'] == ctx.dig('context', 'user') }
        user = user_entry ? user_entry['user'] || {} : {}
        dir = user_entry ? user_entry['_dir'] : Dir.pwd

        {
          server: cluster['server'],
          ca_data: data_or_file(cluster['certificate-authority-data'], cluster['certificate-authority'], dir),
          insecure: truthy(cluster['insecure-skip-tls-verify']),
          token: user['token'],
          token_file: user['tokenFile'] ? File.expand_path(user['tokenFile'], dir) : nil,
          client_cert_data: data_or_file(user['client-certificate-data'], user['client-certificate'], dir),
          client_key_data: data_or_file(user['client-key-data'], user['client-key'], dir),
          exec: user['exec'],
          description: "kubeconfig context #{ctx_name}",
        }.compact
      end

      def data_or_file(data, file, dir)
        return Base64.decode64(data) if data && !data.empty?
        return File.read(File.expand_path(file, dir)) if file && !file.empty?

        nil
      end

      def truthy(v)
        v == true || v.to_s == 'true'
      end
    end
  end
end
