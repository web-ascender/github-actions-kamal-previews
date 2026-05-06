# frozen_string_literal: true

require "fileutils"
require "yaml"

module KamalPreviews
  # Generates a per-PR Kamal destination file by reading a base deploy.yml,
  # applying overrides driven by the configured templates, and writing the
  # result to `config/deploy.<destination>.yml`. Optionally copies the matching
  # `.kamal/secrets.<base>` to `.kamal/secrets.<destination>`.
  #
  # Stdlib-only: no Bundler, no Rails, no third-party YAML library.
  class ConfigGenerator
    Result = Struct.new(
      :destination,
      :deploy_file,
      :secrets_file,
      :proxy_host,
      :service_name,
      :database_name,
      :env_label,
      keyword_init: true
    )

    class Error < KamalPreviews::Error; end

    DEFAULT_DOMAIN_LABEL = "{slug}"
    DEFAULT_SERVICE_PATTERN = "{base_service}-{slug}"
    DEFAULT_DESTINATION_PATTERN = "{slug}"
    DEFAULT_ENV_LABEL = "preview"

    # @param namer_result [Namer::Result]
    # @param base_deploy_file [String] path to base Kamal deploy file (e.g. config/deploy.staging.yml)
    # @param base_secrets_file [String, nil] path to base Kamal secrets file (optional)
    # @param domain_suffix [String] e.g. "preview.example.com" — final host = "<slug>.<domain_suffix>"
    # @param domain_label_pattern [String] pattern that becomes the leftmost DNS label. Default "{slug}".
    # @param service_pattern [String] template for the Kamal `service:` value. Tokens: {base_service}, {slug}, {db_slug}
    # @param destination_pattern [String] template for the Kamal destination (filename suffix). Same tokens.
    # @param database_name_pattern [String, nil] template for the primary DB name; written as env.clear.DATABASE_NAME. Tokens: {base_database}, {slug}, {db_slug}. nil = don't write DATABASE_NAME.
    # @param base_database [String, nil] used to expand {base_database} in the database pattern (typically the staging DB name)
    # @param image_tag [String, nil] override `image:` tag (no tag = leave as-is)
    # @param env_label [String] applied to `labels.environment` and to env.clear.FEATURE_BRANCH_LABEL
    # @param env_overrides [Hash{String=>String}] extra key/value pairs merged into env.clear
    # @param env_secret_overrides [Array<String>] extra entries appended to env.secret
    # @param deploy_timeout [Integer, nil] override `deploy_timeout`
    # @param builder_context [String, nil] override `builder.context` (e.g., "." to allow uncommitted code)
    # @param memory_limit [String, nil] passes `--memory <value>` to docker run for every server role (e.g. "256m", "1g"). Bounds preview RAM until kamal-proxy ships scale-to-zero.
    # @param cpu_limit [String, nil] passes `--cpus <value>` to docker run for every server role (e.g. "0.5", "1").
    def initialize(
      namer_result:,
      base_deploy_file:,
      base_secrets_file: nil,
      domain_suffix:,
      domain_label_pattern: DEFAULT_DOMAIN_LABEL,
      service_pattern: DEFAULT_SERVICE_PATTERN,
      destination_pattern: DEFAULT_DESTINATION_PATTERN,
      database_name_pattern: nil,
      base_database: nil,
      image_tag: nil,
      env_label: DEFAULT_ENV_LABEL,
      env_overrides: {},
      env_secret_overrides: [],
      deploy_timeout: nil,
      builder_context: nil,
      memory_limit: nil,
      cpu_limit: nil
    )
      @namer_result = namer_result
      @base_deploy_file = base_deploy_file
      @base_secrets_file = base_secrets_file
      @domain_suffix = String(domain_suffix).sub(/\A\./, "").sub(/\.\z/, "")
      @domain_label_pattern = domain_label_pattern
      @service_pattern = service_pattern
      @destination_pattern = destination_pattern
      @database_name_pattern = database_name_pattern
      @base_database = base_database
      @image_tag = image_tag
      @env_label = env_label
      @env_overrides = env_overrides || {}
      @env_secret_overrides = env_secret_overrides || []
      @deploy_timeout = deploy_timeout
      @builder_context = builder_context
      @memory_limit = memory_limit
      @cpu_limit = cpu_limit
    end

    def call
      validate!

      base_yaml = load_base_yaml
      base_service = base_yaml["service"] || raise(Error, "Base deploy file is missing top-level `service:` key")

      destination = expand(@destination_pattern, base_service: base_service)
      service_name = expand(@service_pattern, base_service: base_service)
      domain_label = expand(@domain_label_pattern, base_service: base_service)
      proxy_host = "#{domain_label}.#{@domain_suffix}"
      database_name = if @database_name_pattern
        expand(@database_name_pattern, base_service: base_service, base_database: @base_database)
      end

      mutated = mutate_yaml(base_yaml,
        service_name: service_name,
        proxy_host: proxy_host,
        database_name: database_name)

      deploy_file = "config/deploy.#{destination}.yml"
      FileUtils.mkdir_p(File.dirname(deploy_file))
      File.write(deploy_file, YAML.dump(mutated))

      secrets_file = copy_secrets(destination)

      Result.new(
        destination: destination,
        deploy_file: deploy_file,
        secrets_file: secrets_file,
        proxy_host: proxy_host,
        service_name: service_name,
        database_name: database_name,
        env_label: @env_label
      )
    end

    private

    def validate!
      unless File.exist?(@base_deploy_file)
        raise Error, "Base deploy file not found: #{@base_deploy_file}"
      end
      if @base_secrets_file && !File.exist?(@base_secrets_file)
        raise Error, "Base secrets file not found: #{@base_secrets_file}"
      end
      if @database_name_pattern&.include?("{base_database}") && (@base_database.nil? || @base_database.empty?)
        raise Error, "database_name_pattern uses {base_database} but no base_database was provided"
      end
      if @domain_suffix.empty?
        raise Error, "domain_suffix is required"
      end
    end

    def load_base_yaml
      raw = File.read(@base_deploy_file)
      begin
        # We deliberately allow aliases (Kamal configs often use them) but no
        # arbitrary classes and no symbolization.
        data = YAML.safe_load(raw, permitted_classes: [Date, Time], aliases: true)
      rescue Psych::SyntaxError => e
        raise Error, "Failed to parse #{@base_deploy_file}: #{e.message}"
      end
      raise Error, "#{@base_deploy_file} root must be a mapping" unless data.is_a?(Hash)

      data
    end

    def expand(template, base_service: nil, base_database: nil)
      template
        .gsub("{slug}", @namer_result.slug)
        .gsub("{db_slug}", @namer_result.db_slug)
        .gsub("{base_service}", base_service.to_s)
        .gsub("{base_database}", base_database.to_s)
    end

    def mutate_yaml(yaml, service_name:, proxy_host:, database_name:)
      out = deep_dup(yaml)

      out["service"] = service_name

      if @image_tag
        # Replace an existing :tag if present, otherwise append. The negative
        # `[^:/]` class avoids touching `registry:5000/repo` style ports.
        base_image = out["image"].to_s.sub(/:[^:\/]+\z/, "")
        out["image"] = "#{base_image}:#{@image_tag}"
      end

      out["proxy"] ||= {}
      out["proxy"]["host"] = proxy_host

      out["labels"] ||= {}
      out["labels"]["environment"] = @env_label

      out["env"] ||= {}
      out["env"]["clear"] ||= {}
      out["env"]["clear"]["FEATURE_BRANCH"] = "true"
      out["env"]["clear"]["FEATURE_BRANCH_LABEL"] = @env_label
      out["env"]["clear"]["FEATURE_BRANCH_SLUG"] = @namer_result.slug
      out["env"]["clear"]["FEATURE_BRANCH_DB_SLUG"] = @namer_result.db_slug
      out["env"]["clear"]["DATABASE_NAME"] = database_name if database_name
      @env_overrides.each { |k, v| out["env"]["clear"][k.to_s] = v.to_s }

      if @env_secret_overrides.any?
        out["env"]["secret"] ||= []
        out["env"]["secret"].concat(@env_secret_overrides)
        out["env"]["secret"].uniq!
      end

      out["deploy_timeout"] = @deploy_timeout if @deploy_timeout

      if @builder_context
        out["builder"] ||= {}
        out["builder"]["context"] = @builder_context
      end

      apply_resource_limits!(out) if @memory_limit || @cpu_limit

      out
    end

    # Per-role `options` map that Kamal renders into `docker run` flags.
    # Each role under `servers:` may be in shorthand-array form (just hosts)
    # or full-hash form (`hosts:`, `options:`, `cmd:`, …) — handle both.
    def apply_resource_limits!(yaml)
      return unless yaml["servers"].is_a?(Hash)

      yaml["servers"].each_key do |role|
        role_config = yaml["servers"][role]
        if role_config.is_a?(Array)
          yaml["servers"][role] = {"hosts" => role_config}
        end
        yaml["servers"][role]["options"] ||= {}
        yaml["servers"][role]["options"]["memory"] = @memory_limit if @memory_limit
        yaml["servers"][role]["options"]["cpus"] = @cpu_limit if @cpu_limit
      end
    end

    def copy_secrets(destination)
      return nil unless @base_secrets_file

      target = ".kamal/secrets.#{destination}"
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(@base_secrets_file, target)
      target
    end

    def deep_dup(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
      when Array then obj.map { |v| deep_dup(v) }
      else obj.dup rescue obj
      end
    end
  end
end
