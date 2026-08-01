# OBS Integration

Manage openSUSE Build Service projects and packages from Noctalia. The bar
widget toggles a panel for browsing your projects, checking out packages,
editing metadata and files, and triggering rebuilds on OBS — without leaving
the shell.

## Plugin

| Field | Value |
| --- | --- |
| ID | `neyfua/obs-integration` |
| Entries | Bar widget: `obs-integrate`; panel: `panel` |

## Requirements

Install the openSUSE Build Service `osc` CLI on `PATH` and configure your
credentials in `~/.config/osc/oscrc` (for example with `osc apiservice` setup
or by copying a working `oscrc`). The plugin shells out to `osc` for every
operation, so all authentication stays in your normal OBS configuration.

## Usage

Add the `obs-integrate` widget to a bar. Left-click it to open the panel.

Open the panel directly with:

```sh
noctalia msg panel-toggle neyfua/obs-integration:panel
```

### My Projects

The panel opens on **My Projects**: every project you maintain, plus every
project where you are listed as a package maintainer on OBS. Search filters the
list, and the sort button toggles A-Z / Z-A order. The pen icon edits the
project metadata (`osc meta prj -e`).

### Inside a project

Click a project to list its packages. A package's icon turns **primary** when
that package is checked out in your local directory. Click a package to open
its actions:

- **Checkout package** — `osc co` in the configured checkout directory
  (hidden once the package is already checked out).
- **Edit files** — expandable list of editable sources: `_service` and the
  package's `.spec` open in your `$EDITOR`; the `.changes` file runs
  `osc vc`.
- **Files** — lists every non-dotfile in the checkout. Each file has a remove
  button; below the list, **Add/Remove** runs `osc ar` and **Commit** runs
  `osc ci`, both in a terminal so you can watch progress or edit the commit
  message.
- **Rebuild package** — pick an architecture (or **All**) and trigger
  `osc rebuild`.
- **Edit package meta** — `osc meta pkg -e` in a terminal.
- **Remove package** — deletes the checkout from disk only (never touches the
  OBS project); confirm before it runs. If it was the last package in the
  project directory, the directory is removed too.

### Sticky navigation

The panel reopens where you left off — inside the same project or package.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `checkout_dir` | `string` | `~/OBS` | Base directory where packages are checked out. Packages land in `<checkout_dir>/<project>/<package>`. |
| `show_label` | `bool` | `false` | Show the "OBS" label next to the bar icon. |

## Notes

The plugin runs the `osc` CLI with your existing credentials — it stores
nothing itself beyond a small cache of project/package listings and your last
navigated view. Removal is local-only and never modifies the OBS project.
Rebuilds and commits are real OBS operations and open a terminal so you can
confirm what `osc` reports.
