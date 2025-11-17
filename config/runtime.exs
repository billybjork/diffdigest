import Config

# Load .env file if it exists (for development)
env_file = Path.join(File.cwd!(), ".env")

if File.exists?(env_file) do
  env_file
  |> File.read!()
  |> String.split("\n")
  |> Enum.each(fn line ->
    line = String.trim(line)

    # Skip comments and empty lines
    unless line == "" or String.starts_with?(line, "#") do
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          System.put_env(String.trim(key), String.trim(value))

        _ ->
          :ok
      end
    end
  end)
end

# Runtime configuration happens after code compilation, so we can safely
# read environment variables here
