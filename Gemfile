# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in trx_ext.gemspec
gemspec

gem "rake", "~> 13.0"

if ENV['AR_VERSION']
  # Given ENV['AR_VERSION'] to equal "6.0" will produce
  # ```ruby
  # gem 'activerecord', "~> 6.0", "< 6.1"
  # ```
  gem 'activerecord', "~> #{ENV['AR_VERSION']}", "< #{ENV['AR_VERSION'].next}"
end
