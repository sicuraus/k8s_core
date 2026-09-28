# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'puppet_x/k8s_core'

describe PuppetX::K8sCore::Config do
  let(:dir) { Dir.mktmpdir }
  let(:kubeconfig) { File.join(dir, 'config') }

  after { FileUtils.rm_rf(dir) }

  before do
    File.write(kubeconfig, <<~YAML)
      apiVersion: v1
      kind: Config
      current-context: one
      clusters:
        - name: c1
          cluster: { server: 'https://one:6443', certificate-authority-data: #{Base64.strict_encode64('CA')} }
        - name: c2
          cluster: { server: 'https://two:6443', insecure-skip-tls-verify: true }
      users:
        - name: u1
          user: { token: secret }
        - name: u2
          user: { client-certificate: cert.pem, client-key: key.pem }
      contexts:
        - name: one
          context: { cluster: c1, user: u1 }
        - name: two
          context: { cluster: c2, user: u2 }
    YAML
    File.write(File.join(dir, 'cert.pem'), 'CERT')
    File.write(File.join(dir, 'key.pem'), 'KEY')
  end

  it 'uses the current context' do
    opts = described_class.resolve('kubeconfig' => kubeconfig)
    expect(opts).to include(server: 'https://one:6443', token: 'secret', ca_data: 'CA')
  end

  it 'selects a named context and reads files relative to the kubeconfig' do
    opts = described_class.resolve('kubeconfig' => kubeconfig, 'context' => 'two')
    expect(opts).to include(server: 'https://two:6443', insecure: true, client_cert_data: 'CERT', client_key_data: 'KEY')
  end

  it 'fails clearly on an unknown context' do
    expect { described_class.resolve('kubeconfig' => kubeconfig, 'context' => 'nope') }.to raise_error(PuppetX::K8sCore::Error, %r{nope})
  end

  it 'prefers explicit server settings' do
    opts = described_class.resolve('server' => 'https://x', 'token' => 't', 'kubeconfig' => kubeconfig)
    expect(opts).to include(server: 'https://x', token: 't')
  end

  it 'uses the in-cluster ServiceAccount when present and nothing is configured' do
    allow(described_class).to receive(:in_cluster?).and_return(true)
    ENV['KUBERNETES_SERVICE_HOST'] = '10.96.0.1'
    expect(described_class.resolve({})).to include(server: 'https://10.96.0.1:443', token_file: %r{serviceaccount/token})
  ensure
    ENV.delete('KUBERNETES_SERVICE_HOST')
  end
end
