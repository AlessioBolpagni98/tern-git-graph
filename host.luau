--!strict
-- git-graph, host half: the `peek` and `sidebar` blocks. Both read the history of
-- the repository a terminal pane is in, lay it out in lanes and draw it beside a
-- table of commits; a double click (or Enter) shows the commit's diff in place.
--
-- Launch arguments: `pane=<id>` follows that pane's directory, `path=<dir>` pins
-- a directory. The block refreshes when the followed pane changes directory or
-- when a command finishes in any pane inside the repository.

local graph = require("./lib/graph")
local view = require("./lib/view")

local PAGE = view.PAGE
local GIT_MS = 15000 -- git timeout
local DEBOUNCE_MS = 400 -- wait after a command before re-reading
local MAX_FILES = 80 -- files shown in a commit
local MAX_PATCH = 512 * 1024 -- bytes of patch shown in a commit

type State = view.State

-- What the host keeps per running block, beside the state the view sees.
type Entry = {
	state: State,
	cx: BlockCx,
	gen: number, -- bumps on every history read; stale answers are dropped
	dgen: number, -- same, for commit reads
	pending: TimerHandle?,
}

local live: { [number]: Entry } = {}

local function running(): { [number]: boolean }
	local set = {}
	for _, p in tern.pane.list() do
		set[p.pane] = true
	end
	return set
end

local function alive(pane: number): boolean
	return running()[pane] == true
end

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

