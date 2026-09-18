# K8s Status

Monitor Kubernetes nodes, pods, and deployments from Noctalia, with a `/kube` launcher for common actions.

## Plugin

| Field | Value |
| --- | --- |
| ID | `davemhammer/k8s-status` |
| Entries | Bar widget: `status`; panel: `manager`; service: `service`; launcher: `kube` |
| Launcher Prefix | `/kube` |

## Requirements

Install these on `PATH` (declared in `plugin.toml` `dependencies`):

- `kubectl` — cluster queries and actions (or set `kubectl_bin`)
- `less` — pager for describe/logs in the terminal

Optional (not declared; used only if present):

- `k9s` — open-k9s action

Cluster access uses your kubeconfig (passed to kubectl as `--kubeconfig`; the plugin does not parse the file itself).

## Usage

Add the **status** bar widget (`davemhammer/k8s-status:status`). Click for the panel; right-click requests a refresh.

Panel tabs: **Nodes**, **Pods**, **Deployments**, **Namespaces**. Select a row for describe / logs / shell / restart actions (where applicable).

When the kubeconfig holds multiple contexts and the `context` setting is empty, the panel header shows a context
selector. Picking one runs `kubectl config use-context` (the kubectx equivalent), so the choice is shared with your
terminal and persists across restarts. With `context` set in the plugin settings, the selector stays a read-only
label because the pinned setting overrides every kubectl call.

Launcher examples:

- `/kube` — categories (pods, problems, nodes, …)
- `/kube pods nginx` — filter pods
- `/kube problems` — problem pods only

```sh
noctalia msg panel-toggle davemhammer/k8s-status:manager
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `kubeconfig` | `file` | `~/.kube/config` | Path passed to kubectl as `--kubeconfig`. |
| `context` | `string` | _(empty)_ | Context name; empty uses current-context. |
| `namespace` | `string` | _(empty)_ | Limit pods/deployments; empty = all namespaces. |
| `refresh_interval` | `int` | `15` | Poll interval in seconds. |
| `problems_only` | `bool` | `false` | Prefer problem pods in the panel list. |
| `notify_on_not_ready` | `bool` | `true` | Notify when a node becomes NotReady. |
| `kubectl_bin` | `string` | `kubectl` | kubectl command or absolute path. |
| `show_counts` | `bool` (widget) | `true` | Show ready nodes / problem pods on the bar. |
| `ok_color` | `select` (widget) | `tertiary` | Bar color when cluster looks healthy. |
| `warn_color` | `select` (widget) | `error` | Bar color when there are problems. |

## IPC

```sh
noctalia msg panel-toggle davemhammer/k8s-status:manager
noctalia msg plugin davemhammer/k8s-status:service all refresh
noctalia msg plugin davemhammer/k8s-status:service all use_context <name>
```

## Notes

- Shells out to `kubectl` and `less` (and optionally a terminal via `runInTerminal` for logs/shell/`k9s`).
- Refresh: nodes, deployments, and namespaces use compact **jsonpath** queries; pods use `kubectl get pods` table output for ready/restart columns.
- Modifies your kubeconfig's current-context when you pick a context in the panel selector; does not modify cluster
  state unless you run restart/delete-style actions from the panel or launcher.
- Network: only via `kubectl` to the API server from your kubeconfig. No cluster credentials are written into the plugin tree.
