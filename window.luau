--!strict
-- git-graph, window half: opens the graph as a quick look floating over the
-- focused pane, or as a sidebar on its left, and adds a Files pane button.
-- Both commands toggle: run again to close.

local PEEK = "git-graph.peek"
local SIDEBAR = "git-graph.sidebar"
local DEFAULT_SHARE = 0.25
local PEEK_SIZE = { 0.6, 0.85 } -- share of the pane it floats over

-- The open block of `kind` in the window's current tab, if any.
local function open_block(cx: WindowCx, kind: string): number?
	local focused = cx.session:focused()
	local tab = if focused then cx.session:tab_of(focused) else nil
	for _, p in cx.session:panes() do
		if p.block == kind and not p.parked and (tab == nil or p.tab == tab) then
			return p.pane
		end
	end
	return nil
end

-- Launch arguments: follow the focused terminal, else pin its directory.
local function source_args(cx: WindowCx, pane: PaneInfo?): { string }
	if pane == nil then
		return {}
	end
	local p = pane :: PaneInfo
	if p.kind == "terminal" or p.kind == "agent" then
		return { "pane=" .. p.pane }
	end
	if p.cwd and p.cwd ~= "" then
		return { "path=" .. p.cwd }
	end
	return {}
end

local function focused_pane(cx: WindowCx): PaneInfo?
	local id = cx.session:focused()
	if id == nil then
		return nil
	end
	return cx.session:pane(id)
end

-- The share of its split the sidebar has now: a left sidebar is its split's first child.
local function sidebar_share(cx: WindowCx, pane: number): number?
	local tab = cx.session:tab_of(pane)
	local layout = if tab then cx.session:layout(tab) else nil
	if layout == nil then
		return nil
	end
	local function walk(t: TabTree): number?
		local first = t[1]
		if first then
			if first.pane == pane and t.ratio then
				return t.ratio
			end
			local found = walk(first)
			if found then
				return found
			end
		end
		local second = t[2]
		if second then
			return walk(second)
		end
		return nil
	end
	return walk((layout :: TabLayout).root)
end

local function toggle_peek(cx: WindowCx)
	local open = open_block(cx, PEEK)
	if open then
		cx.layout:close(open)
		return
	end
	local here = focused_pane(cx)
	local pane = cx:new_block(PEEK, source_args(cx, here), "beside")
	if pane == nil then
		cx:toast("error", "Git Graph isn't ready on this host")
		return
	end
	local ok, err = cx.layout:float(pane, if here then here.pane else nil, "tr", { focus = true, size = PEEK_SIZE })
	if not ok then
		tern.log.warn("git-graph: float failed", err)
	end
	-- Keys go to the quick look: Esc closes it, arrows move through commits.
	cx.layout:focus(pane)
end

local function toggle_sidebar(cx: WindowCx, args: { string }?)
	local open = open_block(cx, SIDEBAR)
	if open then
		local share = sidebar_share(cx, open)
		if share then
			tern.kv.set("sidebar_share", share)
		end
		cx.layout:close(open)
		return
	end
	local here = focused_pane(cx)
	local share = tern.kv.get("sidebar_share")
	local pane = cx:new_block(SIDEBAR, args or source_args(cx, here), "default", {
		target = if here and not here.floating then here.pane else nil,
		dir = "left",
		ratio = if type(share) == "number" and share > 0 and share < 1 then share else DEFAULT_SHARE,
		focus = false,
	})
	if pane == nil then
		cx:toast("error", "Git Graph isn't ready on this host")
	end
end

tern.command({
	id = "peek",
	title = "Git Graph: Quick look",
	icon = "branch",
	group = "Git Graph",
	keys = { "ctrl+alt+g" },
	run = toggle_peek,
})

tern.command({
	id = "sidebar",
	title = "Git Graph: Toggle sidebar",
	icon = "branch",
	group = "Git Graph",
	run = function(cx)
		toggle_sidebar(cx, nil)
	end,
})

tern.files.button({
	id = "graph",
	title = "Git Graph sidebar",
	icon = "branch",
	run = function(files, cx)
		local args = if files.root then { "path=" .. (files.root :: string) } else nil
		toggle_sidebar(cx, args)
	end,
})
