# Umami

Shows how many people are on your sites right now, from [Umami Analytics](https://umami.is), in the bar. Click the
widget for a dashboard of every website: visitors, views and trends for the last 24 hours, 7, 30 or 90 days, and a
per-website page with its stats, a visitors/views chart, and top pages, sources, environments and locations. Works
with Umami Cloud and self-hosted instances.

## Plugin

| Field   | Value                                  |
| ------- | -------------------------------------- |
| ID      | `ak4duy/umami`                         |
| Entries | Bar widget: `bar`, panel: `dashboard` |

## Requirements

- An Umami API key (Umami Cloud, or self-hosted Umami 3 and later), or the username and password of a self-hosted
  Umami account without two-factor authentication.
- `xdg-open` on `PATH`, used by **Open in Umami** to open a website in your default browser.
- If your Umami instance is behind Cloudflare Access, a Cloudflare Access service token. See
  [Umami behind Cloudflare Access](#umami-behind-cloudflare-access-zero-trust).

## Usage

1. Add the `bar` widget to a bar. Until it is configured it shows a settings icon; left-click it to open the plugin
   settings.
2. For Umami Cloud, paste your **API Key** and keep the default **API URL**. For a self-hosted instance, set
   **API URL** to your instance URL followed by `/api`, then paste an **API Key** from Settings → API keys or fill in
   **Username** and **Password**.

### Umami behind Cloudflare Access (Zero Trust)

If your Umami instance is protected by a Cloudflare Access application, requests from the plugin get a `302` redirect
to a Cloudflare login page. Allow the plugin through with a service token:

1. In the Cloudflare dashboard, go to **Zero Trust → Access controls → Service credentials**.
2. Click **Create Service Token**, give it a name, and copy the **Client ID** and **Client Secret**. The secret is shown
   only once.
3. Go to **Access controls → Applications**, open the application for your Umami domain, and go to its **Policies**
   tab.
4. Add a policy with **Action: Service Auth**, and under **Include** choose **Service Token** and select the token you
   created. Move this policy above any policy that requires a login.
5. In the plugin settings, paste the Client ID into **Cloudflare Access Client ID** and the Client Secret into
   **Cloudflare Access Client Secret**.

The plugin then sends both values as `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers on every request.

To test from a terminal, replace the placeholders:

```sh
curl -sI -H "CF-Access-Client-Id: <client id>" -H "CF-Access-Client-Secret: <client secret>" https://<your-umami-host>/api/heartbeat
```

`HTTP/2 200` means the token works. A `302` still pointing to `cloudflareaccess.com` means the policy in step 4 is
missing or is below a login policy.

The widget shows a chart icon and the number of visitors active in the last five minutes across all your websites.
Left-click it to open the dashboard, right-click to refresh. A warning icon means the last request failed; hover it to
see why.

To open the dashboard without the widget, bind this command to a key:

```sh
noctalia msg panel-toggle ak4duy/umami:dashboard
```

In the dashboard, pick a period at the top, then click a website to see its details. **Open in Umami** opens that
website in your browser. Hover a bar in the chart for its exact numbers. The **Pages**, **Sources**, **Environment**
and **Location** cards each have tabs (for example Browsers, OS and Devices); each card can be hidden in the settings.

## Settings

Plugin settings, shared by every instance:

| Setting                   | Type     | Default                   | Description                                                                                           |
| ------------------------- | -------- | ------------------------- | ----------------------------------------------------------------------------------------------------- |
| `api_url`                 | `string` | `https://api.umami.is/v1` | Umami API root. Self-hosted: `https://<your-instance>/api`.                                           |
| `api_key`                 | `string` | `""`                      | Umami API key. When set, username and password are ignored.                                           |
| `username`                | `string` | `""`                      | Self-hosted login username.                                                                           |
| `password`                | `string` | `""`                      | Self-hosted login password.                                                                           |
| `cf_access_client_id`     | `string` | `""`                      | Cloudflare Access service token Client ID, for Umami behind Cloudflare Access. See the section above. |
| `cf_access_client_secret` | `string` | `""`                      | Cloudflare Access service token Client Secret. Stored in plain text in your Noctalia config.          |
| `refresh_seconds`         | `int`    | `60`                      | Seconds between fetches, from 15 to 3600.                                                             |
| `show_pages`              | `bool`   | `true`                    | Show the Pages card (path, URL, entry and exit pages).                                                |
| `show_sources`            | `bool`   | `true`                    | Show the Sources card (referrers and channels).                                                       |
| `show_environment`        | `bool`   | `true`                    | Show the Environment card (browsers, OS and devices).                                                 |
| `show_location`           | `bool`   | `true`                    | Show the Location card (countries, regions and cities).                                               |

## Notes

- Every `refresh_seconds`, each widget instance requests `<api_url>/websites` and `/websites/<id>/active` for each
  website. While the dashboard is open it also requests `/websites/<id>/stats` and `/websites/<id>/pageviews` for each
  website, plus `/websites/<id>/metrics` once per shown card, for the selected tab of the website being viewed. With a
  username and password each entry first calls `<api_url>/auth/login` and reuses the returned token until Umami rejects
  it or the settings change. These are the plugin's only network requests.
- Chart buckets are hours for 24H and UTC days for longer periods.
- The plugin runs `xdg-open` only when you click **Open in Umami**.
- The API key, username, password and Cloudflare Access client secret are stored in plain text in your Noctalia config,
  like every other plugin setting. The Cloudflare Access headers are sent to your Umami host on every request.
- The plugin writes no files.
- This plugin is not affiliated with Umami Software.
