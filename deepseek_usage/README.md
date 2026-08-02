# DeepSeek Usage Plugin for Noctalia

A clean, beautiful balance and API credit monitor for [Noctalia shell](https://noctalia.dev).

## Features
- **Bar Widget**: Shows live balance directly on your Noctalia bar.
- **Low Balance Warning**: Visual indicator and desktop notifications when credits drop below your set threshold.
- **Interactive Panel**: Displays account wallet summary, local trend graph, and quick top-up action.
- **One-Click Top-Up**: "Add Credits" button opens `platform.deepseek.com/top_up` directly in your browser.

## Installation
Copy or symlink the `deepseek_usage` directory into your Noctalia plugins folder:

```bash
mkdir -p ~/.config/noctalia/plugins/
cp -r deepseek_usage ~/.config/noctalia/plugins/
```

## Settings
Configure the update interval and API key in Noctalia plugin settings.

- **DeepSeek API Key**: Create an API key at [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys) and enter it in plugin settings.
- **Refresh Interval**: Default is 15 minutes.
- **Low Balance Warning**: Default threshold is 2.00.

## Security Note
Your API key is stored locally in standard Noctalia configuration files. Keep your machine secure and never commit plaintext keys to public repositories.
