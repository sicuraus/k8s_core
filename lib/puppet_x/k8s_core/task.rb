# frozen_string_literal: true

require 'json'
require_relative '../k8s_core'

module PuppetX
  module K8sCore
    # Scaffolding for the module's Bolt tasks.
    #
    # Tasks are `remote: true`: against an OpenBolt `remote` target they get the
    # target's `k8s` transport settings in `_target`; run locally (e.g. in a pod
    # with `transport: local`) they use the in-cluster ServiceAccount or kubeconfig.
    module Task
      TARGET_KEYS = %w[kubeconfig context server token token_file ca_file insecure_skip_tls_verify timeout].freeze
      FIELD_MANAGER = 'openbolt'

      # A task failure with structured details for the Bolt result.
      class Failure < Error
        attr_reader :details

        def initialize(msg, details = {})
          super(msg)
          @details = details
        end
      end

      module_function

      # Task files read stdin themselves (they need _installdir to load this
      # file), then hand the parameters over.
      def run(params)
        settings = (params['_target'] || {}).slice(*TARGET_KEYS)
        client = Config.client(settings)
        result = yield(params, client)
        puts JSON.generate(result)
      rescue ApiError, Error, ArgumentError, KeyError => e
        details = e.respond_to?(:details) ? e.details : {}
        puts JSON.generate('_error' => { 'msg' => e.message, 'kind' => 'k8s_core/task-error', 'details' => details })
        exit 1
      ensure
        client&.close
      end

      # "deployment/web" or "Deployment/web" => [apiVersion, Kind, name]
      WORKLOADS = {
        'deployment' => ['apps/v1', 'Deployment'],
        'statefulset' => ['apps/v1', 'StatefulSet'],
        'daemonset' => ['apps/v1', 'DaemonSet'],
      }.freeze

      def workload(ref)
        kind, name = ref.to_s.split('/', 2)
        av, k = WORKLOADS[kind.to_s.downcase]
        raise ArgumentError, "workload must be deployment/NAME, statefulset/NAME or daemonset/NAME, got #{ref.inspect}" unless av && name

        [av, k, name]
      end

      def merge_patch(client, path, patch)
        client.request(:patch, path, body: patch, content_type: 'application/merge-patch+json',
                                     query: { 'fieldManager' => FIELD_MANAGER })
      end

      def wait_ready(client, api_version, kind, namespace, name, timeout)
        deadline = Time.now + timeout
        loop do
          obj = client.get_object(api_version, kind, namespace, name)
          raise Error, "#{kind} #{namespace}/#{name} not found" unless obj

          ready, reason = Object.ready(obj)
          return reason if ready
          raise Error, "#{kind} #{namespace}/#{name} not ready after #{timeout}s: #{reason}" if Time.now > deadline

          sleep 2
        end
      end
    end
  end
end
