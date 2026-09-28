# frozen_string_literal: true

source ENV['GEM_SOURCE'] || 'https://rubygems.org'

group :test do
  gem 'voxpupuli-test', '~> 14.0', require: false
  gem 'puppet-strings', '~> 5.0', require: false
end

gem 'openvox', ENV.fetch('OPENVOX_GEM_VERSION', ['>= 8', '< 10']), require: false, groups: [:test]
