# K8s Status

Monitor Kubernetes nodes, pods, and deployments from Noctalia, with a `/kube` launcher for common actions.

## Plugin

| Field | Value |
| --- | --- |
| ID | `davemhammer/k8s-status` |
| Entries | Bar widget: `status`; panel: `manager`; service: `service`; launcher: `kube` |
| Launcher Prefix | `/kube` |

## Requirements

Install `kubectl` on `PATH` (or set `kubectl_bin`). Cluster access uses your kubeconfig.

Optional: `k9s` if you use the open-k9s action.

## Usage

Add the **status** bar widget (`davemhammer/k8s-status:status`). Click for the panel; right-click requests a refresh.

Panel tabs: **Nodes**, **Pods**, **Deployments**, **Namespaces**. Select a row for describe / logs / shell / restart actions (where applicable).

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
| `kubeconfig` | `file` | `~/.kube/config` | Kubeconfig path. |
| `context` | `string` | _(empty)_ | Context name; empty uses current-context. |
| `namespace` | `string` | _(empty)_ | Limit pods/deployments; empty = all namespaces. |
| `refresh_interval` | `int` | `15` | Poll interval in seconds. |
| `problems_only` | `bool` | `false` | Prefer problem pods in the panel list. |
| `notify_on_not_ready` | `bool` | `true` | Notify when a node becomes NotReady. |
| `kubectl_bin` | `string` | `kubectl` | kubectl command or absolute path. |
| `show_counts` | `bool` (widget) | `true` | Show ready nodes / problem pods on the bar. |

## IPC

```sh
noctalia msg panel-toggle davemhammer/k8s-status:manager
noctalia msg plugin davemhammer/k8s-status:service all refresh
```

## Notes

- Shells out to `kubectl` (and optionally a terminal via `runInTerminal` for logs/shell/k9s).
- Does not modify cluster state unless you run restart/delete-style actions from the panel or launcher.
- Large clusters: refresh uses jsonpath-style queries to keep payloads small.
