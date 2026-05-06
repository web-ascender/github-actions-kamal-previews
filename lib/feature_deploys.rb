# frozen_string_literal: true

# Top-level entry point for the stdlib-only feature_deploys library.
# Loading this file pulls in the namer and config generator. Everything
# downstream is reachable as `FeatureDeploys::Namer`, etc.

module FeatureDeploys
  class Error < StandardError; end
end

require_relative "feature_deploys/version"
require_relative "feature_deploys/namer"
require_relative "feature_deploys/config_generator"
require_relative "feature_deploys/cli"
