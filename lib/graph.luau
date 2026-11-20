--!strict
-- Pure helpers: the `git log` command line, parsing its output into commits,
-- and laying the commits out in lanes. No `tern` API here, so the module runs
-- under the standalone `luau` CLI for tests (`luau tests/graph_test.luau`).

local M = {}

local FS = "\31" -- field separator (%x1f)
local RS = "\30" -- record separator (%x1e)

-- One decoration on a commit.
export type Ref = {
	name: string, -- short name as drawn: `main`, `origin/main`, `v1.2`
	kind: "head" | "local" | "remote" | "tag",
	current: boolean, -- the branch HEAD points at (or HEAD itself when detached)
}

export type Commit = {
	hash: string,
	parents: { string },
	refs: { Ref },
	author: string,
	email: string,
	time: number, -- author date, unix seconds
	subject: string,
}

-- A piece of the graph in one row. Lanes are 0-based columns.
-- v: full-height line in lane `a`; top/bottom: the upper or lower half of lane `a`;
-- dot: the commit in lane `a`; join: a curve from the top of lane `a` into the
-- dot in lane `b`; fork: a curve from the dot in lane `a` down to the bottom of lane `b`.
export type Seg = {
	kind: "v" | "top" | "bottom" | "dot" | "join" | "fork",
	a: number,
	b: number,
	color: number,
}

export type Row = {
	lane: number, -- the commit's lane
	color: number,
	segs: { Seg },
	width: number, -- lanes this row draws into (max lane + 1)
}

-- Lane colors cycle through this many classes (`gg-c0` … in graph.css).
M.COLORS = 8

-- argv for `git log`: every local branch and tag plus HEAD, remotes when asked.
function M.log_argv(limit: number, remotes: boolean): { string }
	local argv = {
		"git",
		"-c", "log.showSignature=false",
		"log",
		"--date-order",
		"--decorate=full",
		"--no-color",
		"--format=" .. RS .. "%H" .. FS .. "%P" .. FS .. "%D" .. FS .. "%an" .. FS .. "%ae" .. FS .. "%at" .. FS .. "%s",
		"-n", tostring(limit),
		"--branches",
		"--tags",
	}
	if remotes then
		table.insert(argv, "--remotes")
	end
	table.insert(argv, "HEAD")
	table.insert(argv, "--")
	return argv
end

-- argv counting the commits the same refs reach.
function M.count_argv(remotes: boolean): { string }
	local argv = { "git", "rev-list", "--count", "--branches", "--tags" }
	if remotes then
		table.insert(argv, "--remotes")
	end
	table.insert(argv, "HEAD")
	table.insert(argv, "--")
	return argv
end

local function split(s: string, sep: string): { string }
	local out = {}
	local start = 1
	while true do
		local at = string.find(s, sep, start, true)
		if at == nil then
			table.insert(out, string.sub(s, start))
			return out
		end
		table.insert(out, string.sub(s, start, at - 1))
		start = at + #sep
	end
end

-- Parses `%D` under `--decorate=full`: `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1`.
function M.parse_refs(decor: string, remotes: boolean): { Ref }
	local refs: { Ref } = {}
	if decor == "" then
		return refs
	end
	local head_branch: string? = nil
	local detached = false
	for _, raw in split(decor, ", ") do
		local item = raw
		if string.sub(item, 1, 8) == "HEAD -> " then
			item = string.sub(item, 9)
			head_branch = item
		elseif item == "HEAD" then
			detached = true
			item = ""
		end
		if string.sub(item, 1, 5) == "tag: " then
			local name = string.gsub(string.sub(item, 6), "^refs/tags/", "")
			table.insert(refs, { name = name, kind = "tag", current = false })
		elseif string.sub(item, 1, 11) == "refs/heads/" then
			table.insert(refs, { name = string.sub(item, 12), kind = "local", current = item == head_branch })
		elseif string.sub(item, 1, 13) == "refs/remotes/" then
			local name = string.sub(item, 14)
			-- `origin/HEAD` only repeats what the remote's default branch says.
			if remotes and string.sub(name, -5) ~= "/HEAD" then
				table.insert(refs, { name = name, kind = "remote", current = false })
			end
		end
	end
	if detached then
		local head: Ref = { name = "HEAD", kind = "head", current = true }
		table.insert(refs, 1, head)
	end
	-- The checked-out branch first, then local branches, remotes, tags.
	local order = { head = 0, ["local"] = 1, remote = 2, tag = 3 }
	table.sort(refs, function(x: Ref, y: Ref): boolean
		if x.current ~= y.current then
			return x.current
		end
		if x.kind ~= y.kind then
			return order[x.kind] < order[y.kind]
		end
		return x.name < y.name
	end)
	return refs
