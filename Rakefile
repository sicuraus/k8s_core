# frozen_string_literal: true

require 'voxpupuli/test/rake'
require 'puppet-strings/tasks' if Gem.loaded_specs.key?('puppet-strings')

desc 'Run the KinD acceptance suite (needs docker or podman, kind and kubectl)'
task :acceptance do
  sh 'test/acceptance/run.sh'
end
