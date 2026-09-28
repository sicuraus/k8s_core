# frozen_string_literal: true

require 'spec_helper'

describe 'k8s_core::yaml_documents' do
  it { is_expected.to run.with_params("---\na: 1\n---\n---\nb: 2\n").and_return([{ 'a' => 1 }, { 'b' => 2 }]) }
  it { is_expected.to run.with_params("kind: List\nitems:\n- {kind: A}\n- {kind: B}\n").and_return([{ 'kind' => 'A' }, { 'kind' => 'B' }]) }
  it { is_expected.to run.with_params("- not\n- a mapping\n").and_raise_error(Puppet::ParseError, %r{expected a mapping}) }
end
