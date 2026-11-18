# BitDjinn

BitDjinn is a real-time cryptocurrency market tracker, trend visualizer, and multi-chain address balance monitor with desktop transaction alerts for Noctalia.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nirvam/bitdjinn` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service`; desktop widget: `desktop`; shortcut: `toggle` |

## Usage

Access the BitDjinn interactive dashboard by clicking the bar widget or via IPC:

```sh
noctalia msg panel-toggle nirvam/bitdjinn:panel
```

- **Bar Widget (`bar`)**: Shows current price for your preferred coin (e.g. BTC) and a 24h change pill. Scroll vertically over the widget to cycle through watched assets. Click to open the dashboard panel.
- **Panel (`panel`)**: Interactive multi-tab dashboard featuring real-time market cards, 36-hour sparkline trend graphs, instant currency converter (`USD`, `CNY`, `EUR`, `USDT`, `USDC`), and an on-chain address watcher with copy-to-clipboard actions.
- **Desktop Widget (`desktop`)**: HUD card pinned to the desktop displaying large price trend graphs and total portfolio valuation.
- **Control Center Shortcut (`toggle`)**: Quick toggle tile to mute or enable desktop transaction notifications.

## Settings

Configure BitDjinn under **Settings → Plugins → BitDjinn** or in `~/.config/noctalia/config.toml`:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `currency` | `select` | `usd` | Display fiat/stablecoin valuation currency (`usd`, `cny`, `eur`, `usdt`, `usdc`). |
| `interval` | `int` | `30` | Market prices and trend sparklines refresh cadence (10–600 seconds). |
| `wallet_interval` | `int` | `60` | On-chain address balance and transaction check cadence (15–1800 seconds). |
| `notify_tx` | `bool` | `true` | Send desktop notifications when a balance or transaction count change is detected. |
| `widget_coin` | `string` | `BTC` | Default cryptocurrency symbol displayed on the status bar widget. |

## IPC

Send commands to BitDjinn's background service from scripts or compositor bindings:

```sh
# Trigger immediate market prices and on-chain balance refresh
noctalia msg plugin nirvam/bitdjinn:service all refresh

# Add a wallet address to watch list (supports BTC, ETH 0x..., and SOL)
noctalia msg plugin nirvam/bitdjinn:service all add "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045 Vitalik-Cold"

# Remove a watched address from list
noctalia msg plugin nirvam/bitdjinn:service all remove "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

# Toggle transaction notification alerts
noctalia msg plugin nirvam/bitdjinn:service all toggle_notify

# Refresh status bar widget instance on focused output
noctalia msg plugin nirvam/bitdjinn:bar focused refresh
```

## Notes

- **Network Access**: BitDjinn queries public CoinGecko market endpoints for live exchange rates and sparkline trend history, Mempool.space for Bitcoin addresses, and public JSON-RPC nodes for Ethereum and Solana balances.
- **Privacy & Security**: All address lookups and API requests are read-only. No private keys, seed phrases, or credentials are ever required or stored.
- **Local Persistence**: User watchlists, transaction notification states, and cached exchange rate matrices are saved in `$XDG_DATA_HOME/noctalia/bitdjinn_state.json`.
