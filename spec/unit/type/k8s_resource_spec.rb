# frozen_string_literal: true

require 'spec_helper'

describe Puppet::Type.type(:k8s_resource) do
  it 'parses namespaced titles' do
    r = described_class.new(title: 'Deployment/web/frontend', api_version: 'apps/v1')
    expect([r[:kind], r[:namespace], r[:resource_name]]).to eq(%w[Deployment web frontend])
  end

  it 'parses cluster-scoped titles' do
    r = described_class.new(title: 'Namespace/web', api_version: 'v1')
    expect([r[:kind], r[:namespace], r[:resource_name]]).to eq(['Namespace', nil, 'web'])
  end

  it 'accepts the kubectl_apply parameter shape and canonicalizes the name' do
    r = described_class.new(title: 'my frontend', api_version: 'apps/v1', kind: 'Deployment', namespace: 'web', resource_name: 'frontend')
    expect(r[:name]).to eq('Deployment/web/frontend')
  end

  it 'requires api_version' do
    expect { described_class.new(title: 'Namespace/web') }.to raise_error(Puppet::ResourceError, %r{api_version})
  end

  it 'rejects titles it cannot parse' do
    expect { described_class.new(title: 'web', api_version: 'v1') }.to raise_error(Puppet::ResourceError, %r{Kind/name})
  end

  it 'rejects apiVersion in content' do
    expect { described_class.new(title: 'Namespace/web', api_version: 'v1', content: { 'apiVersion' => 'v1' }) }.to raise_error(Puppet::ResourceError, %r{apiVersion})
  end

  it 'rejects invalid managed_by values' do
    expect { described_class.new(title: 'Namespace/web', api_version: 'v1', managed_by: 'not a label') }.to raise_error(Puppet::ResourceError, %r{label value})
  end

  it 'marks Secret content sensitive' do
    r = described_class.new(title: 'Secret/web/creds', api_version: 'v1', content: { 'type' => 'Opaque' })
    expect(r.parameters[:content].sensitive).to be true
  end

  describe 'autorequires' do
    let(:catalog) { Puppet::Resource::Catalog.new }
    let(:ns) { described_class.new(title: 'Namespace/web', api_version: 'v1') }
    let(:crd) do
      described_class.new(title: 'CustomResourceDefinition/widgets.example.com', api_version: 'apiextensions.k8s.io/v1',
                          content: { 'spec' => { 'group' => 'example.com', 'names' => { 'kind' => 'Widget' } } })
    end
    let(:widget) { described_class.new(title: 'Widget/web/one', api_version: 'example.com/v1') }

    before { [ns, crd, widget].each { |r| catalog.add_resource(r) } }

    it 'requires its Namespace and its CRD' do
      reqs = widget.autorequire.map { |e| e.source.ref }
      expect(reqs).to contain_exactly('K8s_resource[Namespace/web]', 'K8s_resource[CustomResourceDefinition/widgets.example.com]')
    end
  end

  it 'refuses the same object under two titles' do
    catalog = Puppet::Resource::Catalog.new
    catalog.add_resource(described_class.new(title: 'Namespace/web', api_version: 'v1'))
    dup = described_class.new(title: 'other title', api_version: 'v1', kind: 'Namespace', resource_name: 'web')
    expect { catalog.add_resource(dup) }.to raise_error(ArgumentError, %r{Cannot alias})
  end
end
