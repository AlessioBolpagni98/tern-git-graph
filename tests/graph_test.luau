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
end

if failures > 0 then
	error(failures .. " check(s) failed")
end
print("ok")
