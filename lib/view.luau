--!strict
-- Builds the block's view from its state: the graph beside (or above) the selected
-- commit's details, or the commit alone when it is expanded.

local graph = require("./graph")

local ui = tern.ui

local M = {}

-- Lanes drawn; lines further right are cut (graph.css has a class per lane).
M.MAX_LANES = 16
-- Commits loaded per page.
M.PAGE = 300
-- Pane width in cells from which the details sit beside the graph instead of under it.
M.WIDE = 110
-- Files shown open in the details pane; the rest start folded.
M.OPEN_FILES = 3

export type FileDiff = { path: string, text: string, binary: boolean, adds: number?, dels: number? }

export type Detail = {
	hash: string,
	loading: boolean,
	error: string?,
	body: string,
	files: { FileDiff },
	cut: number, -- files left out past the cap
	adds: number, -- lines added and removed, over every file (cut ones too)
	dels: number,
}

export type Upstream = { name: string, ahead: number, behind: number }

export type State = {
	peek: boolean,
	source: number?,
	cwd: string?,
	root: string?,
	branch: string?,
	upstream: Upstream?,
	remotes: boolean,
	limit: number,
	commits: { graph.Commit },
	rows: { graph.Row },
	total: number?,
	loading: boolean,
	error: string?,
	notrepo: boolean,
	sel: string?,
	detail: Detail?, -- the selected commit's
	zoom: boolean, -- the details fill the block
}

local function basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

local function short(hash: string): string
	return string.sub(hash, 1, 7)
end

