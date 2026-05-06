# frozen_string_literal: true

# Top-level entry point for the stdlib-only kamal_previews library.
# Loading this file pulls in the namer and config generator. Everything
# downstream is reachable as `KamalPreviews::Namer`, etc.

module KamalPreviews
  class Error < StandardError; end
end

require_relative "kamal_previews/version"
require_relative "kamal_previews/namer"
require_relative "kamal_previews/config_generator"
require_relative "kamal_previews/cli"
