--!strict
-- Builds the block's view from its state: the graph page and the commit page.

local graph = require("./graph")

local ui = tern.ui

local M = {}

-- Lanes drawn; lines further right are cut (graph.css has a class per lane).
M.MAX_LANES = 16

export type FileDiff = { path: string, text: string, binary: boolean }

export type Detail = {
	hash: string,
	loading: boolean,
	error: string?,
	body: string,
	files: { FileDiff },
	cut: number, -- files left out past the cap
}

export type State = {
	peek: boolean,
	source: number?,
	cwd: string?,
	root: string?,
	branch: string?,
	remotes: boolean,
	limit: number,
	commits: { graph.Commit },
	rows: { graph.Row },
	total: number?,
	loading: boolean,
	error: string?,
	notrepo: boolean,
	sel: string?,
	detail: Detail?,
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

local function subject_cell(c: graph.Commit): { Span }
	local spans: { Span } = {}
	for _, r in c.refs do
		local s = REF_TOKENS[r.kind]
		if r.current then
			s = REF_TOKENS.head
		end
		table.insert(spans, ui.span(r.name, s))
		table.insert(spans, ui.span(" "))
	end
	table.insert(spans, ui.span(c.subject))
	return spans
end

local function tooltip(c: graph.Commit): string
	local parents = {}
	for _, p in c.parents do
		table.insert(parents, short(p))
	end
	local lines = {
		c.subject,
		"",
		short(c.hash) .. "  " .. full_date(c.time),
		c.author .. " <" .. c.email .. ">",
	}
	if #parents > 0 then
		table.insert(lines, "Parents: " .. table.concat(parents, ", "))
	end
	return table.concat(lines, "\n")
end

-- One row of the graph column: absolutely placed pieces (graph.css).
local function graph_row(c: graph.Commit, row: graph.Row, head: string?): Node
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
	return ui.el("div", { key = c.hash, class = "gg-row" }, pieces)
end

local function head_row(state: State): Node
	local name = if state.root then basename(state.root :: string) else "Git Graph"
	local meta = if state.branch then "  " .. (state.branch :: string) else ""
	return ui.node("row", { key = "head", justify = "between", align = "center", gap = "sm" }, {
		ui.node("text", {
			key = "title",
			spans = { ui.span(name, "title"), ui.span(meta, "muted mono") },
			truncate = "end",
			grow = 1,
			shrink = 1,
			basis = 0,
		}),
		ui.node("row", { key = "end", gap = "sm", align = "center", shrink = 0 }, {
			ui.button(nil, {
				key = "remotes",
				icon = "globe",
				on = state.remotes,
				title = if state.remotes then "Hide remote branches" else "Show remote branches",
				aria = "Remote branches",
				actions = { click = "remotes" },
			}),
			ui.button(nil, {
				key = "refresh",
				icon = "repeat",
				busy = state.loading,
				title = "Refresh",
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

local function graph_body(state: State): Node
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
			return ui.node("shimmer", { key = "body", text = "Reading history…" })
		end
		return ui.node("empty", { key = "body", icon = "branch", title = "No commits yet" })
	end

	local head: string? = nil
	local width = 1
	local lines: { Node } = {}
	local trows = {}
	for i, c in state.commits do
		local row = state.rows[i]
		for _, r in c.refs do
			if r.current then
				head = c.hash
			end
		end
		width = math.max(width, row.width)
		table.insert(lines, graph_row(c, row, nil))
		table.insert(trows, {
			id = c.hash,
			cells = {
				subject = subject_cell(c),
				date = M.when(c.time, os.time()),
				author = c.author,
			},
			title = tooltip(c),
			menu = { "show-diff", "copy-hash", "copy-subject" },
		})
	end
	-- Mark HEAD's dot now that it is known.
	if head then
		for i, c in state.commits do
			if c.hash == head then
				lines[i] = graph_row(c, state.rows[i], head)
				break
			end
		end
	end
	width = math.min(width, M.MAX_LANES)

	-- The table hides columns lowest priority first when the pane is narrow.
	local tcols: { { [string]: any } } = {
		{ id = "subject", grow = 1, priority = 9 },
		{ id = "date", mono = true, align = "end", priority = 5 },
		{ id = "author", priority = 3 },
	}

	local list: { Node } = {
		ui.node("row", { key = "grid", align = "start", gap = "none" }, {
			ui.el("div", { key = "graph", class = "gg-graph gg-n" .. width }, lines),
			ui.node("col", { key = "list", grow = 1, basis = 0 }, {
				ui.node("table", {
					key = "table",
					cols = tcols,
					rows = trows,
					selectable = true,
					selected = state.sel,
				}),
			}),
		}),
	}
	if state.total and (state.total :: number) > #state.commits then
		table.insert(list, ui.node("pager", {
			key = "more",
			variant = "more",
			page = 1,
			size = #state.commits,
			total = state.total,
			loading = state.loading,
			label = "commits",
		}))
	end
	return ui.node("scroll", { key = "body", grow = 1, basis = 0, role = "git-graph.body" }, list)
end

local function find(state: State, hash: string): graph.Commit?
	for _, c in state.commits do
		if c.hash == hash then
			return c
		end
	end
	return nil
end

local function detail_page(state: State, d: Detail): BlockView
	local c = find(state, d.hash)
	local subject = if c then c.subject else short(d.hash)
	local head = ui.node("row", { key = "head", align = "center", gap = "sm" }, {
		ui.button("Graph", { key = "back", icon = "back", keys = { "esc" }, actions = { click = "back" } }),
		ui.node("text", { key = "title", spans = { ui.span(subject, "title") }, truncate = "end", grow = 1 }),
	})
	local facts: { Node } = {}
	if c then
		local parents = {}
		for _, p in c.parents do
			table.insert(parents, short(p))
		end
		table.insert(facts, ui.kv({
			{ "Commit", { ui.span(short(d.hash), "mono") } },
			{ "Author", c.author .. " <" .. c.email .. ">" },
			{ "Date", { ui.span(full_date(c.time), "mono") } },
			{ "Parents", { ui.span(if #parents > 0 then table.concat(parents, " ") else "none", "mono") } },
		}))
	end
	local body: { Node } = {}
	if d.loading then
		table.insert(body, ui.node("shimmer", { key = "loading", text = "Reading commit…" }))
	elseif d.error then
		table.insert(body, ui.card("Couldn't read the commit", { ui.code(d.error :: string) }, { key = "error", tone = "error", icon = "commit" }))
	else
		local msg = string.gsub(d.body, "^%s+", "")
		local rest = string.match(msg, "^[^\n]*\n+(.*)$")
		if rest and rest ~= "" then
			table.insert(body, ui.node("text", { key = "message", spans = { ui.span(rest, "muted") }, wrap = "word" }))
		end
		if #d.files == 0 then
			table.insert(body, ui.node("empty", { key = "nofiles", variant = "inline", icon = "file", title = "No file changes" }))
		end
		for i, f in d.files do
			local inner: Node = if f.binary
				then ui.text({ ui.span("Binary file", "muted") })
				else ui.diff(f.text, f.path)
			local card = ui.card(f.path, { inner }, { key = "f" .. i, icon = "file", collapsible = true })
			table.insert(body, card)
		end
		if d.cut > 0 then
			table.insert(body, ui.text({ ui.span(string.format("%d more files not shown", d.cut), "muted") }))
		end
	end
	local children: { Node } = { head }
	for _, f in facts do
		table.insert(children, f)
	end
	table.insert(children, ui.node("scroll", { key = "body", grow = 1, basis = 0, gap = "sm" }, body))
	return {
		main = ui.node("col", { gap = "md", key = "detail" }, children),
		dock = legend({ { "esc", "graph" }, { "c", "copy hash" } }),
	}
end

function M.render(state: State): BlockView
	local d = state.detail
	if d then
		return detail_page(state, d)
	end
	local keys = { { "↑↓", "select" }, { "↵", "diff" }, { "c", "copy hash" }, { "m", "remotes" }, { "r", "refresh" } }
	table.insert(keys, { if state.peek then "esc" else "q", "close" })
	return {
		main = ui.node("col", { gap = "md", key = "graph-page" }, { head_row(state), graph_body(state) }),
		dock = legend(keys),
	}
end

return M
