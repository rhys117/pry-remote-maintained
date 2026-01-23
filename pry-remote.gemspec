# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name = "pry-remote"

  s.version = "0.2.0"

  s.summary     = "Connect to Pry remotely"
  s.description = "Connect to Pry remotely using DRb"
  s.homepage    = "http://github.com/Mon-Ouie/pry-remote"
  s.license     = "BSD-2-Clause"

  s.email   = "rhys117gmail.com"
  s.authors = ["Rhys Muray"]

  s.required_ruby_version = ">= 3.0"

  s.files = Dir["lib/**/*.rb"] + Dir["*.md"] + ["LICENSE"]

  s.require_paths = ["lib"]

  s.add_dependency "pry",  "~> 0.16"
  s.add_dependency "slop", "~> 4.0"
  s.add_dependency "drb",  ">= 2.0"

  s.executables = ["pry-remote"]
end
