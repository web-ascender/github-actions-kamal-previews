# frozen_string_literal: true

require "date" # for Date / DateTime in YAML permitted_classes
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
      :databases,
      :databases_full,
      :env_label,
      keyword_init: true
    )

    # One entry in the `databases:` list. Source is the existing template DB
    # being cloned; pattern resolves to the per-PR target DB name. There
    # are two delivery modes, picked automatically from the env-var suffix:
    #
    #   - `*_URL`  (e.g. DATABASE_URL): the action reads the original URL
    #     from base-secrets-file, swaps in the resolved target as the
    #     dbname path segment, and injects the rewritten URL via env.secret
    #     at deploy time. Container app code reads ENV_NAME and gets a
    #     fully-formed connection URL pointing at the per-PR clone — the
    #     user's database.yml / credentials / secrets file stay unchanged.
    #
    #   - any other name (e.g. DATABASE_NAME): the resolved target name is
    #     written to env.clear[ENV_NAME] and exported to $GITHUB_ENV so
    #     the consumer can build URLs themselves if they want.
    DatabaseSpec = Struct.new(:env_name, :source, :pattern, keyword_init: true) do
      def resolve(slug:, db_slug:)
        pattern
          .gsub("{slug}", slug)
          .gsub("{db_slug}", db_slug)
          .gsub("{base_database}", source.to_s)
      end

      # URL-mode if the env name ends in `_URL` (case-insensitive). Anything
      # else is treated as a database-name entry.
      def url_mode?
        env_name.to_s =~ /_URL\z/i ? true : false
      end
    end

    class Error < KamalPreviews::Error; end

    DEFAULT_DOMAIN_LABEL = "{slug}"
    DEFAULT_SERVICE_PATTERN = "{base_service}-{slug}"
    DEFAULT_DESTINATION_PATTERN = "{slug}"
    DEFAULT_ENV_LABEL = "preview"
    PRIMARY_DATABASE_ENV = "DATABASE_NAME"

    # Parses one entry of the multi-line `databases:` input. Format:
    #   ENV_NAME=source_db:target_pattern
    # Whitespace around tokens is trimmed; blank lines and `#`-comments are
    # skipped by the caller.
    def self.parse_database_entry(entry)
      raw = entry.to_s.strip
      env_name, rest = raw.split("=", 2)
      raise Error, "database entry missing `=` (got #{entry.inspect})" if env_name.nil? || rest.nil?
      source, pattern = rest.split(":", 2)
      raise Error, "database entry missing `:` separator between source and pattern (got #{entry.inspect})" if source.nil? || pattern.nil?
      env_name = env_name.strip
      source = source.strip
      pattern = pattern.strip
      raise Error, "database entry has empty env_name (got #{entry.inspect})" if env_name.empty?
      raise Error, "database entry has empty source (got #{entry.inspect})" if source.empty?
      raise Error, "database entry has empty pattern (got #{entry.inspect})" if pattern.empty?
      DatabaseSpec.new(env_name: env_name, source: source, pattern: pattern)
    end

    # Parses a multi-line spec into an array of DatabaseSpec. Skips blank
    # lines and `#`-prefixed comments.
    def self.parse_databases(input)
      return [] if input.nil?
      lines = input.is_a?(Array) ? input : input.to_s.split(/\r?\n/)
      lines.filter_map do |line|
        stripped = line.to_s.strip
        next if stripped.empty?
        next if stripped.start_with?("#")
        parse_database_entry(stripped)
      end
    end

    # @param namer_result [Namer::Result]
    # @param base_deploy_file [String] path to base Kamal deploy file (e.g. config/deploy.staging.yml)
    # @param base_secrets_file [String, nil] path to base Kamal secrets file (optional)
    # @param domain_suffix [String] e.g. "preview.example.com" — final host = "<slug>.<domain_suffix>"
    # @param domain_label_pattern [String] pattern that becomes the leftmost DNS label. Default "{slug}".
    # @param service_pattern [String] template for the Kamal `service:` value. Tokens: {base_service}, {slug}, {db_slug}
    # @param destination_pattern [String] template for the Kamal destination (filename suffix). Same tokens.
    # @param databases [Array<DatabaseSpec>, Array<String>, String] multi-line spec or array of entries; each entry "ENV_NAME=source:pattern". Each entry produces a clone+drop and an env.clear[ENV_NAME] = resolved-target write.
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
      databases: [],
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
      @databases = normalize_databases(databases)
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

      databases_resolved = {}
      databases_full = []
      databases_url_targets = {}
      databases_name_targets = {}
      @databases.each do |spec|
        target = spec.resolve(slug: @namer_result.slug, db_slug: @namer_result.db_slug)
        databases_resolved[spec.env_name] = target
        databases_full << "#{spec.env_name}=#{spec.source}:#{target}"
        if spec.url_mode?
          databases_url_targets[spec.env_name] = target
        else
          databases_name_targets[spec.env_name] = target
        end
      end

      mutated = mutate_yaml(base_yaml,
        service_name: service_name,
        proxy_host: proxy_host,
        databases_name_targets: databases_name_targets,
        databases_url_envs: databases_url_targets.keys)

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
        database_name: databases_resolved[PRIMARY_DATABASE_ENV],
        databases: databases_resolved,
        databases_full: databases_full,
        env_label: @env_label
      )
    end

    private

    def normalize_databases(databases)
      case databases
      when nil, "" then []
      when Array
        databases.map { |e| e.is_a?(DatabaseSpec) ? e : self.class.parse_database_entry(e) }
      else
        self.class.parse_databases(databases)
      end
    end

    def validate!
      unless File.exist?(@base_deploy_file)
        raise Error, "Base deploy file not found: #{@base_deploy_file}"
      end
      if @base_secrets_file && !File.exist?(@base_secrets_file)
        raise Error, "Base secrets file not found: #{@base_secrets_file}"
      end
      env_names = @databases.map(&:env_name)
      dupes = env_names.group_by(&:itself).select { |_, vs| vs.size > 1 }.keys
      raise Error, "duplicate database env names: #{dupes.join(", ")}" if dupes.any?
      if @domain_suffix.empty?
        raise Error, "domain_suffix is required"
      end
    end

    def load_base_yaml
      data = parse_yaml(@base_deploy_file)
      raise Error, "#{@base_deploy_file} root must be a mapping" unless data.is_a?(Hash)

      # Kamal's destination convention puts shared config in deploy.yml and
      # destination-specific overrides in deploy.<destination>.yml. `kamal -d
      # staging` merges both at deploy time. If our base file is a
      # destination override, top-level keys like `service:` and `image:`
      # may live in the sibling deploy.yml — read it and fill in the gaps
      # so we have everything needed to derive the per-PR config.
      sibling = File.join(File.dirname(@base_deploy_file), "deploy.yml")
      if sibling != @base_deploy_file && File.exist?(sibling)
        shared = parse_yaml(sibling)
        if shared.is_a?(Hash)
          # Destination values win where they're set; the shared file fills
          # in everything else.
          data = shared.merge(data) { |_key, _shared_v, dest_v| dest_v }
        end
      end

      data
    end

    def parse_yaml(path)
      raw = File.read(path)
      YAML.safe_load(raw, permitted_classes: [Date, Time], aliases: true)
    rescue Psych::SyntaxError => e
      raise Error, "Failed to parse #{path}: #{e.message}"
    end

    def expand(template, base_service: nil)
      template
        .gsub("{slug}", @namer_result.slug)
        .gsub("{db_slug}", @namer_result.db_slug)
        .gsub("{base_service}", base_service.to_s)
    end

    def mutate_yaml(yaml, service_name:, proxy_host:, databases_name_targets:, databases_url_envs:)
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
      # Name-mode entries land in env.clear (resolved name visible to the
      # container; consumer wires it into URLs however they want).
      databases_name_targets.each { |k, v| out["env"]["clear"][k] = v }
      @env_overrides.each { |k, v| out["env"]["clear"][k.to_s] = v.to_s }

      # URL-mode entries land in env.secret. The actual rewritten URL is
      # injected at deploy time by the action, via runtime env + an
      # appended override line in the per-PR `.kamal/secrets.<dest>` file.
      url_secrets = databases_url_envs + @env_secret_overrides
      if url_secrets.any?
        out["env"]["secret"] ||= []
        out["env"]["secret"].concat(url_secrets)
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
