# frozen_string_literal: true

require 'spec_helper'

describe Puppet::Type.type(:k8s_prune).provider(:api) do
  let(:fake) { FakeK8sClient.new }
  let(:catalog) { Puppet::Resource::Catalog.new }
  let(:prune) { Puppet::Type.type(:k8s_prune).new(title: 'scope', catalog: catalog) }
  let(:provider) { prune.provider }

  def cm(name, labels = { 'openvox.voxpupuli.org/managed-by' => 'scope' }, annotations = {})
    { 'apiVersion' => 'v1', 'kind' => 'ConfigMap',
      'metadata' => { 'name' => name, 'namespace' => 'app', 'labels' => labels, 'annotations' => annotations }, }
  end

  def entry(kind, ns, name, api = 'v1')
    { 'apiVersion' => api, 'kind' => kind, 'namespace' => ns, 'name' => name }.compact
  end

  def inventory(*entries)
    fake.put('apiVersion' => 'v1', 'kind' => 'ConfigMap',
             'metadata' => { 'name' => 'inventory-scope', 'namespace' => 'openvox-system' },
             'data' => { 'inventory.json' => JSON.generate(entries) })
  end

  def declare(title)
    catalog.add_resource(Puppet::Type.type(:k8s_resource).new(title: title, api_version: 'v1', managed_by: 'scope'))
  end

  before do
    allow(PuppetX::K8sCore).to receive(:client).and_return(fake)
    catalog.add_resource(prune)
  end

  it 'deletes objects that left the catalog' do
    declare('ConfigMap/app/keep')
    %w[keep drop].each { |n| fake.put(cm(n)) }
    inventory(entry('ConfigMap', 'app', 'keep'), entry('ConfigMap', 'app', 'drop'))
    expect(provider.inventory).to eq(:stale)
    provider.inventory = :current
    expect(fake.deletes).to eq([%w[v1 ConfigMap app drop]])
  end

  it 'releases objects someone else adopted' do
    fake.put(cm('adopted', 'openvox.voxpupuli.org/managed-by' => 'other'))
    inventory(entry('ConfigMap', 'app', 'adopted'))
    expect(provider.plan[:delete]).to be_empty
    expect(provider.plan[:notes].first).to match(%r{now managed by "other"})
  end

  it 'honors the prune: disabled annotation' do
    fake.put(cm('pinned', { 'openvox.voxpupuli.org/managed-by' => 'scope' }, 'openvox.voxpupuli.org/prune' => 'disabled'))
    inventory(entry('ConfigMap', 'app', 'pinned'))
    expect(provider.plan[:delete]).to be_empty
  end

  it 'never prunes protected kinds and keeps them in the inventory' do
    fake.put('apiVersion' => 'v1', 'kind' => 'Namespace',
             'metadata' => { 'name' => 'app', 'labels' => { 'openvox.voxpupuli.org/managed-by' => 'scope' } })
    inventory(entry('Namespace', nil, 'app'))
    expect(provider.plan[:delete]).to be_empty
    expect(provider.plan[:record].map { |e| e['name'] }).to eq(['app'])
  end

  it 'refuses a mass prune' do
    names = (1..10).map { |i| "cm#{i}" }
    names.each { |n| fake.put(cm(n)) }
    inventory(*names.map { |n| entry('ConfigMap', 'app', n) })
    declare('ConfigMap/app/cm1')
    expect { provider.inventory = :current }.to raise_error(PuppetX::K8sCore::Error, %r{refusing to prune 9 of 10 objects \(limit 2\)})
    expect(fake.deletes).to be_empty
  end

  it 'keeps candidates and deletes nothing in dryrun' do
    prune[:prune] = :dryrun
    fake.put(cm('drop'))
    inventory(entry('ConfigMap', 'app', 'drop'))
    expect(provider.plan[:delete]).to be_empty
    expect(provider.plan[:would_delete].map { |e| e['name'] }).to eq(['drop'])
    expect(provider.plan[:record].map { |e| e['name'] }).to eq(['drop'])
  end

  it 'deletes custom resources before built-in kinds' do
    order = [entry('ConfigMap', 'app', 'b'), entry('Widget', 'app', 'a', 'example.com/v1')].sort_by { |e| provider.rank(e) }
    expect(order.map { |e| e['kind'] }).to eq(%w[Widget ConfigMap])
  end
end
