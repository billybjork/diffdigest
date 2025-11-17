# DiffDigest

AI-powered newsletter generator that turns git commits into digestible email updates.

## What it does

DiffDigest monitors a git repository and generates formatted newsletters from commit activity using OpenAI's GPT-5. It creates both a detailed newsletter and a short summary, then sends them via email.

## Setup

1. Install dependencies:
   ```bash
   mix deps.get
   ```

2. Create a `.env` file with required configuration:
   ```bash
   REPO_ROOT=/path/to/your/git/repo
   NEWSLETTER_FROM=digest@yourdomain.com
   NEWSLETTER_REPLY_TO=you@yourdomain.com
   NEWSLETTER_RECIPIENTS=team@yourdomain.com
   MAILGUN_DOMAIN=mg.yourdomain.com
   MAILGUN_API_KEY=your-mailgun-api-key
   OPENAI_API_KEY=your-openai-api-key
   ```

## Usage

Generate and send a weekly newsletter (last 7 days):
```bash
mix newsletter.generate
```

Generate for a custom date range:
```bash
mix newsletter.generate --date 2025-01-15 --days 14
```

Newsletters are saved to `priv/newsletters/` and summaries to `priv/newsletters/summaries/`. Running the same command twice is idempotent - it won't regenerate or resend existing newsletters.

