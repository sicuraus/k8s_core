# frozen_string_literal: true

require 'spec_helper'

describe Puppet::Type.type(:k8s_resource).provider(:api) do
  let(:fake) { FakeK8sClient.new }
  let(:resource) do
    Puppet::Type.type(:k8s_resource).new(title: 'ConfigMap/web/settings', api_version: 'v1',
                                         content: { 'data' => { 'a' => '1' } })
  end
  let(:provider) { resource.provider }

  before { allow(PuppetX::K8sCore).to receive(:client).and_return(fake) }

  it 'is absent when the object does not exist' do
    expect(provider.exists?).to be false
  end

  it 'creates with server-side apply, labels and title annotation' do
    provider.create
    body = fake.applies.last
    expect(body).to include('apiVersion' => 'v1', 'kind' => 'ConfigMap', 'data' => { 'a' => '1' })
    expect(body['metadata']['labels']).to eq('openvox.voxpupuli.org/managed-by' => 'openvox')
    expect(body['metadata']['annotations']).to eq('openvox.voxpupuli.org/title' => 'ConfigMap/web/settings')
  end

  context 'with an existing object' do
    before do
      fake.put('apiVersion' => 'v1', 'kind' => 'ConfigMap', 'metadata' => {
                 'name' => 'settings', 'namespace' => 'web',
                 'labels' => { 'openvox.voxpupuli.org/managed-by' => 'openvox' },
                 'annotations' => { 'openvox.voxpupuli.org/title' => 'ConfigMap/web/settings' },
               }, 'data' => { 'a' => '1' })
    end

    it 'is in sync when a dry-run changes nothing' do
      expect(provider.content_insync?).to be true
    end

    it 'reports the changed fields' do
      resource[:content] = { 'data' => { 'a' => '2' } }
      expect(provider.content_insync?).to be false
      expect(provider.change_summary).to eq('ConfigMap web/settings: data.a: "1" -> "2"')
    end

    it 'takes back fields from imperative kubectl edits' do
      fake.conflict_on(%w[v1 ConfigMap web settings], 'kubectl-edit')
      resource[:content] = { 'data' => { 'a' => '2' } }
      expect(provider.content_insync?).to be false
      expect(provider.change_summary).to include('reverting edits by kubectl-edit')
    end

    it 'fails on conflicts with another declarative manager, naming it' do
      fake.conflict_on(%w[v1 ConfigMap web settings], 'helm')
      resource[:content] = { 'data' => { 'a' => '2' } }
      expect { provider.content_insync? }.to raise_error(PuppetX::K8sCore::Error, %r{owned by helm; not forcing})
    end

    it 'takes ownership with force_conflicts' do
      fake.conflict_on(%w[v1 ConfigMap web settings], 'helm')
      resource[:content] = { 'data' => { 'a' => '2' } }
      resource[:force_conflicts] = true
      expect(provider.content_insync?).to be false
    end
  end

  it 'base64-encodes sensitive_data into Secret data' do
    secret = Puppet::Type.type(:k8s_resource).new(title: 'Secret/web/creds', api_version: 'v1',
                                                  sensitive_data: { 'password' => 'hunter2' })
    secret.provider.create
    expect(fake.applies.last['data']).to eq('password' => Base64.strict_encode64('hunter2'))
  end
end
