import Config

# Configure Jason as JSON library
config :absmartly, :json_library, Jason

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