-- "5m", "3h", "2d" within a week, then "19 Nov", then "19 Nov 2024".
function M.when(t: number, now: number): string
	local ago = now - t
	if ago < 60 then
		return "now"
	elseif ago < 3600 then
		return string.format("%dm", ago // 60)
	elseif ago < 86400 then
		return string.format("%dh", ago // 3600)
	elseif ago < 7 * 86400 then
		return string.format("%dd", ago // 86400)
	end
	local day = os.date("*t", t)
	local today = os.date("*t", now)
	local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
	local s = string.format("%d %s", day.day, months[day.month])
	if day.year ~= today.year then
		s ..= " " .. day.year
	end
	return s
end

local function full_date(t: number): string
	return os.date("%Y-%m-%d %H:%M", t) :: string
end

local REF_TOKENS = {
	head = "code accent strong",
	["local"] = "code success",
	remote = "code info",
	tag = "code warning",
}

local function ref_spans(c: graph.Commit): { Span }
	local spans: { Span } = {}
	for _, r in c.refs do
		table.insert(spans, ui.span(r.name, if r.current then REF_TOKENS.head else REF_TOKENS[r.kind]))
		table.insert(spans, ui.span(" "))
	end
	return spans
end

local function subject_cell(c: graph.Commit): { Span }
	local spans = ref_spans(c)
	table.insert(spans, ui.span(c.subject))
	return spans
end

-- One row of the graph column: absolutely placed pieces (graph.css).
local function graph_row(c: graph.Commit, row: graph.Row, head: string?, sel: string?): Node
	local pieces: { Node } = {}
	for i, s in row.segs do
		local cls: string
		if s.kind == "join" or s.kind == "fork" then
			local lo, hi = math.min(s.a, s.b), math.max(s.a, s.b)
			if hi >= M.MAX_LANES then
				continue
			end
			local right = if s.kind == "join" then s.a > s.b else s.b > s.a
			cls = string.format("gg-s gg-%s gg-x%d gg-d%d gg-%s gg-c%d", s.kind, lo, hi - lo, if right then "r" else "l", s.color)
		else
			if s.a >= M.MAX_LANES then
				continue
			end
			cls = string.format("gg-s gg-%s gg-x%d gg-c%d", s.kind, s.a, s.color)
			if s.kind == "dot" then
				if c.hash == head then
					cls ..= " gg-head"
				elseif #c.parents > 1 then
					cls ..= " gg-merge"
				end
			end
		end
		table.insert(pieces, ui.el("span", { key = tostring(i), class = cls }))
	end
	local cls = if c.hash == sel then "gg-row gg-sel" else "gg-row"
	return ui.el("div", { key = c.hash, class = cls }, pieces)
end

local function with_title(node: Node, title: string): Node
	local p: { [string]: any } = node.p or {}
	p.title = title
	node.p = p
	return node
end

local function head_row(state: State): Node
	local name = if state.root then basename(state.root :: string) else "Git Graph"
	local left: { Node } = { ui.text({ ui.span(name, "title") }) }
	if state.branch then
		table.insert(left, ui.badge(state.branch :: string, if state.branch == "detached" then "warning" else "accent"))
	end
	local up = state.upstream
	if up then
		local u = up :: Upstream
		if u.ahead > 0 then
			table.insert(left, with_title(ui.badge("↑" .. u.ahead, "info"), u.ahead .. " to push to " .. u.name))
		end
		if u.behind > 0 then
			table.insert(left, with_title(ui.badge("↓" .. u.behind, "warning"), u.behind .. " to pull from " .. u.name))
		end
	end
	if state.total then
		table.insert(left, ui.text({ ui.span(string.format("%d commits", state.total :: number), "muted") }))
	end
	return ui.node("row", { key = "head", justify = "between", align = "center", gap = "sm" }, {
		ui.node("row", { key = "id", gap = "sm", align = "center", wrap = true, grow = 1, shrink = 1, basis = 0 }, left),
		ui.node("row", { key = "end", gap = "sm", align = "center", shrink = 0 }, {
			ui.button(nil, {
				key = "remotes",
				icon = "globe",
				on = state.remotes,
				title = if state.remotes then "Hide remote branches (m)" else "Show remote branches (m)",
				aria = "Remote branches",
				actions = { click = "remotes" },
			}),
			ui.button(nil, {
				key = "refresh",
				icon = "repeat",
				busy = state.loading,
				title = "Refresh (r)",
				aria = "Refresh",
				actions = { click = "refresh" },
			}),
		}),
	})
end

local function legend(items: { { string } }): Node
	local spans: { Span } = {}
	for i, it in items do
		if i > 1 then
			table.insert(spans, ui.span("   "))
		end
		table.insert(spans, ui.span(it[1], "key"))
		table.insert(spans, ui.span(" " .. it[2], "muted"))
	end
	return ui.col({ ui.text(spans) })
end

local function find(state: State, hash: string?): graph.Commit?
	for _, c in state.commits do
		if c.hash == hash then
			return c
		end
	end
	return nil
end

-- The graph column beside the commit table, and the pager under them.
local function history(state: State): Node
	local head: string? = nil
	for _, c in state.commits do
		for _, r in c.refs do
			if r.current then
				head = c.hash
			end
		end
	end
	local width = 1
	local lines: { Node } = {}
	local trows = {}
	local now = os.time()
	for i, c in state.commits do
		local row = state.rows[i]
		width = math.max(width, row.width)
		table.insert(lines, graph_row(c, row, head, state.sel))
		table.insert(trows, {
			id = c.hash,
			cells = {
				subject = subject_cell(c),
				date = M.when(c.time, now),
				author = c.author,
			},
			title = c.subject,
			menu = { "show-diff", "copy-hash", "copy-subject" },
		})
	end
	width = math.min(width, M.MAX_LANES)

	-- The table hides columns lowest priority first when the pane is narrow.
	local tcols: { { [string]: any } } = {
		{ id = "subject", grow = 1, priority = 9 },
		{ id = "date", mono = true, align = "end", priority = 5 },
		{ id = "author", priority = 3 },
	}
	local children: { Node } = {
		ui.node("row", { key = "grid", align = "start", gap = "none" }, {
			ui.el("div", { key = "graph", class = "gg-graph gg-n" .. width }, lines),
			ui.node("col", { key = "list", grow = 1, basis = 0 }, {
				ui.node("table", { key = "table", cols = tcols, rows = trows, selectable = true, selected = state.sel }),
			}),
		}),
	}
	if state.total and (state.total :: number) > #state.commits then
		table.insert(children, ui.node("pager", {
			key = "more",
			variant = "more",
			page = state.limit // M.PAGE,
			size = M.PAGE,
			total = state.total,
			loading = state.loading,
			label = "commits",
		}))
	end
	return ui.node("col", { key = "history", gap = "sm" }, children)
end

-- What the selected commit is and changed. `zoomed` opens every file.
local function commit_view(state: State, d: Detail?, zoomed: boolean): { Node }
	local c = find(state, if d then d.hash else state.sel)
	if c == nil then
		return { ui.node("empty", { key = "none", icon = "commit", title = "No commit selected" }) }
	end
	local cm = c :: graph.Commit
	local out: { Node } = {}

	-- Who and when, beside the author's mark.
	local who = ui.node("row", { key = "who", gap = "sm", align = "center" }, {
		ui.node("avatar", { key = "avatar", text = cm.author, seed = cm.email, size = "sm", title = cm.author .. " <" .. cm.email .. ">" }),
		ui.node("text", {
			key = "meta",
			spans = {
				ui.span(cm.author, "strong"),
				ui.span("  " .. M.when(cm.time, os.time()), "muted"),
			},
			title = full_date(cm.time),
			truncate = "end",
			grow = 1,
			basis = 0,
		}),
		ui.button(nil, {
			key = "zoom",
			size = "sm",
			icon = if zoomed then "back" else "expand",
			title = if zoomed then "Back to the graph (esc)" else "Expand (enter)",
			aria = if zoomed then "Back" else "Expand",
			actions = { click = if zoomed then "back" else "zoom" },
		}),
	})
	table.insert(out, who)
	table.insert(out, ui.node("text", { key = "subject", spans = { ui.span(cm.subject, "title") }, wrap = "word" }))

	-- Hash, refs and parents.
	local ids: { Span } = { ui.span(short(cm.hash), "code"), ui.span("  ") }
	for _, s in ref_spans(cm) do
		table.insert(ids, s)
	end
	if #cm.parents > 0 then
		local parents = {}
		for _, p in cm.parents do
			table.insert(parents, short(p))
		end
		table.insert(ids, ui.span((if #cm.parents > 1 then " merge of " else " parent ") .. table.concat(parents, " + "), "muted mono"))
	end
	table.insert(out, ui.node("text", { key = "ids", spans = ids, wrap = "word" }))

	if d == nil or (d :: Detail).loading then
		table.insert(out, ui.node("skeleton", { key = "files", shape = "rows", rows = 4 }))
		return out
	end
	local det = d :: Detail
	if det.error then
		table.insert(out, ui.card("Couldn't read the commit", { ui.code(det.error :: string) }, { key = "files", tone = "error", icon = "commit" }))
		return out
	end

	local msg = string.gsub(det.body, "^%s+", "")
	local rest = string.match(msg, "^[^\n]*\n+(.-)%s*$")
	if rest and rest ~= "" then
		table.insert(out, ui.node("text", { key = "message", spans = { ui.span(rest, "muted") }, wrap = "word" }))
	end

	-- Files: a summary line, then one folding card per file.
	local nfiles = #det.files + det.cut
	local adds, dels = det.adds, det.dels
	table.insert(out, ui.node("text", {
		key = "stat",
		spans = {
			ui.span(string.format("%d file%s changed  ", nfiles, if nfiles == 1 then "" else "s"), "strong"),
			ui.span("+" .. adds, "ins"),
			ui.span("  "),
			ui.span("−" .. dels, "del"),
		},
	}))
	if #det.files == 0 then
		table.insert(out, ui.node("empty", { key = "nofiles", variant = "inline", icon = "file", title = "No file changes" }))
	end
	for i, f in det.files do
		local inner: Node = if f.binary
			then ui.text({ ui.span("Binary file", "muted") })
			else ui.diff(f.text, f.path)
		local meta: { Span } = {}
		if f.adds or f.dels then
			meta = { ui.span("+" .. (f.adds or 0), "ins"), ui.span(" "), ui.span("−" .. (f.dels or 0), "del") }
		end
		table.insert(out, ui.card(f.path, { inner }, {
			-- Keyed per commit, so a card the user opened doesn't stay open on the next commit.
			key = "f" .. i .. "-" .. short(det.hash),
			icon = "file",
			meta = meta,
			collapsible = true,
			collapsed = not zoomed and i > M.OPEN_FILES,
		}))
	end
	if det.cut > 0 then
		table.insert(out, ui.text({ ui.span(string.format("%d more files not shown", det.cut), "muted") }))
	end
	return out
end

local function body(state: State): Node?
	if state.notrepo then
		return ui.node("empty", {
			key = "body",
			icon = "branch",
			title = "Not a git repository",
			text = state.cwd or "The pane has no working directory",
		})
	end
	if state.error then
		return ui.card("Couldn't read the history", {
			ui.button("Retry", { key = "end", icon = "repeat", keys = { "r" }, actions = { click = "refresh" } }),
			ui.code(state.error :: string),
		}, { key = "body", icon = "branch", tone = "error", ["end"] = "main.body.end" })
	end
	if #state.commits == 0 then
		if state.loading then
			return ui.node("skeleton", { key = "body", shape = "rows", rows = 8 })
		end
		return ui.node("empty", { key = "body", icon = "commit", title = "No commits yet" })
	end
	return nil
end

function M.render(state: State, cols: number): BlockView
	local special = body(state)
	if special then
		return {
			main = ui.node("col", { gap = "md", key = "page" }, { head_row(state), special :: Node }),
			dock = legend({ { "r", "refresh" }, { if state.peek then "esc" else "q", "close" } }),
		}
	end

	if state.zoom then
		return {
			main = ui.node("col", { gap = "md", key = "zoom" }, commit_view(state, state.detail, true)),
			dock = legend({ { "esc", "back" }, { "c", "copy hash" } }),
		}
	end

	local wide = cols >= M.WIDE
	local split = ui.node("split", {
		key = if wide then "split-row" else "split-col",
		dir = if wide then "row" else "col",
		-- Tern keeps the user's drag by key; a double click on the handle goes back to these.
		sizes = if wide then { 0.6, 0.4 } else { 0.55, 0.45 },
		min = { if wide then "40ch" else "6lines", if wide then "36ch" else "6lines" },
		grow = 1,
	}, {
		history(state),
		ui.node("col", { key = "commit", gap = "md" }, commit_view(state, state.detail, false)),
	})
	local keys = { { "↑↓", "select" }, { "↵", "expand" } }
	if wide then
		table.insert(keys, { "c", "copy hash" })
		table.insert(keys, { "m", "remotes" })
		table.insert(keys, { "r", "refresh" })
	end
	table.insert(keys, { if state.peek then "esc" else "q", "close" })
	return {
		main = ui.node("col", { gap = "md", key = "page" }, { head_row(state), split }),
		dock = legend(keys),
	}
end

return M