local function inside(path: string?, root: string?): boolean
	if path == nil or root == nil then
		return false
	end
	local p, r = path :: string, root :: string
	return p == r or string.sub(p, 1, #r + 1) == r .. "/"
end

local function pane_cwd(pane: number): string?
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return p.cwd
		end
	end
	return nil
end

-- Reads the repository at state.cwd: root and branch, then the log and the commit count.
local function load(e: Entry)
	local state, cx = e.state, e.cx
	e.gen += 1
	local gen = e.gen
	local function current(): boolean
		return gen == e.gen and live[cx.pane] == e and alive(cx.pane)
	end
	if state.cwd == nil then
		state.notrepo, state.loading = true, false
		state.commits, state.rows, state.root = {}, {}, nil
		cx:render()
		return
	end
	state.loading = true
	cx:render()
	local cwd = state.cwd :: string
	tern.process.run({ "git", "rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD" }, { cwd = cwd, timeout_ms = GIT_MS }, function(r)
		if not current() then
			return
		end
		if r.status ~= 0 then
			state.notrepo, state.loading, state.error = true, false, nil
			state.commits, state.rows, state.root, state.branch, state.total = {}, {}, nil, nil, nil
			cx:render()
			return
		end
		local out = string.split(trim(r.stdout), "\n")
		local root = out[1]
		state.notrepo = false
		if root ~= state.root then
			-- Another repository: forget what belonged to the last one.
			state.commits, state.rows, state.sel, state.total, state.detail = {}, {}, nil, nil, nil
		end
		state.root = root
		state.branch = if out[2] == "HEAD" then "detached" else out[2]

		local log: ProcessResult? = nil
		local count: ProcessResult? = nil
		local remotes = state.remotes
		local function both()
			if not current() or log == nil or count == nil then
				return
			end
			local l = log :: ProcessResult
			state.loading = false
			if l.status ~= 0 then
				local err = trim(l.stderr)
				-- An empty repository has no HEAD to read yet.
				if string.find(err, "does not have any commits", 1, true) or string.find(err, "unknown revision", 1, true) then
					state.error, state.commits, state.rows, state.total = nil, {}, {}, 0
				else
					state.error = if err ~= "" then err else "git log exited with " .. l.status
				end
				cx:render()
				return
			end
			state.error = nil
			state.commits = graph.parse_log(l.stdout, remotes)
			state.rows = graph.layout(state.commits)
			state.total = tonumber(trim((count :: ProcessResult).stdout))
			local keep = false
			for _, c in state.commits do
				if c.hash == state.sel then
					keep = true
					break
				end
			end
			if not keep then
				state.sel = if #state.commits > 0 then state.commits[1].hash else nil
			end
			cx:render()
		end
		tern.process.run(graph.log_argv(state.limit, remotes), { cwd = root, timeout_ms = GIT_MS }, function(lr)
			log = lr
			both()
		end)
		tern.process.run(graph.count_argv(remotes), { cwd = root, timeout_ms = GIT_MS }, function(cr)
			count = cr
			both()
		end)
	end)
end

-- Splits `git show` patch text into one entry per file.
local function split_files(patch: string): ({ view.FileDiff }, number)
	local files: { view.FileDiff } = {}
	local cut = 0
	local text = "\n" .. patch
	local starts = {}
	local at = 1
	while true do
		local s = string.find(text, "\ndiff --git ", at, true)
		if s == nil then
			break
		end
		table.insert(starts, s + 1)
		at = s + 1
	end
	local used = 0
	for i, s in starts do
		local stop = if starts[i + 1] then starts[i + 1] - 2 else #text
		local chunk = string.sub(text, s, stop)
		if #files >= MAX_FILES or used + #chunk > MAX_PATCH then
			cut += 1
			continue
		end
		used += #chunk
		local path = string.match(chunk, "\n%+%+%+ b/([^\n]+)")
			or string.match(chunk, "\n%-%-%- a/([^\n]+)")
			or string.match(chunk, "^diff %-%-git a/.- b/([^\n]+)")
			or "?"
		local binary = string.find(chunk, "\nBinary files ", 1, true) ~= nil
			or string.find(chunk, "\nGIT binary patch", 1, true) ~= nil
		table.insert(files, { path = path, text = chunk, binary = binary })
	end
	return files, cut
end

local function open_detail(e: Entry, hash: string)
	local state, cx = e.state, e.cx
	if state.root == nil then
		return
	end
	e.dgen += 1
	local gen = e.dgen
	local d: view.Detail = { hash = hash, loading = true, error = nil, body = "", files = {}, cut = 0 }
	state.detail = d
	tern.process.run({
		"git", "show", "--no-color", "--no-ext-diff", "-M", "--diff-merges=first-parent",
		"--format=%B%x1e", hash, "--",
	}, { cwd = state.root, timeout_ms = GIT_MS }, function(r)
		if gen ~= e.dgen or state.detail ~= d or not alive(cx.pane) then
			return
		end
		d.loading = false
		if r.status ~= 0 then
			d.error = trim(r.stderr)
		else
			local sep = string.find(r.stdout, "\30", 1, true)
			if sep then
				d.body = string.sub(r.stdout, 1, sep - 1)
				local patch = string.gsub(string.sub(r.stdout, sep + 1), "^%s+", "")
				d.files, d.cut = split_files(patch)
			else
				d.body = r.stdout
			end
		end
		cx:render()
	end)
end

local function selected_commit(state: State): graph.Commit?
	for _, c in state.commits do
		if c.hash == state.sel then
			return c
		end
	end
	return nil
end

local function find_commit(state: State, hash: string?): graph.Commit?
	for _, c in state.commits do
		if c.hash == hash then
			return c
		end
	end
	return nil
end

local function copy_hash(cx: BlockCx, c: graph.Commit?)
	if c then
		cx:copy(c.hash)
		cx:toast("success", "Copied " .. string.sub(c.hash, 1, 7))
	end
end

local function move(state: State, step: number)
	local n = #state.commits
	if n == 0 then
		return
	end
	local at = 1
	for i, c in state.commits do
		if c.hash == state.sel then
			at = i
			break
		end
	end
	at = math.clamp(at + step, 1, n)
	state.sel = state.commits[at].hash
end

local function close(e: Entry)
	live[e.cx.pane] = nil
	if e.pending then
		(e.pending :: TimerHandle):cancel()
	end
	e.cx:exit(0)
end

-- Re-reads soon, folding a burst of finished commands into one read.
local function schedule(e: Entry)
	if e.pending then
		(e.pending :: TimerHandle):cancel()
	end
	e.pending = tern.timer(DEBOUNCE_MS, function()
		e.pending = nil
		if live[e.cx.pane] == e and alive(e.cx.pane) then
			load(e)
		end
	end)
end

local function define(id: string, peek: boolean)
	local def: BlockDef<State> = {
		font = "sans",

		init = function(cx, args, saved)
			local source: number? = nil
			local path: string? = nil
			for _, a in args do
				local k, v = string.match(a, "^(%w+)=(.*)$")
				if k == "pane" then
					source = tonumber(v)
				elseif k == "path" and v ~= "" then
					path = v
				end
			end
			local remotes = true
			local limit = PAGE
			if type(saved) == "table" then
				source = if type(saved.source) == "number" then saved.source else source
				path = if type(saved.cwd) == "string" then saved.cwd else path
				remotes = saved.remotes ~= false
				limit = if type(saved.limit) == "number" then saved.limit else PAGE
			end
			local cwd = path
			if source and cwd == nil then
				cwd = pane_cwd(source :: number)
			end
			if cwd == nil then
				cwd = cx.cwd
			end
			local state: State = {
				peek = peek,
				source = source,
				cwd = cwd,
				root = nil,
				branch = nil,
				remotes = remotes,
				limit = limit,
				commits = {},
				rows = {},
				total = nil,
				loading = true,
				error = nil,
				notrepo = false,
				sel = nil,
				detail = nil,
			}
			local e: Entry = { state = state, cx = cx, gen = 0, dgen = 0, pending = nil }
			live[cx.pane] = e
			load(e)
			return state
		end,

		title = function(state)
			if state.root then
				return "Git Graph · " .. (string.match(state.root :: string, "([^/]+)$") or "")
			end
			return "Git Graph"
		end,

		view = function(state, _cx)
			return view.render(state)
		end,

		key = function(state, key, cx)
			local e = live[cx.pane]
			if e == nil then
				return false
			end
			local n = key.name
			if state.detail then
				if n == "escape" or n == "backspace" or n == "left" or n == "h" then
					state.detail = nil
					return true
				elseif n == "c" then
					copy_hash(cx, find_commit(state, (state.detail :: view.Detail).hash))
					return false
				end
				return false
			end
			if n == "down" or n == "j" then
				move(state, 1)
			elseif n == "up" or n == "k" then
				move(state, -1)
			elseif n == "page_down" then
				move(state, 20)
			elseif n == "page_up" then
				move(state, -20)
			elseif n == "home" or key.text == "g" then
				move(state, -#state.commits)
			elseif n == "end" or key.text == "G" then
				move(state, #state.commits)
			elseif n == "enter" or n == "right" or n == "l" then
				if state.sel then
					open_detail(e, state.sel :: string)
				end
			elseif n == "c" then
				copy_hash(cx, selected_commit(state))
				return false
			elseif n == "m" then
				state.remotes = not state.remotes
				load(e)
			elseif n == "r" then
				load(e)
			elseif n == "q" or (n == "escape" and state.peek) then
				close(e)
			else
				return false
			end
			return true
		end,

		event = function(state, ev, cx)
			local e = live[cx.pane]
			if e == nil then
				return
			end
			if ev.ev == "select" and type(ev.item) == "string" then
				state.sel = ev.item
			elseif ev.ev == "activate" and type(ev.item) == "string" then
				state.sel = ev.item
				open_detail(e, ev.item)
			elseif ev.ev == "action" then
				local act = ev.act
				local item: string? = if type(ev.item) == "string" then ev.item else nil
				if act == "remotes" then
					state.remotes = not state.remotes
					load(e)
				elseif act == "refresh" then
					load(e)
				elseif act == "more" then
					state.limit += PAGE
					load(e)
				elseif act == "back" then
					state.detail = nil
				elseif act == "show-diff" and item then
					state.sel = item
					open_detail(e, item :: string)
				elseif act == "copy-hash" then
					copy_hash(cx, find_commit(state, item))
				elseif act == "copy-subject" then
					local c = find_commit(state, item)
					if c then
						cx:copy(c.subject)
						cx:toast("success", "Copied subject")
					end
				end
			end
		end,

		save = function(state)
			return {
				source = if state.source then state.source else tern.json.null,
				-- A pinned directory survives restarts; a followed pane's directory is read again.
				cwd = if state.source then tern.json.null else state.cwd,
				remotes = state.remotes,
				limit = state.limit,
			}
		end,
	}
	tern.block.define(id, def)
end

define("peek", true)
define("sidebar", false)

-- Follow the source pane into other directories.
tern.on("cwd", function(ev)
	for pane, e in live do
		local state = e.state
		if state.source == ev.pane and ev.path ~= state.cwd then
			state.cwd = ev.path
			if not inside(ev.path, state.root) then
				schedule(e)
			end
		end
	end
end)

-- A finished command may have committed, checked out, fetched or rebased.
tern.on("command_finished", function(ev)
	local up = running()
	local where = pane_cwd(ev.pane)
	for pane, e in live do
		if not up[pane] then
			live[pane] = nil
		elseif e.state.source == ev.pane or inside(where, e.state.root) then
			schedule(e)
		end
	end
end)
