defmodule DiffDigest.Newsletter do
  @moduledoc """
  Generates a newsletter from git commits over a configurable time window and emails it.

  Idempotent per date: if today's newsletter + summary files already exist,
  it will skip regeneration and sending.

  ## Options

    * `:date` - The end date for the newsletter (defaults to today)
    * `:days` - Number of days to look back (defaults to 7)

  """

  # File paths
  @system_prompt_rel_path "priv/system_prompt_full.md"
  @summary_prompt_rel_path "priv/system_prompt_summary.md"
  @email_template_rel_path "priv/email_template.html.eex"
  @newsletters_rel_dir "priv/newsletters"
  @summaries_rel_dir "priv/newsletters/summaries"

  # AI model configuration (Claude/Anthropic)
  @ai_model "claude-opus-4-5-20251101"

  # Newsletter generation settings
  @newsletter_max_tokens 32000

  # Summary generation settings
  @summary_max_tokens 8000

  # Context settings
  @previous_summaries_count 5

  require Logger

  ## Public API

  def run(opts \\ []) do
    date = Keyword.get(opts, :date, Date.utc_today())
    days = Keyword.get(opts, :days, 7)
    config = load_config()
    app_root = get_app_root()

    {newsletter_path, summary_path, slug} =
      output_paths(app_root, date, days)

    if File.exists?(newsletter_path) and File.exists?(summary_path) do
      Logger.info("Newsletter already exists for #{slug}; skipping (idempotent).")
      :ok
    else
      with {:ok, diffs} <- git_diffs(config.repo_root, days),
           :non_empty <- check_non_empty_diffs(diffs),
           {:ok, system_prompt} <- load_system_prompt(app_root),
           {:ok, summary_prompt} <- load_summary_prompt(app_root),
           previous_summaries <- load_previous_newsletters(app_root, date),
           {:ok, newsletter_md} <-
             generate_newsletter(
               config.anthropic_api_key,
               system_prompt,
               diffs,
               date,
               days,
               previous_summaries
             ),
           {:ok, summary_md} <-
             generate_short_summary(config.anthropic_api_key, summary_prompt, newsletter_md),
           :ok <- ensure_output_dirs(app_root),
           :ok <- File.write(newsletter_path, newsletter_md),
           :ok <- File.write(summary_path, summary_md),
           :ok <- send_email(config, date, summary_md, newsletter_md) do
        Logger.info("Generated and sent newsletter #{slug}.")
        :ok
      else
        :empty ->
          Logger.info("No commits in last #{days} days; nothing to send.")
          :ok

        {:error, reason} ->
          Logger.error("Newsletter generation failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  ## Config

  defp load_config do
    from_email = fetch_env!("NEWSLETTER_FROM")
    from_name = System.get_env("NEWSLETTER_FROM_NAME")

    # Format "from" field: if name is provided, use "Name <email>", otherwise just email
    from = if from_name && String.trim(from_name) != "" do
      "#{from_name} <#{from_email}>"
    else
      from_email
    end

    %{
      # All configuration values are required via environment variables
      repo_root: fetch_env!("REPO_ROOT"),
      from: from,
      reply_to: fetch_env!("NEWSLETTER_REPLY_TO"),
      recipients: fetch_env!("NEWSLETTER_RECIPIENTS"),
      mailgun_domain: fetch_env!("MAILGUN_DOMAIN"),
      mailgun_api_key: fetch_env!("MAILGUN_API_KEY"),
      anthropic_api_key: fetch_env!("ANTHROPIC_API_KEY")
    }
  end

  defp fetch_env!(name) do
    case System.get_env(name) do
      nil -> raise "Environment variable #{name} is required"
      value -> value
    end
  end

  defp get_app_root do
    # Returns the DiffDigest project root directory
    # This is where mix.exs lives and where we'll store priv/ files
    File.cwd!()
  end

  ## Git

  defp git_diffs(repo_root, days) do
    # Commits with stats and diffs from the specified number of days
    # Uses relative date syntax that doesn't require shell quoting.
    # --patch provides actual content changes for meaningful newsletter generation
    args = ["log", "--since=#{days}.days.ago", "--stat", "--patch", "--no-color"]

    case System.cmd("git", args, cd: repo_root) do
      {output, 0} ->
        truncated = truncate_diffs(output, 50_000)
        {:ok, String.trim(truncated)}

      {output, status} ->
        {:error, {:git_log_failed, status, output}}
    end
  end

  # Intelligently truncates git log output to stay within token limits
  # Keeps commit headers and stats, but limits individual patch sizes
  # Max output is approximately max_chars characters
  defp truncate_diffs(output, max_chars) when is_binary(output) do
    if String.length(output) <= max_chars do
      output
    else
      # Split on commit boundaries and truncate
      lines = String.split(output, "\n")
      {result, _} = truncate_lines(lines, max_chars)
      result
    end
  end

  defp truncate_lines(lines, max_chars) do
    Enum.reduce_while(lines, {"", 0}, fn line, {result, current_length} ->
      line_with_newline = line <> "\n"
      new_length = current_length + String.length(line_with_newline)

      if new_length > max_chars do
        # Stop processing and add truncation notice
        {:halt, {result <> "\n[git log truncated to fit context window]\n", new_length}}
      else
        {:cont, {result <> line_with_newline, new_length}}
      end
    end)
  end

  defp check_non_empty_diffs(""), do: :empty
  defp check_non_empty_diffs(str) when is_binary(str) do
    if String.trim(str) == "" do
      :empty
    else
      :non_empty
    end
  end

  ## System prompt

  defp load_system_prompt(repo_root) do
    path = Path.join(repo_root, @system_prompt_rel_path)

    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error, {:system_prompt_read_failed, path, reason}}
    end
  end

  defp load_summary_prompt(repo_root) do
    path = Path.join(repo_root, @summary_prompt_rel_path)

    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error, {:summary_prompt_read_failed, path, reason}}
    end
  end

  defp load_previous_newsletters(app_root, current_date) do
    summaries_dir = Path.join(app_root, @summaries_rel_dir)

    # Return empty list if directory doesn't exist yet
    if not File.exists?(summaries_dir) do
      []
    else
      # Get all summary files, parse dates, and sort by most recent
      summaries_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".summary.md"))
      |> Enum.map(fn filename ->
        # Extract date from filename (YYYY-MM-DD-*.summary.md)
        date_str = filename |> String.split("-") |> Enum.take(3) |> Enum.join("-")

        case Date.from_iso8601(date_str) do
          {:ok, date} -> {date, filename}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      # Only include newsletters before the current date
      |> Enum.filter(fn {date, _filename} -> Date.compare(date, current_date) == :lt end)
      |> Enum.sort_by(fn {date, _filename} -> date end, {:desc, Date})
      |> Enum.take(@previous_summaries_count)
      |> Enum.map(fn {date, filename} ->
        path = Path.join(summaries_dir, filename)

        case File.read(path) do
          {:ok, content} -> {Date.to_iso8601(date), String.trim(content)}
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    end
  end

  ## Directories & output file naming

  defp ensure_output_dirs(repo_root) do
    newsletters_dir = Path.join(repo_root, @newsletters_rel_dir)
    summaries_dir = Path.join(repo_root, @summaries_rel_dir)

    with :ok <- File.mkdir_p(newsletters_dir),
         :ok <- File.mkdir_p(summaries_dir) do
      :ok
    else
      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  defp output_paths(repo_root, date, days) do
    date_string = Date.to_iso8601(date)

    # Generate slug based on days: weekly for 7, otherwise show the days
    period = if days == 7, do: "weekly", else: "#{days}d"
    slug = "#{date_string}-#{period}"

    newsletters_dir = Path.join(repo_root, @newsletters_rel_dir)
    summaries_dir = Path.join(repo_root, @summaries_rel_dir)

    newsletter_path = Path.join(newsletters_dir, "#{slug}.md")
    summary_path = Path.join(summaries_dir, "#{slug}.summary.md")

    {newsletter_path, summary_path, slug}
  end

  ## Anthropic Claude client

  defp anthropic_req_client(api_key) do
    Req.new(
      base_url: "https://api.anthropic.com/v1",
      headers: [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ],
      json: true,
      receive_timeout: 300_000  # 5 minutes for long generation
    )
  end

  defp generate_newsletter(api_key, system_prompt, diffs, date, days, previous_summaries) do
    client = anthropic_req_client(api_key)

    start_date = Date.add(date, -(days - 1))
    date_range = "#{Date.to_iso8601(start_date)} to #{Date.to_iso8601(date)}"

    # Format previous summaries if available
    previous_context =
      if Enum.empty?(previous_summaries) do
        ""
      else
        summaries_text =
          previous_summaries
          |> Enum.map(fn {date, content} -> "- #{date}: #{content}" end)
          |> Enum.join("\n")

        """

        Previous newsletter summaries (for context):

        #{summaries_text}
        """
      end

    user_prompt = """
    Date range: #{date_range} (#{days} days)
    #{previous_context}

    Git log output:

    ```git
    #{diffs}
    ```
    """

    body = %{
      "model" => @ai_model,
      "max_tokens" => @newsletter_max_tokens,
      "system" => system_prompt,
      "messages" => [
        %{"role" => "user", "content" => user_prompt}
      ]
    }

    resp =
      Req.post!(client, url: "/messages", json: body)

    Logger.debug("Claude Newsletter Response: #{inspect(resp.body, pretty: true)}")

    extract_output_text(resp.body)
  end

  defp generate_short_summary(api_key, summary_prompt, newsletter_markdown) do
    client = anthropic_req_client(api_key)

    user_prompt = """
    Newsletter:

    ```markdown
    #{newsletter_markdown}
    ```
    """

    body = %{
      "model" => @ai_model,
      "max_tokens" => @summary_max_tokens,
      "system" => summary_prompt,
      "messages" => [
        %{"role" => "user", "content" => user_prompt}
      ]
    }

    resp =
      Req.post!(client, url: "/messages", json: body)

    Logger.debug("Claude Summary Response: #{inspect(resp.body, pretty: true)}")

    extract_output_text(resp.body)
  end

  # Parses the Claude Messages API JSON into a plain text string.
  #
  # Expected shape (simplified):
  # %{
  #   "content" => [
  #     %{"type" => "text", "text" => "..."}
  #   ],
  #   ...
  # }
  defp extract_output_text(%{"content" => content}) when is_list(content) do
    case Enum.find(content, fn part -> part["type"] == "text" end) do
      %{"text" => text} ->
        Logger.debug("Successfully extracted text of length: #{String.length(text)}")
        {:ok, text}

      _ ->
        Logger.debug("No text content found in response")
        {:error, :no_output_text_found}
    end
  end

  defp extract_output_text(%{"error" => error}) do
    Logger.error("Claude API error: #{inspect(error)}")
    {:error, {:claude_api_error, error}}
  end

  defp extract_output_text(response) do
    Logger.debug("Response doesn't match expected shape: #{inspect(Map.keys(response))}")
    {:error, :unexpected_claude_response_shape}
  end

  ## Mailgun email

  defp send_email(config, date, short_summary_text, newsletter_markdown) do
    subject = "DiffDigest – #{Date.to_iso8601(date)}"

    with {:ok, html} <- render_email_html(date, short_summary_text, newsletter_markdown) do
      text_body = """
      #{subject}

      #{short_summary_text}

      ---

      #{newsletter_markdown}
      """

      form = [
        from: config.from,
        to: config.recipients,
        subject: subject,
        "h:Reply-To": config.reply_to,
        text: text_body,
        html: html
      ]

      url = "https://api.mailgun.net/v3/#{config.mailgun_domain}/messages"

      case Req.post(url, auth: {:basic, "api:#{config.mailgun_api_key}"}, form: form) do
        {:ok, %{status: status}} when status in 200..299 ->
          Logger.info("Email sent successfully (status: #{status})")
          :ok

        {:ok, %{status: status, body: body}} ->
          Logger.error("Email send failed with status #{status}: #{inspect(body)}")
          {:error, {:email_send_failed, status, body}}

        {:error, reason} ->
          Logger.error("Email send request failed: #{inspect(reason)}")
          {:error, {:email_send_request_failed, reason}}
      end
    end
  end

  defp render_email_html(date, short_summary_text, newsletter_markdown) do
    with {:ok, newsletter_html, _} <- Earmark.as_html(newsletter_markdown),
         app_root <- get_app_root(),
         template_path <- Path.join(app_root, @email_template_rel_path),
         {:ok, template} <- File.read(template_path) do
      date_str = Date.to_iso8601(date)

      # Prepare template variables
      assigns = [
        date_str: date_str,
        short_summary_text: escape_html(short_summary_text),
        newsletter_html: newsletter_html
      ]

      {:ok, EEx.eval_string(template, assigns)}
    else
      {:error, reason} ->
        {:error, {:email_template_error, reason}}
    end
  end

  # minimal escaping for the summary snippet
  defp escape_html(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
