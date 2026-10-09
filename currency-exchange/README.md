# Currency Exchange

Shows a live exchange rate on the bar, with a small converter panel and a `/fx` launcher provider for quick
conversions. Rates are merged from two free feeds: open.er-api.com covers about 160 currencies with daily reference rates,
and the AwesomeAPI market feed overrides it with real-time bids for the currencies it lists (including BRL, USD,
EUR, GBP, JPY, CAD, AUD, CHF, CNY and ILS). If one feed is down, the other still works.

Rewritten for Noctalia v5 from the v4 `currency-exchange` plugin by balor. It keeps that plugin's design and the `/fx`
query syntax.

## Plugin

| Field | Value |
| --- | --- |
| ID | `vinioli/currency-exchange` |
| Entries | Bar widget: `rate`; panel: `converter`; launcher provider: `fx`; service: `rates` |
| Launcher Prefix | `/fx` |

## Usage

Add the bar widget with type `vinioli/currency-exchange:rate` under **Settings → Bar → Widget List**. Clicking it opens
the converter panel. Type an amount, pick the two currencies, and the result updates as you type. The swap button flips
the pair and the copy button copies the converted amount.

Open the panel from a keybind or script:

```sh
noctalia msg panel-toggle vinioli/currency-exchange:converter
```

In the launcher, type `/fx` followed by a query. Activating a result copies the converted amount to the clipboard.

| Query | Result |
| --- | --- |
| `/fx 100 USD EUR` | Convert 100 USD to EUR |
| `/fx 50 BRL` | Convert 50 BRL to the target currency |
| `/fx EUR GBP` | Show the rate for 1 EUR in GBP |

## Settings

Configured under **Settings → Plugins**, on the gear of this plugin.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `source_currency` | `string` | `USD` | Three-letter code for the left side of the bar rate. |
| `target_currency` | `string` | `EUR` | Three-letter code for the right side of the bar rate, and the default target for `/fx`. |
| `refresh_minutes` | `int` | `30` | How often rates are fetched, in minutes. |
| `display_mode` | `select` | `full` | `icon` shows only the glyph, `compact` shows the rate, `full` shows the pair and the rate. |

## Notes

- **Network:** one HTTPS GET each to `https://open.er-api.com/v6/latest/USD` and
  `https://economia.awesomeapi.com.br/json/all` on startup and then every `refresh_minutes`. Nothing is sent besides the request itself.
- **Processes:** the bar widget runs no processes. The panel and launcher copy results with `noctalia.copyToClipboard`.
- **Files:** none are written.
- Rates are indicative market bids, not an official or tradable quote. The converter supports the 30 currencies listed
  in the panel, all of which have a rate; `/fx` accepts any code either feed returns.
