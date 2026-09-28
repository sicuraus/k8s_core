# frozen_string_literal: true

require 'spec_helper'

describe 'k8s_core::title' do
  it { is_expected.to run.with_params('kind' => 'Namespace', 'metadata' => { 'name' => 'web' }).and_return('Namespace/web') }
  it { is_expected.to run.with_params({ 'kind' => 'ConfigMap', 'metadata' => { 'name' => 'c' } }, 'ns').and_return('ConfigMap/ns/c') }
end
