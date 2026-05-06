# frozen_string_literal: true

module FeatureDeploys
  # Sanitizes a Git branch name into the two flavors of slug we need:
  #
  #   * `slug` — DNS-safe (a-z, 0-9, '-'). Used for subdomains and Kamal
  #     destination filenames. Max 50 chars to leave headroom under the 63-char
  #     DNS-label limit when callers append a hostname segment.
  #   * `db_slug` — SQL-identifier-safe (a-z, 0-9, '_', starts with a letter).
  #     Used for database names and other identifiers. Max 50 chars; PostgreSQL
  #     identifiers cap at 63, MySQL at 64, SQLite is unbounded — 50 is
  #     comfortably under all three.
  #
  # Both slugs are derived from the *branch name*, not the PR number, so they
  # remain stable across all three lifecycle events: PR open, PR close, and
  # branch delete (where no PR number is available).
  class Namer
    DEFAULT_PREFIX_STRIP = %w[feature/ feat/ fix/ bug/ bugfix/ chore/ hotfix/ release/].freeze

    SLUG_MAX = 50
    DB_SLUG_MAX = 50

    Result = Struct.new(:branch, :slug, :db_slug, keyword_init: true) do
      def to_h
        super.transform_keys(&:to_s)
      end
    end

    class InvalidBranchName < FeatureDeploys::Error; end

    def self.call(branch_name, prefix_strip: DEFAULT_PREFIX_STRIP)
      new(branch_name, prefix_strip: prefix_strip).call
    end

    def initialize(branch_name, prefix_strip: DEFAULT_PREFIX_STRIP)
      @branch_name = String(branch_name).strip
      @prefix_strip = Array(prefix_strip)
    end

    def call
      raise InvalidBranchName, "branch name is empty" if @branch_name.empty?

      Result.new(branch: @branch_name, slug: build_slug, db_slug: build_db_slug)
    end

    private

    def stripped_source
      stripped = @branch_name.dup
      @prefix_strip.each do |prefix|
        if stripped.downcase.start_with?(prefix.downcase)
          stripped = stripped[prefix.length..]
          break
        end
      end
      stripped
    end

    def build_slug
      out = stripped_source.downcase.gsub(/[^a-z0-9]+/, "-")
      out = out.gsub(/-+/, "-").sub(/\A-+/, "").sub(/-+\z/, "")
      out = out[0, SLUG_MAX].sub(/-+\z/, "")
      raise InvalidBranchName, "branch name '#{@branch_name}' produces empty slug" if out.empty?

      out
    end

    def build_db_slug
      out = stripped_source.downcase.gsub(/[^a-z0-9]+/, "_")
      out = out.gsub(/_+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
      out = "b_#{out}" unless /\A[a-z]/.match?(out)
      out = out[0, DB_SLUG_MAX].sub(/_+\z/, "")
      raise InvalidBranchName, "branch name '#{@branch_name}' produces empty db_slug" if out.empty?

      out
    end
  end
end
