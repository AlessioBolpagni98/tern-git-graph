# tern-git-graph

A minimal commit graph for [Tern](https://docs.stencil.so/tern/): every branch of the repository you are in, drawn as
colored lanes beside a table of commits. Open it as a quick look floating over the terminal, or keep it as a sidebar
on the left.

- Lanes for local branches, remote branches (toggle) and tags, with ref chips on their commits
- Follows the terminal it was opened from: `cd` into another repository and the graph switches
- Refreshes on its own when a command finishes in any pane inside the repository (commit, checkout, fetch, rebase…)
- Click a commit and its details show beside the graph (under it in a narrow pane): author, message, refs,
  parents, files with their added and removed lines, and each file's diff
- Double click, <kbd>Enter</kbd> or the expand button gives the commit the whole pane; <kbd>Esc</kbd> goes back
- The head row shows the checked-out branch, how far it is ahead of or behind its upstream, and the commit count
- Right click a commit to copy its hash or subject, or expand it
- Read-only: it never changes the repository

## Install

```sh
tern plugin install ~/GitHub/tern-git-graph   # copy into Tern's plugins folder
# or, to edit in place:
tern plugin link ~/GitHub/tern-git-graph
```

The plugin has both halves (`host.luau` for the graph block, `window.luau` for the commands), so for panes on a remote
host install it on that host too. It needs `git` 2.31 or newer on `PATH`.

## Use

| How | What |
| --- | --- |
| <kbd>⌃⌥G</kbd> (Ctrl+Alt+G) or **Git Graph: Quick look** in the palette | Floats the graph over the focused pane; run again or press <kbd>Esc</kbd> to close |
| **Git Graph: Toggle sidebar** in the palette | Opens the graph left of the focused pane at a quarter of its width; run again to close. The width you drag it to is remembered |
| The branch button in the Files pane header | Toggles the sidebar for the folder the Files pane shows |

Keys inside the graph:

| Key | Action |
| --- | --- |
| <kbd>↑</kbd> <kbd>↓</kbd> / <kbd>k</kbd> <kbd>j</kbd> | Select a commit (<kbd>PgUp</kbd> <kbd>PgDn</kbd>, <kbd>g</kbd> <kbd>G</kbd> jump) |
| <kbd>Enter</kbd> | Expand the selected commit (merges are diffed against their first parent) |
| <kbd>c</kbd> | Copy the selected commit's hash |
| <kbd>m</kbd> | Show or hide remote branches |
| <kbd>r</kbd> | Refresh |
| <kbd>Esc</kbd> | Back from an expanded commit; closes the quick look |
| <kbd>q</kbd> | Close |

### Using ⌘⇧G instead

Tern binds ⌘⇧G (Ctrl+Shift+G on Linux and Windows) to **Go to directory**, and a plugin can't take a key Tern
already uses. Your own `settings.json` can: add the quick look there, and Go to directory stays in the palette.

```json
{
	"keybinds": {
		"cmd+shift+g": "plugin.git-graph.peek"
	}
}
```

On Linux and Windows use `"ctrl+shift+g"`. Bind `plugin.git-graph.sidebar` the same way to toggle the sidebar.

## Limits

- 300 commits per page; **Show more** under the table loads the next 300.
- Lines further right than the 16th lane are cut.
- A commit page shows up to 80 files and 512 KiB of patch.

## Develop

```sh
cd ~/GitHub/tern-git-graph
tern plugin link .          # Tern reloads the plugin on every save
tern plugin types .         # tern.d.luau for luau-lsp
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau host.luau window.luau lib/*.luau
luau tests/graph_test.luau  # lane layout and parsing tests
```

| File | Role |
| --- | --- |
| `lib/graph.luau` | `git log` arguments, parsing and the lane layout (no Tern API, runs under plain `luau`) |
| `lib/view.luau` | The views: the graph page and the commit page |
| `host.luau` | The `peek` and `sidebar` blocks: reading git, keys, events, refresh hooks |
| `window.luau` | Commands, the default key and the Files pane button |
| `graph.css` | The lane drawing, scoped to the plugin's blocks and colored with theme tokens |

The graph is a column of absolutely placed pieces (lines, curves, dots) next to Tern's native table, one fixed-height
row per commit: the row height follows the table's stride (`--sf-lh` + 6px), so both stay aligned at any font size.

## License

MIT
