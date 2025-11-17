defmodule Mix.Tasks.Newsletter.Generate do
  use Mix.Task

  @shortdoc "Generate a git newsletter and send via Mailgun"

  @moduledoc """
  Generates a newsletter from git commits and sends it via email.

  ## Usage

      mix newsletter.generate              # Default: last 7 days
      mix newsletter.generate --days 14    # Last 14 days
      mix newsletter.generate --days 30    # Last 30 days

  ## Options

    * `--days` - Number of days to look back (default: 7)

  """

  def run(args) do
    Mix.Task.run("app.start")

    # Parse arguments
    {opts, _remaining, _invalid} =
      OptionParser.parse(args, strict: [days: :integer])

    days = Keyword.get(opts, :days, 7)

    case DiffDigest.Newsletter.run(days: days) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("Newsletter generation failed: #{inspect(reason)}")
    end
  end
end
