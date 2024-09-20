# frozen_string_literal: true

require_relative "lib/trx_ext/version"

Gem::Specification.new do |spec|
  spec.name          = "trx_ext"
  spec.version       = TrxExt::VERSION
  spec.authors       = ["Ivan Dzyzenko"]
  spec.email         = ["ivan.dzyzenko@gmail.com"]

  spec.summary       = "ActiveRecord's transaction extension"
  spec.description   = "Allow you to retry deadlocks, serialization errors, non-unique errors."
  spec.homepage      = "https://github.com/intale/trx_ext"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/intale/trx_ext/tree/v#{spec.version}"
  spec.metadata["changelog_uri"] = "https://github.com/intale/trx_ext/blob/v#{spec.version}/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency 'activerecord', '>= 7.2', '< 8'
end
