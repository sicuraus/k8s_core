# frozen_string_literal: true

require 'puppet/resource_api'

Puppet::ResourceApi.register_transport(
  name: 'k8s',
  desc: <<~DESC,
    A Kubernetes API server. Supply a `kubeconfig` (and optionally a
    `context`), or an explicit `server` with a `token` or `token_file`.
    With no settings, the in-cluster ServiceAccount is used when present.
  DESC
  features: [],
  connection_info: {
    kubeconfig: {
      type: 'Optional[String]',
      desc: 'Path to a kubeconfig file.',
    },
    context: {
      type: 'Optional[String]',
      desc: 'The kubeconfig context to use; defaults to its current-context.',
    },
    server: {
      type: 'Optional[String]',
      desc: 'API server URL, e.g. https://api.example.com:6443. Overrides kubeconfig.',
    },
    token: {
      type: 'Optional[String]',
      desc: 'Bearer token for `server`.',
      sensitive: true,
    },
    token_file: {
      type: 'Optional[String]',
      desc: 'File holding the bearer token for `server`; re-read when it changes.',
    },
    ca_file: {
      type: 'Optional[String]',
      desc: 'CA bundle used to verify `server`.',
    },
    insecure_skip_tls_verify: {
      type: 'Optional[Boolean]',
      desc: 'Skip TLS verification of `server`. For test clusters only.',
    },
    timeout: {
      type: 'Optional[Integer[1]]',
      desc: 'Read timeout in seconds for API requests.',
    },
  },
)
