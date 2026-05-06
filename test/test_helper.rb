# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "kamal_previews"

module TestHelpers
  # Run a block inside a fresh tmpdir as the cwd; restores afterwards.
  def in_tmpdir
    Dir.mktmpdir("kamal-previews-test") do |dir|
      Dir.chdir(dir) do
        yield dir
      end
    end
  end

  def write_base_deploy(path = "config/deploy.staging.yml", overrides = {})
    FileUtils.mkdir_p(File.dirname(path))
    yaml = {
      "service" => "myapp",
      "image" => "acme/myapp",
      "servers" => {"web" => ["10.0.0.1"]},
      "registry" => {"server" => "ghcr.io", "username" => ["KAMAL_REGISTRY_USERNAME"], "password" => ["KAMAL_REGISTRY_PASSWORD"]},
      "proxy" => {"host" => "staging.example.com", "ssl" => true},
      "env" => {"clear" => {"RAILS_ENV" => "staging"}, "secret" => ["SECRET_KEY_BASE"]},
      "labels" => {"environment" => "staging"}
    }.merge(overrides)
    File.write(path, YAML.dump(yaml))
    path
  end

  def write_base_secrets(path = ".kamal/secrets.staging", body = "SECRETS=fetch from somewhere\n")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end
end
