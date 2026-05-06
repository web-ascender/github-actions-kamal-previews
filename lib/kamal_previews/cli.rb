# frozen_string_literal: true

require "json"
require "optparse"

module KamalPreviews
  # Command-line interface for the namer + config generator. Prints a short
  # JSON summary to stdout (machine-friendly) and ALSO writes key/value pairs
  # to $GITHUB_OUTPUT when running inside GitHub Actions.
  #
  # Two subcommands:
  #
  #   generate   read a base deploy.yml, write config/deploy.<dest>.yml
  #   slugify    print only the slugs for a branch (used in teardown where
  #              we don't need to write a new deploy file)
  class CLI
    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      command = argv.shift
      case command
      when "generate" then generate(argv)
      when "slugify" then slugify(argv)
      when "version", "--version", "-v" then puts KamalPreviews::VERSION
      when nil, "help", "--help", "-h" then print_help
      else
        warn "Unknown command: #{command.inspect}\n\n"
        print_help
        exit 1
      end
    end

    private

    def slugify(argv)
      opts = parse_slugify(argv)
      result = Namer.call(opts.fetch(:branch), prefix_strip: opts.fetch(:prefix_strip))
      emit({
        branch: result.branch,
        slug: result.slug,
        db_slug: result.db_slug
      })
    end

    def generate(argv)
      opts = parse_generate(argv)
      namer_result = Namer.call(opts.fetch(:branch), prefix_strip: opts.fetch(:prefix_strip))
      config_result = ConfigGenerator.new(
        namer_result: namer_result,
        base_deploy_file: opts.fetch(:base_deploy_file),
        base_secrets_file: opts[:base_secrets_file],
        domain_suffix: opts.fetch(:domain_suffix),
        domain_label_pattern: opts.fetch(:domain_label_pattern),
        service_pattern: opts.fetch(:service_pattern),
        destination_pattern: opts.fetch(:destination_pattern),
        database_name_pattern: opts[:database_name_pattern],
        base_database: opts[:base_database],
        image_tag: opts[:image_tag],
        env_label: opts.fetch(:env_label),
        env_overrides: opts.fetch(:env_overrides),
        env_secret_overrides: opts.fetch(:env_secret_overrides),
        deploy_timeout: opts[:deploy_timeout],
        builder_context: opts[:builder_context],
        memory_limit: opts[:memory_limit],
        cpu_limit: opts[:cpu_limit]
      ).call

      emit({
        branch: namer_result.branch,
        slug: namer_result.slug,
        db_slug: namer_result.db_slug,
        destination: config_result.destination,
        deploy_file: config_result.deploy_file,
        secrets_file: config_result.secrets_file,
        proxy_host: config_result.proxy_host,
        service_name: config_result.service_name,
        database_name: config_result.database_name,
        env_label: config_result.env_label
      })
    end

    def parse_slugify(argv)
      opts = {prefix_strip: Namer::DEFAULT_PREFIX_STRIP.dup}
      OptionParser.new do |o|
        o.banner = "Usage: kamal-previews slugify --branch <branch_name> [options]"
        o.on("--branch BRANCH", "Branch name to sanitize") { |v| opts[:branch] = v }
        o.on("--prefix-strip PREFIXES", "Comma-separated prefixes to strip (default: #{Namer::DEFAULT_PREFIX_STRIP.join(",")})") { |v| opts[:prefix_strip] = v.split(",").map(&:strip).reject(&:empty?) }
        o.on("-h", "--help") { puts o; exit }
      end.parse!(argv)
      die!("--branch is required") unless opts[:branch]
      opts
    end

    def parse_generate(argv)
      opts = {
        prefix_strip: Namer::DEFAULT_PREFIX_STRIP.dup,
        domain_label_pattern: ConfigGenerator::DEFAULT_DOMAIN_LABEL,
        service_pattern: ConfigGenerator::DEFAULT_SERVICE_PATTERN,
        destination_pattern: ConfigGenerator::DEFAULT_DESTINATION_PATTERN,
        env_label: ConfigGenerator::DEFAULT_ENV_LABEL,
        env_overrides: {},
        env_secret_overrides: []
      }

      OptionParser.new do |o|
        o.banner = "Usage: kamal-previews generate --branch <branch_name> --base-deploy-file <path> --domain-suffix <suffix> [options]"

        o.on("--branch BRANCH") { |v| opts[:branch] = v }
        o.on("--prefix-strip PREFIXES") { |v| opts[:prefix_strip] = v.split(",").map(&:strip).reject(&:empty?) }

        o.on("--base-deploy-file PATH") { |v| opts[:base_deploy_file] = v }
        o.on("--base-secrets-file PATH") { |v| opts[:base_secrets_file] = v }

        o.on("--domain-suffix SUFFIX", "e.g. preview.example.com") { |v| opts[:domain_suffix] = v }
        o.on("--domain-label-pattern PATTERN", "default: '{slug}'") { |v| opts[:domain_label_pattern] = v }
        o.on("--service-pattern PATTERN", "default: '{base_service}-{slug}'") { |v| opts[:service_pattern] = v }
        o.on("--destination-pattern PATTERN", "default: '{slug}'") { |v| opts[:destination_pattern] = v }

        o.on("--database-name-pattern PATTERN", "e.g. 'myapp_{db_slug}' (omit to skip writing DATABASE_NAME)") { |v| opts[:database_name_pattern] = v }
        o.on("--base-database NAME", "expands {base_database} in --database-name-pattern") { |v| opts[:base_database] = v }

        o.on("--image-tag TAG") { |v| opts[:image_tag] = v }
        o.on("--env-label LABEL", "default: 'preview'") { |v| opts[:env_label] = v }
        o.on("--env-override KEY=VALUE", "may be repeated") do |v|
          k, val = v.split("=", 2)
          die!("--env-override must be KEY=VALUE") unless k && val
          opts[:env_overrides][k] = val
        end
        o.on("--env-secret KEY", "append KEY to env.secret list (may be repeated)") do |v|
          opts[:env_secret_overrides] << v
        end
        o.on("--deploy-timeout SECONDS", Integer) { |v| opts[:deploy_timeout] = v }
        o.on("--builder-context PATH", "override builder.context") { |v| opts[:builder_context] = v }
        o.on("--memory-limit VALUE", "Docker --memory cap (e.g. '256m', '1g') for every server role") { |v| opts[:memory_limit] = v }
        o.on("--cpu-limit VALUE", "Docker --cpus cap (e.g. '0.5')") { |v| opts[:cpu_limit] = v }

        o.on("-h", "--help") { puts o; exit }
      end.parse!(argv)

      die!("--branch is required") unless opts[:branch]
      die!("--base-deploy-file is required") unless opts[:base_deploy_file]
      die!("--domain-suffix is required") unless opts[:domain_suffix]
      opts
    end

    def emit(data)
      puts JSON.pretty_generate(data)
      write_github_output(data) if ENV["GITHUB_OUTPUT"] && !ENV["GITHUB_OUTPUT"].empty?
    end

    def write_github_output(data)
      File.open(ENV["GITHUB_OUTPUT"], "a") do |f|
        data.each do |key, value|
          # Multi-line values use the `<<EOF\n…\nEOF` heredoc syntax.
          # Most of our outputs are short single-line strings; guard for safety.
          str = value.to_s
          if str.include?("\n")
            delim = "EOF#{rand(2**32)}"
            f.puts("#{key}<<#{delim}")
            f.puts(str)
            f.puts(delim)
          else
            f.puts("#{key}=#{str}")
          end
        end
      end
    end

    def die!(msg)
      warn "kamal-previews: #{msg}"
      exit 1
    end

    def print_help
      puts <<~HELP
        kamal-previews — preview-environment helper for Kamal-deployed Rails apps.

        Usage:
          kamal-previews generate    --branch <name> --base-deploy-file <path> --domain-suffix <suffix> [options]
          kamal-previews slugify     --branch <name>
          kamal-previews version

        Run any subcommand with --help for details.
      HELP
    end
  end
end
