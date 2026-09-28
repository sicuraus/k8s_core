# frozen_string_literal: true

require 'voxpupuli/test/spec_helper'

Dir[File.join(__dir__, 'support', '*.rb')].sort.each { |f| require f }

RSpec.configure do |c|
  c.after { PuppetX::K8sCore.reset! if defined?(PuppetX::K8sCore) }
end
