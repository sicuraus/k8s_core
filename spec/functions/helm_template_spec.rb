# frozen_string_literal: true

require 'spec_helper'

describe 'k8s_core::helm_template' do
  it { is_expected.to run.with_params('https://charts.example.com/x').and_raise_error(Puppet::ParseError, %r{not a local chart}) }
end
