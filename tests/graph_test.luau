--!strict
-- Run with: luau tests/graph_test.luau
local graph = require("../lib/graph")

local failures = 0
local function check(cond: boolean, what: string)
	if not cond then
		failures += 1
		print("FAIL: " .. what)
	end
end

local function commit(hash: string, parents: { string }): graph.Commit
	return { hash = hash, parents = parents, refs = {}, author = "a", email = "e", time = 0, subject = hash }
end

local function has(row: graph.Row, kind: string, a: number, b: number): boolean
	for _, s in row.segs do
		if s.kind == kind and s.a == a and s.b == b then
			return true
		end
	end
	return false
end

-- Invariants every layout must hold; `name` labels the failures.
-- A seg "ends" at the bottom of lane L when it is `bottom`/`v` in L or a `fork` into L;
-- it "starts" at the top of L when it is `top`/`v` in L or a `join` out of L.
local function invariants(rows: { graph.Row }, name: string)
	local above: { [number]: number } = {} -- lane -> color left at the bottom of the previous row
	for i, row in rows do
		local at = name .. " row " .. i
		local dots = 0
		local max = -1
		local below: { [number]: number } = {}
		local starts: { [number]: boolean } = {}
		for k, s in row.segs do
			if s.a > max then
				max = s.a
			end
			if s.b > max then
				max = s.b
			end
			if s.kind == "v" or s.kind == "top" or s.kind == "bottom" or s.kind == "dot" then
				check(s.a == s.b, at .. ": " .. s.kind .. " stays in its lane")
			end
			if s.kind == "dot" then
				dots += 1
				check(k == #row.segs, at .. ": dot is the last seg")
				check(s.a == row.lane and s.color == row.color, at .. ": dot matches row lane/color")
			end
			local top: number? = nil
			if s.kind == "top" or s.kind == "v" or s.kind == "join" then
				top = s.a
			end
			if top then
				starts[top] = true
				local c = above[top]
				check(c ~= nil, at .. ": " .. s.kind .. " starts at top of lane " .. top .. " that nothing fed")
				check(c == nil or c == s.color, at .. ": lane " .. top .. " keeps its color across rows")
			end
			local bottom: number? = nil
			if s.kind == "bottom" or s.kind == "v" then
				bottom = s.a
			elseif s.kind == "fork" then
				bottom = s.b
			end
			if bottom then
				local c = below[bottom]
				check(c == nil or c == s.color, at .. ": segs ending in lane " .. bottom .. " share one color")
				below[bottom] = s.color
			end
			if s.kind == "join" then
				check(s.b == row.lane, at .. ": join lands on the dot")
			end
			if s.kind == "fork" then
				check(s.a == row.lane, at .. ": fork leaves the dot")
			end
		end
		check(dots == 1, at .. ": exactly one dot")
		check(row.width == max + 1, at .. ": width " .. row.width .. " == max lane + 1 (" .. (max + 1) .. ")")
		for lane in above do
			check(starts[lane] == true, at .. ": lane " .. lane .. " left by the previous row continues")
		end
		above = below
	end
	for lane in above do
		check(false, name .. ": lane " .. lane .. " still open after the last row")
	end
end

local function count(row: graph.Row, kind: string): number
	local n = 0
	for _, s in row.segs do
		if s.kind == kind then
			n += 1
		end
	end
	return n
end

-- M merges F into C; both branch off B; A is the root.
do
	local rows = graph.layout({
		commit("M", { "C", "F" }),
		commit("F", { "B" }),
		commit("C", { "B" }),
		commit("B", { "A" }),
		commit("A", {}),
	})
	check(rows[1].lane == 0, "merge commit in lane 0")
	check(not has(rows[1], "top", 0, 0), "a tip has no line above it")
	check(has(rows[1], "fork", 0, 1), "merge forks to lane 1 for its second parent")
	check(has(rows[1], "bottom", 0, 0), "merge continues down to its first parent")
	check(rows[2].lane == 1, "F sits in the lane the merge opened")
	check(has(rows[2], "v", 0, 0), "lane 0 passes by F")
	check(rows[3].lane == 0 and has(rows[3], "v", 1, 1), "C in lane 0, F's line passes by")
	check(rows[4].lane == 0 and has(rows[4], "join", 1, 0), "B gathers lane 1 into lane 0")
	check(rows[4].width == 2, "B's row still draws two lanes")
	check(rows[5].width == 1 and not has(rows[5], "bottom", 0, 0), "root ends its line")
	check(rows[1].segs[#rows[1].segs].kind == "dot", "dot drawn last")
	check(rows[2].color ~= rows[1].color, "a new line gets a new color")
	check(rows[3].color == rows[1].color, "a line keeps its color")
	invariants(rows, "simple merge")
end

-- Two unrelated tips: the second opens a new lane, then reuses lane 1 after it ends.
do
	local rows = graph.layout({
		commit("X", { "R" }),
		commit("Y", {}),
		commit("Z", { "W" }),
		commit("R", {}),
		commit("W", {}),
	})
	check(rows[2].lane == 1, "second tip opens lane 1")
	check(rows[3].lane == 1, "freed lane 1 is reused")
	check(rows[4].lane == 0 and rows[5].lane == 1, "parents land in their lanes")
	invariants(rows, "unrelated tips")
end

-- Octopus merge: O has three parents, each in its own lane.
do
	local rows = graph.layout({
		commit("O", { "A", "B", "C" }),
		commit("C", { "R" }),
		commit("B", { "R" }),
		commit("A", { "R" }),
		commit("R", {}),
	})
	invariants(rows, "octopus")
	check(has(rows[1], "bottom", 0, 0), "octopus: first parent continues lane 0")
	check(has(rows[1], "fork", 0, 1) and has(rows[1], "fork", 0, 2), "octopus: forks into lanes 1 and 2")
	check(count(rows[1], "fork") == 2, "octopus: two forks")
	check(rows[1].width == 3, "octopus: three lanes wide")
	local f1, f2
	for _, s in rows[1].segs do
		if s.kind == "fork" and s.b == 1 then
			f1 = s.color
		elseif s.kind == "fork" and s.b == 2 then
			f2 = s.color
		end
	end
	check(f1 ~= nil and f2 ~= nil and f1 ~= f2 and f1 ~= rows[1].color and f2 ~= rows[1].color, "octopus: each parent lane gets its own color")
	check(rows[2].lane == 2 and rows[3].lane == 1 and rows[4].lane == 0, "octopus: parents sit in the lanes opened for them")
	check(rows[5].lane == 0 and has(rows[5], "join", 1, 0) and has(rows[5], "join", 2, 0), "octopus: root gathers all lanes")
	check(rows[5].width == 3, "octopus: root row draws all three lanes")
end

-- Two merges share the second parent S: the second merge forks into S's waiting lane.
do
	local rows = graph.layout({
		commit("M1", { "A", "S" }),
		commit("M2", { "B", "S" }),
		commit("A", { "S" }),
		commit("B", { "S" }),
		commit("S", {}),
	})
	invariants(rows, "shared parent")
	check(has(rows[1], "fork", 0, 1), "shared parent: M1 opens lane 1 for S")
	check(rows[2].lane == 2, "shared parent: M2 is a new tip in lane 2")
	check(has(rows[2], "fork", 2, 1), "shared parent: M2 forks into S's lane 1")
	check(not has(rows[2], "fork", 2, 3) and rows[2].width == 3, "shared parent: M2 opens no new lane")
	check(rows[5].lane == 0 and count(rows[5], "join") == 2, "shared parent: S gathers the other lanes")
end

-- Criss-cross: C1 and C2 each merge A and B in opposite order.
do
	local rows = graph.layout({
		commit("C1", { "A", "B" }),
		commit("C2", { "B", "A" }),
		commit("A", { "O" }),
		commit("B", { "O" }),
		commit("O", {}),
	})
	invariants(rows, "criss-cross")
	check(rows[1].lane == 0 and has(rows[1], "fork", 0, 1), "criss-cross: C1 forks to B in lane 1")
	check(rows[2].lane == 2 and has(rows[2], "bottom", 2, 2), "criss-cross: C2 in lane 2 heads to B")
	check(has(rows[2], "fork", 2, 0), "criss-cross: C2 forks into A's waiting lane 0")
	check(rows[3].lane == 0, "criss-cross: A in lane 0")
	check(rows[4].lane == 1 and has(rows[4], "join", 2, 1), "criss-cross: B gathers lane 2 into lane 1")
	check(rows[5].lane == 0 and has(rows[5], "join", 1, 0), "criss-cross: O gathers lane 1")
end

-- Three branches converge into B: two joins in one row.
do
	local rows = graph.layout({
		commit("T1", { "B" }),
		commit("T2", { "B" }),
		commit("T3", { "B" }),
		commit("B", {}),
	})
	invariants(rows, "converge")
	check(rows[3].lane == 2 and rows[3].width == 3, "converge: third tip in lane 2")
	check(rows[4].lane == 0 and has(rows[4], "top", 0, 0), "converge: B in lane 0 with a line above")
	check(has(rows[4], "join", 1, 0) and has(rows[4], "join", 2, 0), "converge: lanes 1 and 2 join B")
	check(count(rows[4], "join") == 2 and count(rows[4], "v") == 0, "converge: nothing else passes")
	check(rows[4].width == 3, "converge: B's row draws three lanes")
	check(rows[4].color == rows[1].color, "converge: B keeps lane 0's color")
end

-- X gathers lane 1 and opens a lane for its second parent: lane 1 (joined this row) is skipped.
do
	local rows = graph.layout({
		commit("T1", { "X" }),
		commit("T2", { "X" }),
		commit("X", { "P", "Q" }),
		commit("P", {}),
		commit("Q", {}),
	})
	invariants(rows, "join reuse")
	check(rows[3].lane == 0 and has(rows[3], "join", 1, 0), "join reuse: lane 1 joins X")
	check(has(rows[3], "fork", 0, 2) and not has(rows[3], "fork", 0, 1), "join reuse: Q's lane skips the joined lane 1")
	check(rows[3].width == 3, "join reuse: X's row is three lanes wide")
	check(rows[4].lane == 0 and has(rows[4], "v", 2, 2) and not has(rows[4], "v", 1, 1), "join reuse: lane 1 stays empty after")
	check(rows[5].lane == 2, "join reuse: Q in lane 2")
end

-- Twenty parallel branches, then a twenty-parent octopus: more than 16 lanes still lay out.
do
	local n = 20
	local cs = {}
	for i = 1, n do
		table.insert(cs, commit("T" .. i, { "P" .. i }))
	end
	for i = 1, n do
		table.insert(cs, commit("P" .. i, {}))
	end
	local ok, rows = pcall(graph.layout, cs)
	check(ok, "wide: layout of " .. n .. " lanes does not error")
	if ok then
		invariants(rows, "wide")
		for i = 1, n do
			check(rows[i].lane == i - 1 and rows[i].width == i, "wide: tip " .. i .. " opens lane " .. (i - 1))
		end
		check(rows[n + 1].width == n, "wide: first parent row draws all lanes")
		check(rows[2 * n].lane == n - 1 and rows[2 * n].width == n, "wide: last parent in the last lane")
	end

	local parents = {}
	for i = 1, n do
		table.insert(parents, "Q" .. i)
	end
	local oc = { commit("O", parents) }
	for i = n, 1, -1 do
		table.insert(oc, commit("Q" .. i, {}))
	end
	local ok2, orows = pcall(graph.layout, oc)
	check(ok2, "wide octopus: layout does not error")
	if ok2 then
		invariants(orows, "wide octopus")
		check(orows[1].width == n and count(orows[1], "fork") == n - 1, "wide octopus: one lane per parent")
		check(orows[2].lane == n - 1 and orows[#orows].lane == 0, "wide octopus: parents in their lanes")
	end
end

-- Decorations.
do
	local refs = graph.parse_refs("HEAD -> refs/heads/main, refs/remotes/origin/main, refs/remotes/origin/HEAD, tag: refs/tags/v1, refs/heads/dev", true)
	check(#refs == 4, "origin/HEAD dropped")
	check(refs[1].name == "main" and refs[1].current and refs[1].kind == "local", "checked-out branch first")
	check(refs[2].name == "dev", "other local branches next")
	check(refs[3].name == "origin/main" and refs[3].kind == "remote", "then remotes")
	check(refs[4].name == "v1" and refs[4].kind == "tag", "then tags")
	local hidden = graph.parse_refs("refs/remotes/origin/main, refs/heads/x", false)
	check(#hidden == 1 and hidden[1].name == "x", "remotes hidden on request")
	local detached = graph.parse_refs("HEAD, refs/heads/x", true)
	check(detached[1].kind == "head" and detached[1].current, "detached HEAD drawn first")
	local tags = graph.parse_refs("tag: refs/tags/v2, tag: refs/tags/v1", true)
	check(#tags == 2, "tags only: two refs")
	check(tags[1].name == "v1" and tags[2].name == "v2", "tags only: sorted by name")
	check(tags[1].kind == "tag" and not tags[1].current and not tags[2].current, "tags only: tags, none current")
	local tracked = graph.parse_refs("HEAD -> refs/heads/x, refs/remotes/origin/x", true)
	check(#tracked == 2, "tracked: branch and remote")
	check(tracked[1].name == "x" and tracked[1].kind == "local" and tracked[1].current, "tracked: local x current, first")
	check(tracked[2].name == "origin/x" and tracked[2].kind == "remote" and not tracked[2].current, "tracked: origin/x remote")
	local untracked = graph.parse_refs("HEAD -> refs/heads/x, refs/remotes/origin/x", false)
	check(#untracked == 1 and untracked[1].name == "x" and untracked[1].current, "tracked: remote hidden on request")
	check(#graph.parse_refs("", true) == 0, "empty decoration")
end

-- Log parsing.
do
	local out = "\x1eaaa\x1fbbb ccc\x1fHEAD -> refs/heads/main\x1fAnn\x1fann@x\x1f100\x1fMerge it\n"
		.. "\x1ebbb\x1f\x1f\x1fBob\x1fbob@x\x1f50\x1ffirst\n"
	local cs = graph.parse_log(out, true)
	check(#cs == 2, "two commits")
	check(#cs[1].parents == 2 and cs[1].parents[2] == "ccc", "parents split")
	check(cs[1].refs[1].name == "main", "refs parsed")
	check(cs[2].time == 50 and #cs[2].parents == 0, "root commit")
	check(cs[1].subject == "Merge it", "subject kept")
	local sep = "\x1eddd\x1f\x1f\x1fCy\x1fcy@x\x1f7\x1fa\x1fb\x1fc\n"
	local sc = graph.parse_log(sep, true)
	check(#sc == 1 and sc[1].subject == "a\x1fb\x1fc", "subject keeps the field separator")
	check(sc[1] ~= nil and sc[1].author == "Cy" and sc[1].time == 7, "fields before the subject unaffected")
	local empty = graph.parse_log("\x1eeee\x1f\x1f\x1fD\x1fd@x\x1f1\x1f\n", true)
	check(#empty == 1 and empty[1].subject == "", "empty subject")
end

-- Command lines.
do
	local argv = graph.log_argv(50, true)
	check(argv[#argv] == "--" and argv[#argv - 1] == "HEAD", "log_argv ends with HEAD --")
	check(table.find(argv, "--remotes") ~= nil and table.find(argv, "50") ~= nil, "log_argv: remotes and limit")
	check(table.find(graph.log_argv(10, false), "--remotes") == nil, "log_argv: no remotes")
	local cnt = graph.count_argv(false)
	check(cnt[2] == "rev-list" and table.find(cnt, "--remotes") == nil and cnt[#cnt] == "--", "count_argv")
	check(table.find(graph.count_argv(true), "--remotes") ~= nil, "count_argv: remotes")
end

if failures > 0 then
	error(failures .. " check(s) failed")
end
print("ok")
