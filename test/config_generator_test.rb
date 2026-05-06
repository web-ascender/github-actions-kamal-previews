# frozen_string_literal: true

require_relative "test_helper"

class ConfigGeneratorTest < Minitest::Test
  include TestHelpers

  def namer(branch = "feature/awesome-thing")
    KamalPreviews::Namer.call(branch)
  end

  def test_writes_per_pr_deploy_file
    in_tmpdir do
      write_base_deploy
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com"
      ).call

      assert_equal "awesome-thing", result.destination
      assert_equal "config/deploy.awesome-thing.yml", result.deploy_file
      assert File.exist?(result.deploy_file)

      yaml = YAML.safe_load_file(result.deploy_file)
      assert_equal "myapp-awesome-thing", yaml["service"]
      assert_equal "awesome-thing.preview.example.com", yaml["proxy"]["host"]
      assert_equal "preview", yaml["labels"]["environment"]
      assert_equal "true", yaml["env"]["clear"]["FEATURE_BRANCH"]
      assert_equal "preview", yaml["env"]["clear"]["FEATURE_BRANCH_LABEL"]
      assert_equal "awesome-thing", yaml["env"]["clear"]["FEATURE_BRANCH_SLUG"]
      assert_equal "awesome_thing", yaml["env"]["clear"]["FEATURE_BRANCH_DB_SLUG"]
    end
  end

  def test_image_tag_override_replaces_existing_tag
    in_tmpdir do
      write_base_deploy("config/deploy.staging.yml", "image" => "acme/myapp:staging")
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        image_tag: "abc123"
      ).call
      yaml = YAML.safe_load_file(result.deploy_file)
      assert_equal "acme/myapp:abc123", yaml["image"]
    end
  end

  def test_image_tag_override_appends_when_no_existing_tag
    in_tmpdir do
      write_base_deploy
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        image_tag: "abc123"
      ).call
      yaml = YAML.safe_load_file(result.deploy_file)
      assert_equal "acme/myapp:abc123", yaml["image"]
    end
  end

  def test_image_tag_preserves_registry_port
    in_tmpdir do
      write_base_deploy("config/deploy.staging.yml", "image" => "registry.example.com:5000/acme/myapp:staging")
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        image_tag: "abc123"
      ).call
      yaml = YAML.safe_load_file(result.deploy_file)
      assert_equal "registry.example.com:5000/acme/myapp:abc123", yaml["image"]
    end
  end

  def test_env_overrides_merged
    in_tmpdir do
      write_base_deploy
      KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        env_overrides: {"ROLLBAR_ENV" => "preview-awesome", "ANALYTICS_KEY" => "preview"}
      ).call

      yaml = YAML.safe_load_file("config/deploy.awesome-thing.yml")
      assert_equal "preview-awesome", yaml["env"]["clear"]["ROLLBAR_ENV"]
      assert_equal "preview", yaml["env"]["clear"]["ANALYTICS_KEY"]
      # base envs preserved
      assert_equal "staging", yaml["env"]["clear"]["RAILS_ENV"]
    end
  end

  def test_env_secret_overrides_appended_uniquely
    in_tmpdir do
      write_base_deploy
      KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        env_secret_overrides: ["SECRET_KEY_BASE", "EXTRA_SECRET"] # SECRET_KEY_BASE already in base
      ).call

      yaml = YAML.safe_load_file("config/deploy.awesome-thing.yml")
      assert_equal ["SECRET_KEY_BASE", "EXTRA_SECRET"], yaml["env"]["secret"]
    end
  end

  def test_secrets_file_copied_when_provided
    in_tmpdir do
      write_base_deploy
      write_base_secrets
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        base_secrets_file: ".kamal/secrets.staging",
        domain_suffix: "preview.example.com"
      ).call

      assert_equal ".kamal/secrets.awesome-thing", result.secrets_file
      assert File.exist?(result.secrets_file)
      assert_equal File.read(".kamal/secrets.staging"), File.read(result.secrets_file)
    end
  end

  def test_secrets_file_skipped_when_not_provided
    in_tmpdir do
      write_base_deploy
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com"
      ).call
      assert_nil result.secrets_file
    end
  end

  def test_destination_pattern_can_be_customized
    in_tmpdir do
      write_base_deploy
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        destination_pattern: "preview-{slug}"
      ).call
      assert_equal "preview-awesome-thing", result.destination
      assert_equal "config/deploy.preview-awesome-thing.yml", result.deploy_file
    end
  end

  def test_service_pattern_can_be_customized
    in_tmpdir do
      write_base_deploy
      KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        service_pattern: "preview-{slug}"
      ).call
      yaml = YAML.safe_load_file("config/deploy.awesome-thing.yml")
      assert_equal "preview-awesome-thing", yaml["service"]
    end
  end

  def test_domain_label_pattern_can_be_customized
    in_tmpdir do
      write_base_deploy
      KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "example.com",
        domain_label_pattern: "preview-{slug}"
      ).call
      yaml = YAML.safe_load_file("config/deploy.awesome-thing.yml")
      assert_equal "preview-awesome-thing.example.com", yaml["proxy"]["host"]
    end
  end

  def test_deploy_timeout_override
    in_tmpdir do
      write_base_deploy
      KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        deploy_timeout: 900
      ).call
      yaml = YAML.safe_load_file("config/deploy.awesome-thing.yml")
      assert_equal 900, yaml["deploy_timeout"]
    end
  end

  def test_builder_context_override
    in_tmpdir do
      write_base_deploy
      KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        builder_context: "."
      ).call
      yaml = YAML.safe_load_file("config/deploy.awesome-thing.yml")
      assert_equal ".", yaml["builder"]["context"]
    end
  end

  def test_memory_and_cpu_limits_applied_to_array_form_role
    in_tmpdir do
      write_base_deploy("config/deploy.staging.yml", "servers" => {"web" => ["10.0.0.1", "10.0.0.2"]})
      KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        memory_limit: "256m",
        cpu_limit: "0.5"
      ).call
      yaml = YAML.safe_load_file("config/deploy.awesome-thing.yml")
      assert_equal ["10.0.0.1", "10.0.0.2"], yaml["servers"]["web"]["hosts"]
      assert_equal "256m", yaml["servers"]["web"]["options"]["memory"]
      assert_equal "0.5", yaml["servers"]["web"]["options"]["cpus"]
    end
  end

  def test_memory_and_cpu_limits_applied_to_hash_form_role
    in_tmpdir do
      base = {
        "servers" => {
          "web" => {"hosts" => ["10.0.0.1"], "options" => {"label" => "preview"}},
          "job" => {"hosts" => ["10.0.0.2"], "cmd" => "bin/jobs"}
        }
      }
      write_base_deploy("config/deploy.staging.yml", base)
      KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        memory_limit: "512m"
      ).call
      yaml = YAML.safe_load_file("config/deploy.awesome-thing.yml")
      # web: existing options preserved, memory added
      assert_equal "preview", yaml["servers"]["web"]["options"]["label"]
      assert_equal "512m", yaml["servers"]["web"]["options"]["memory"]
      # job: hash form gets options added; cmd preserved
      assert_equal "bin/jobs", yaml["servers"]["job"]["cmd"]
      assert_equal "512m", yaml["servers"]["job"]["options"]["memory"]
    end
  end

  def test_no_resource_limits_does_not_touch_servers
    in_tmpdir do
      base = {"servers" => {"web" => ["10.0.0.1"]}}
      write_base_deploy("config/deploy.staging.yml", base)
      KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com"
      ).call
      yaml = YAML.safe_load_file("config/deploy.awesome-thing.yml")
      # Untouched array form
      assert_equal ["10.0.0.1"], yaml["servers"]["web"]
    end
  end

  def test_raises_on_missing_base_deploy_file
    in_tmpdir do
      err = assert_raises(KamalPreviews::ConfigGenerator::Error) do
        KamalPreviews::ConfigGenerator.new(
          namer_result: namer,
          base_deploy_file: "config/missing.yml",
          domain_suffix: "preview.example.com"
        ).call
      end
      assert_match(/Base deploy file not found/, err.message)
    end
  end

  def test_raises_on_missing_secrets_file
    in_tmpdir do
      write_base_deploy
      err = assert_raises(KamalPreviews::ConfigGenerator::Error) do
        KamalPreviews::ConfigGenerator.new(
          namer_result: namer,
          base_deploy_file: "config/deploy.staging.yml",
          base_secrets_file: ".kamal/secrets.missing",
          domain_suffix: "preview.example.com"
        ).call
      end
      assert_match(/Base secrets file not found/, err.message)
    end
  end

  def test_raises_on_missing_service_in_base
    in_tmpdir do
      FileUtils.mkdir_p("config")
      File.write("config/deploy.staging.yml", YAML.dump({"image" => "acme/myapp"}))
      err = assert_raises(KamalPreviews::ConfigGenerator::Error) do
        KamalPreviews::ConfigGenerator.new(
          namer_result: namer,
          base_deploy_file: "config/deploy.staging.yml",
          domain_suffix: "preview.example.com"
        ).call
      end
      assert_match(/service/, err.message)
    end
  end

  def test_databases_list_writes_one_env_clear_entry_per_database
    in_tmpdir do
      write_base_deploy
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        databases: <<~SPEC
          DATABASE_NAME=myapp_staging:myapp_{db_slug}
          QUEUE_DATABASE_NAME=myapp_staging_queue:myapp_queue_{db_slug}
          CACHE_DATABASE_NAME=myapp_staging_cache:myapp_cache_{db_slug}
        SPEC
      ).call

      assert_equal({
        "DATABASE_NAME" => "myapp_awesome_thing",
        "QUEUE_DATABASE_NAME" => "myapp_queue_awesome_thing",
        "CACHE_DATABASE_NAME" => "myapp_cache_awesome_thing"
      }, result.databases)
      # Back-compat: `database_name` shortcut points at DATABASE_NAME entry.
      assert_equal "myapp_awesome_thing", result.database_name

      yaml = YAML.safe_load_file(result.deploy_file)
      assert_equal "myapp_awesome_thing", yaml["env"]["clear"]["DATABASE_NAME"]
      assert_equal "myapp_queue_awesome_thing", yaml["env"]["clear"]["QUEUE_DATABASE_NAME"]
      assert_equal "myapp_cache_awesome_thing", yaml["env"]["clear"]["CACHE_DATABASE_NAME"]
    end
  end

  def test_databases_list_supports_base_database_token
    in_tmpdir do
      write_base_deploy
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        databases: "DATABASE_NAME=myapp_staging:{base_database}_{db_slug}"
      ).call

      assert_equal "myapp_staging_awesome_thing", result.database_name
    end
  end

  def test_databases_list_skips_blank_lines_and_comments
    in_tmpdir do
      write_base_deploy
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        databases: <<~SPEC

          # primary
          DATABASE_NAME=myapp_staging:myapp_{db_slug}

          # queue (commented out for now)
          # QUEUE_DATABASE_NAME=myapp_staging_queue:myapp_queue_{db_slug}
        SPEC
      ).call
      assert_equal({"DATABASE_NAME" => "myapp_awesome_thing"}, result.databases)
    end
  end

  def test_databases_list_rejects_duplicate_env_names
    in_tmpdir do
      write_base_deploy
      err = assert_raises(KamalPreviews::ConfigGenerator::Error) do
        KamalPreviews::ConfigGenerator.new(
          namer_result: namer,
          base_deploy_file: "config/deploy.staging.yml",
          domain_suffix: "preview.example.com",
          databases: "DATABASE_NAME=a:a_{db_slug}\nDATABASE_NAME=b:b_{db_slug}"
        ).call
      end
      assert_match(/duplicate database env names/, err.message)
    end
  end

  def test_databases_list_rejects_malformed_entries
    [
      "DATABASE_NAME",                # missing `=`
      "DATABASE_NAME=myapp_staging",  # missing `:`
      "=myapp_staging:pat",           # empty env_name
      "DATABASE_NAME=:pat",           # empty source
      "DATABASE_NAME=myapp_staging:"  # empty pattern
    ].each do |bad|
      err = assert_raises(KamalPreviews::ConfigGenerator::Error) do
        KamalPreviews::ConfigGenerator.parse_database_entry(bad)
      end
      assert_match(/database entry/, err.message, "expected error for #{bad.inspect}")
    end
  end

  def test_url_suffix_entries_skip_env_clear_and_land_in_env_secret
    in_tmpdir do
      write_base_deploy
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        databases: <<~SPEC
          DATABASE_URL=myapp_staging:myapp_{db_slug}
          QUEUE_DATABASE_URL=myapp_staging_queue:myapp_queue_{db_slug}
        SPEC
      ).call

      yaml = YAML.safe_load_file(result.deploy_file)

      # No env.clear entries for URL-mode databases — credentials don't
      # belong in plaintext YAML.
      refute yaml["env"]["clear"].key?("DATABASE_URL")
      refute yaml["env"]["clear"].key?("QUEUE_DATABASE_URL")

      # env.secret gets each URL-mode env name appended. Existing
      # SECRET_KEY_BASE from the base config is preserved.
      assert_includes yaml["env"]["secret"], "SECRET_KEY_BASE"
      assert_includes yaml["env"]["secret"], "DATABASE_URL"
      assert_includes yaml["env"]["secret"], "QUEUE_DATABASE_URL"

      # databases_full output still carries every entry (downstream uses it
      # to drive cloning + URL rewriting).
      assert_includes result.databases_full, "DATABASE_URL=myapp_staging:myapp_awesome_thing"
      assert_includes result.databases_full, "QUEUE_DATABASE_URL=myapp_staging_queue:myapp_queue_awesome_thing"
    end
  end

  def test_mixed_url_and_name_entries_route_correctly
    in_tmpdir do
      write_base_deploy
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com",
        databases: <<~SPEC
          DATABASE_URL=myapp_staging:myapp_{db_slug}
          ANALYTICS_DATABASE_NAME=analytics_staging:analytics_{db_slug}
        SPEC
      ).call

      yaml = YAML.safe_load_file(result.deploy_file)
      # URL → env.secret only
      refute yaml["env"]["clear"].key?("DATABASE_URL")
      assert_includes yaml["env"]["secret"], "DATABASE_URL"
      # Name → env.clear only
      assert_equal "analytics_awesome_thing", yaml["env"]["clear"]["ANALYTICS_DATABASE_NAME"]
      refute_includes yaml["env"]["secret"], "ANALYTICS_DATABASE_NAME"
    end
  end

  def test_url_mode_detection_on_database_spec
    spec_url = KamalPreviews::ConfigGenerator::DatabaseSpec.new(env_name: "DATABASE_URL", source: "x", pattern: "y")
    spec_url_lower = KamalPreviews::ConfigGenerator::DatabaseSpec.new(env_name: "Database_url", source: "x", pattern: "y")
    spec_name = KamalPreviews::ConfigGenerator::DatabaseSpec.new(env_name: "DATABASE_NAME", source: "x", pattern: "y")
    spec_url_prefix = KamalPreviews::ConfigGenerator::DatabaseSpec.new(env_name: "URL_PARSER", source: "x", pattern: "y")

    assert spec_url.url_mode?
    assert spec_url_lower.url_mode?
    refute spec_name.url_mode?
    refute spec_url_prefix.url_mode?, "URL must be a suffix, not anywhere in the name"
  end

  def test_loads_service_from_sibling_deploy_yml_when_destination_file_lacks_it
    in_tmpdir do
      FileUtils.mkdir_p("config")
      # The shared deploy.yml has top-level keys like `service:` and `image:`.
      File.write("config/deploy.yml", YAML.dump(
        "service" => "myapp",
        "image" => "acme/myapp",
        "registry" => {"server" => "ghcr.io"}
      ))
      # The destination file is a thin override — no service / image.
      File.write("config/deploy.staging.yml", YAML.dump(
        "servers" => {"web" => ["10.0.0.1"]},
        "proxy" => {"host" => "staging.example.com", "ssl" => true},
        "env" => {"clear" => {"RAILS_ENV" => "staging"}}
      ))
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com"
      ).call

      yaml = YAML.safe_load_file(result.deploy_file)
      assert_equal "myapp-awesome-thing", yaml["service"], "service: derived from sibling deploy.yml"
      # destination overrides preserved
      assert_equal "awesome-thing.preview.example.com", yaml["proxy"]["host"]
      assert_equal "staging", yaml["env"]["clear"]["RAILS_ENV"]
    end
  end

  def test_destination_file_values_override_sibling_deploy_yml
    in_tmpdir do
      FileUtils.mkdir_p("config")
      File.write("config/deploy.yml", YAML.dump(
        "service" => "myapp",
        "image" => "acme/myapp",
        "proxy" => {"host" => "default.example.com", "ssl" => false}
      ))
      File.write("config/deploy.staging.yml", YAML.dump(
        "proxy" => {"host" => "staging.example.com", "ssl" => true},
        "servers" => {"web" => ["10.0.0.1"]}
      ))
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com"
      ).call
      yaml = YAML.safe_load_file(result.deploy_file)
      # destination's proxy block wins — even though deploy.yml has its own
      assert_equal true, yaml["proxy"]["ssl"]
    end
  end

  def test_no_databases_writes_no_database_env_clear_entries
    in_tmpdir do
      write_base_deploy
      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com"
      ).call
      yaml = YAML.safe_load_file(result.deploy_file)
      refute yaml["env"]["clear"].key?("DATABASE_NAME")
      assert_equal({}, result.databases)
    end
  end

  def test_yaml_aliases_supported
    in_tmpdir do
      raw = <<~YAML
        defaults: &defaults
          environment: staging
        service: myapp
        image: acme/myapp
        servers:
          web:
            - 10.0.0.1
        proxy:
          host: staging.example.com
        env:
          clear:
            RAILS_ENV: staging
        labels:
          <<: *defaults
      YAML
      FileUtils.mkdir_p("config")
      File.write("config/deploy.staging.yml", raw)

      result = KamalPreviews::ConfigGenerator.new(
        namer_result: namer,
        base_deploy_file: "config/deploy.staging.yml",
        domain_suffix: "preview.example.com"
      ).call

      yaml = YAML.safe_load_file(result.deploy_file)
      assert_equal "preview", yaml["labels"]["environment"]
    end
  end
end
