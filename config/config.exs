import Config

# Default workspace configuration
config :jido_workspace,
  default_adapter: Jido.VFS.Adapter.InMemory

# Import environment specific config
import_config "#{config_env()}.exs"
