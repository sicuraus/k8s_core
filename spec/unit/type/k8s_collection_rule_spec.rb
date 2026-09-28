# frozen_string_literal: true

require 'spec_helper'

describe Puppet::Type.type(:k8s_collection_rule) do
  let(:fake) { FakeK8sClient.new }
  let(:catalog) { Puppet::Resource::Catalog.new }

  def ns(name)
    fake.put('apiVersion' => 'v1', 'kind' => 'Namespace', 'metadata' => { 'name' => name })
  end

  before do
    allow(PuppetX::K8sCore).to receive(:client).and_return(fake)
    %w[kube-system team-a team-b].each { |n| ns(n) }
  end

  def rule(**opts)
    r = described_class.new({ title: 'pss', api_version: 'v1', kind: 'Namespace', exclude: ['kube-*'],
                              action: 'patch', patch: { 'metadata' => { 'labels' => { 'x' => 'y' } } }, }.merge(opts).compact)
    catalog.add_resource(r)
    r
  end

  it 'generates one k8s_patch per object in scope' do
    kids = rule.eval_generate
    expect(kids.map(&:title)).to contain_exactly('pss: Namespace/team-a', 'pss: Namespace/team-b')
    expect(kids.map(&:class).uniq).to eq([Puppet::Type.type(:k8s_patch)])
  end

  it 'makes report rules noop' do
    expect(rule(action: 'report').eval_generate.map { |k| k[:noop] }.uniq).to eq([true])
  end

  it 'generates releases with release => true' do
    expect(rule(release: true).eval_generate.map { |k| k[:ensure] }.uniq).to eq([:absent])
  end

  it 'filters by match conditions' do
    r = rule(action: 'delete', patch: nil, match: [{ 'path' => '{.metadata.name}', 'op' => 'equals', 'value' => 'team-b' }])
    kids = r.eval_generate
    expect(kids.map(&:title)).to eq(['pss: Namespace/team-b'])
    expect(kids.first[:ensure]).to eq(:absent)
  end

  it 'never deletes objects the catalog declares' do
    catalog.add_resource(Puppet::Type.type(:k8s_resource).new(title: 'Namespace/team-b', api_version: 'v1'))
    r = rule(action: 'delete', patch: nil)
    expect(r.eval_generate.map(&:title)).to eq(['pss: Namespace/team-a'])
  end

  it 'requires patch for action patch' do
    expect { rule(patch: nil) }.to raise_error(Puppet::ResourceError, %r{requires patch})
  end
end
