# frozen_string_literal: true

require 'spec_helper'
require 'puppet_x/k8s_core'

describe PuppetX::K8sCore::Object do
  describe '.parse_title' do
    it { expect(described_class.parse_title('Namespace/web')).to eq(['Namespace', nil, 'web']) }
    it { expect(described_class.parse_title('Deployment/web/frontend')).to eq(%w[Deployment web frontend]) }
    it { expect(described_class.parse_title('just-a-name')).to eq([nil, nil, nil]) }
  end

  describe '.normalize' do
    it 'drops status and server-maintained metadata' do
      obj = { 'metadata' => { 'name' => 'x', 'resourceVersion' => '1', 'managedFields' => [], 'uid' => 'u' },
              'status' => { 'phase' => 'Active' }, 'spec' => { 'a' => 1 }, }
      expect(described_class.normalize(obj)).to eq('metadata' => { 'name' => 'x' }, 'spec' => { 'a' => 1 })
    end
  end

  describe '.diff' do
    it 'reports changed, added and removed leaves with paths' do
      old = { 'spec' => { 'replicas' => 2, 'gone' => 'x', 'list' => [{ 'a' => 1 }] } }
      new = { 'spec' => { 'replicas' => 3, 'added' => true, 'list' => [{ 'a' => 2 }] } }
      expect(described_class.diff(old, new)).to contain_exactly(
        ['spec.replicas', 2, 3], ['spec.gone', 'x', nil], ['spec.added', nil, true], ['spec.list[0].a', 1, 2]
      )
    end
  end

  describe '.summarize_changes' do
    it 'redacts Secret data' do
      msg = described_class.summarize_changes('Secret', [['data.password', 'b2xk', 'bmV3']])
      expect(msg).to eq('data.password changed [redacted]')
    end

    it 'shows other values' do
      expect(described_class.summarize_changes('ConfigMap', [['data.a', '1', '2']])).to eq('data.a: "1" -> "2"')
    end
  end

  describe '.subset?' do
    it { expect(described_class.subset?({ 'a' => { 'b' => 1 } }, { 'a' => { 'b' => 1, 'c' => 2 } })).to be true }
    it { expect(described_class.subset?({ 'a' => { 'b' => 2 } }, { 'a' => { 'b' => 1 } })).to be false }
  end

  describe '.ready' do
    let(:deployment) do
      { 'kind' => 'Deployment', 'metadata' => { 'generation' => 2 }, 'spec' => { 'replicas' => 2 },
        'status' => { 'observedGeneration' => 2, 'replicas' => 2, 'updatedReplicas' => 2, 'availableReplicas' => 2 }, }
    end

    it 'accepts a rolled-out Deployment' do
      expect(described_class.ready(deployment).first).to be true
    end

    it 'waits for the controller to observe a new generation' do
      deployment['metadata']['generation'] = 3
      expect(described_class.ready(deployment)).to eq([false, 'rollout not observed yet'])
    end

    it 'waits for old replicas to go away' do
      deployment['status']['replicas'] = 3
      expect(described_class.ready(deployment).first).to be false
    end

    it 'fails a stalled rollout' do
      deployment['status']['conditions'] = [{ 'type' => 'Progressing', 'reason' => 'ProgressDeadlineExceeded', 'message' => 'x' }]
      expect { described_class.ready(deployment) }.to raise_error(PuppetX::K8sCore::Error, %r{stalled})
    end

    it 'fails a failed Job' do
      job = { 'kind' => 'Job', 'status' => { 'conditions' => [{ 'type' => 'Failed', 'status' => 'True', 'message' => 'boom' }] } }
      expect { described_class.ready(job) }.to raise_error(PuppetX::K8sCore::Error, %r{boom})
    end

    it 'treats objects without status as ready' do
      expect(described_class.ready('kind' => 'ConfigMap').first).to be true
    end

    it 'uses the Ready condition of other kinds' do
      obj = { 'kind' => 'Certificate', 'status' => { 'conditions' => [{ 'type' => 'Ready', 'status' => 'False', 'message' => 'pending' }] } }
      expect(described_class.ready(obj)).to eq([false, 'pending'])
    end
  end

  describe '.jsonpath' do
    let(:obj) do
      { 'status' => { 'phase' => 'Running', 'conditions' => [{ 'type' => 'Ready', 'status' => 'True' }] },
        'subjects' => [{ 'name' => 'a' }, { 'name' => 'b' }], }
    end

    it { expect(described_class.jsonpath(obj, '{.status.phase}')).to eq(['Running']) }
    it { expect(described_class.jsonpath(obj, '{.status.conditions[?(@.type=="Ready")].status}')).to eq(['True']) }
    it { expect(described_class.jsonpath(obj, '{.subjects[*].name}')).to eq(%w[a b]) }
    it { expect(described_class.jsonpath(obj, '{.subjects[1].name}')).to eq(['b']) }
    it { expect(described_class.jsonpath(obj, '{.missing.path}')).to eq([]) }
  end
end
