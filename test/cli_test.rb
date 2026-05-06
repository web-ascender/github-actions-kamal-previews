# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class CLITest < Minitest::Test
  include TestHelpers

  CLI_BIN = File.expand_path("../bin/kamal-previews", __dir__)

  def test_version
    out, _err, status = Open3.capture3(CLI_BIN, "version")
    assert status.success?
    assert_equal KamalPreviews::VERSION, out.strip
  end

  def test_help_when_no_args
    _out, _err, status = Open3.capture3(CLI_BIN)
    assert status.success?, "expected help to exit 0"
  end

  def test_unknown_command_exits_nonzero
    _out, _err, status = Open3.capture3(CLI_BIN, "frobnicate")
    refute status.success?
  end

  def test_slugify_subcommand
    out, _err, status = Open3.capture3(CLI_BIN, "slugify", "--branch", "feature/my-feature")
    assert status.success?, "slugify should succeed"
    parsed = JSON.parse(out)
    assert_equal "my-feature", parsed["slug"]
    assert_equal "my_feature", parsed["db_slug"]
  end

  def test_slugify_requires_branch
    _out, _err, status = Open3.capture3(CLI_BIN, "slugify")
    refute status.success?
  end

  def test_generate_subcommand_writes_outputs
    in_tmpdir do
      write_base_deploy
      write_base_secrets

      out, _err, status = Open3.capture3(
        CLI_BIN, "generate",
        "--branch", "feature/awesome",
        "--base-deploy-file", "config/deploy.staging.yml",
        "--base-secrets-file", ".kamal/secrets.staging",
        "--domain-suffix", "preview.example.com",
        "--database-name-pattern", "myapp_{db_slug}",
        "--env-override", "ROLLBAR_ENV=preview-awesome",
        "--env-override", "EXTRA=foo",
        "--env-secret", "EXTRA_SECRET",
        "--image-tag", "abc123",
        "--deploy-timeout", "900"
      )

      assert status.success?, "generate should succeed: #{_err}"
      parsed = JSON.parse(out)
      assert_equal "awesome", parsed["slug"]
      assert_equal "config/deploy.awesome.yml", parsed["deploy_file"]
      assert_equal "myapp_awesome", parsed["database_name"]

      yaml = YAML.safe_load_file("config/deploy.awesome.yml")
      assert_equal "myapp-awesome", yaml["service"]
      assert_equal "acme/myapp:abc123", yaml["image"]
      assert_equal 900, yaml["deploy_timeout"]
      assert_equal "preview-awesome", yaml["env"]["clear"]["ROLLBAR_ENV"]
      assert_equal "foo", yaml["env"]["clear"]["EXTRA"]
      assert_includes yaml["env"]["secret"], "EXTRA_SECRET"
    end
  end

  def test_generate_writes_github_output_when_env_set
    in_tmpdir do |dir|
      write_base_deploy
      output_path = File.join(dir, "gh_output")
      File.write(output_path, "")

      env = {"GITHUB_OUTPUT" => output_path}
      _out, _err, status = Open3.capture3(env,
        CLI_BIN, "generate",
        "--branch", "feature/awesome",
        "--base-deploy-file", "config/deploy.staging.yml",
        "--domain-suffix", "preview.example.com")

      assert status.success?
      gh = File.read(output_path)
      assert_match(/^slug=awesome$/, gh)
      assert_match(/^db_slug=awesome$/, gh)
      assert_match(/^proxy_host=awesome\.preview\.example\.com$/, gh)
      assert_match(/^destination=awesome$/, gh)
    end
  end
end