end

-- Parses the output of `log_argv`.
function M.parse_log(out: string, remotes: boolean): { Commit }
	local commits: { Commit } = {}
	for _, record in split(out, RS) do
		local rec = string.gsub(record, "\n+$", "")
		if rec ~= "" then
			local f = split(rec, FS)
			if #f >= 7 then
				local parents = {}
				for p in string.gmatch(f[2], "%x+") do
					table.insert(parents, p)
				end
				-- A subject may hold the separator only if a commit message does; keep the rest.
				local subject = table.concat(f, FS, 7)
				table.insert(commits, {
					hash = f[1],
					parents = parents,
					refs = M.parse_refs(f[3], remotes),
					author = f[4],
					email = f[5],
					time = tonumber(f[6]) or 0,
					subject = subject,
				})
			end
		end
	end
	return commits
end

-- Lays `commits` (children before parents, as `git log` prints them) out in lanes.
-- A lane keeps its column for as long as it runs, so lines never shift sideways;
-- a freed column is reused by the next new line. Each line keeps one color.
function M.layout(commits: { Commit }): { Row }
	-- lanes[i] (1-based here, 0-based in segs) = the hash the line in column i waits for.
	local lanes: { string | false } = {}
	local colors: { number } = {}
	local next_color = 0
	local rows: { Row } = {}

	local function free_lane(skip: { [number]: boolean }?): number
		for i, h in lanes do
			if h == false and not (skip and skip[i]) then
				return i
			end
		end
		return #lanes + 1
	end

	local function new_color(): number
		local c = next_color
		next_color = (next_color + 1) % M.COLORS
		return c
	end

	for _, c in commits do
		local segs: { Seg } = {}
		local width = 0
		local function touch(i: number)
			if i > width then
				width = i
			end
		end

		-- Lanes waiting for this commit converge into the leftmost one.
		local waiting: { number } = {}
		for i, h in lanes do
			if h == c.hash then
				table.insert(waiting, i)
			end
		end

		local col: number
		local color: number
		if #waiting > 0 then
			col = waiting[1]
			color = colors[col]
			table.insert(segs, { kind = "top", a = col - 1, b = col - 1, color = color })
		else
			-- A branch tip: start a new line.
			col = free_lane()
			color = new_color()
		end
		touch(col)

		local joined: { [number]: boolean } = {}
		for k = 2, #waiting do
			local j = waiting[k]
			joined[j] = true
			touch(j)
			table.insert(segs, { kind = "join", a = j - 1, b = col - 1, color = colors[j] })
		end

		-- Lines passing by.
		for i, h in lanes do
			if h ~= false and i ~= col and not joined[i] then
				touch(i)
				table.insert(segs, { kind = "v", a = i - 1, b = i - 1, color = colors[i] })
			end
		end

		-- Free the converged lanes, then route the parents.
		for j in joined do
			lanes[j] = false
		end
		lanes[col] = false

		local first = c.parents[1]
		if first then
			lanes[col] = first
			colors[col] = color
			table.insert(segs, { kind = "bottom", a = col - 1, b = col - 1, color = color })
		end
		for k = 2, #c.parents do
			local p = c.parents[k]
			-- Merge from a line that already waits for this parent, else open one.
			local target: number? = nil
			for i, h in lanes do
				if h == p then
					target = i
					break
				end
			end
			if target == nil then
				local t = free_lane(joined)
				lanes[t] = p
				colors[t] = new_color()
				target = t
			end
			local t = target :: number
			touch(t)
			table.insert(segs, { kind = "fork", a = col - 1, b = t - 1, color = colors[t] })
		end

		-- The dot last, so it draws over the lines.
		table.insert(segs, { kind = "dot", a = col - 1, b = col - 1, color = color })

		-- Trim free lanes at the right edge.
		while #lanes > 0 and lanes[#lanes] == false do
			lanes[#lanes] = nil
		end

		table.insert(rows, { lane = col - 1, color = color, segs = segs, width = width })
	end
	return rows
end

return M
