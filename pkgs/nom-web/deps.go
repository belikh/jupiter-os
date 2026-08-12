package main

import (
	"bufio"
	"os"
	"sort"
	"strings"
)

// depGraph is the derivation dependency graph for one CI run, loaded from
// the `deps-<run_id>.txt` edge list ci-distributed.yml writes next to the
// jsonl log — one `<input-drv> <dependent-drv>` pair per line, store
// basenames, no /nix/store/ prefix.
//
// It has to arrive out of band because the internal-json stream carries no
// dependency edges at all: every build activity nix emits has "parent":0,
// there are no actBuildWaiting events, and the "these N derivations will be
// built:" listing names derivations without relating them. nom gets its own
// dependency graph by reading the .drv files named in the log out of the
// LOCAL store — which only resolves where the build was evaluated. On europa
// that is 9 of a run's 1144 planned drvs (the other 1135 were evaluated on
// the GitHub runners), which is why pointing at the store instead would
// produce an almost entirely flat graph.
type depGraph struct {
	// inputs maps a derivation to the derivations it directly depends on.
	inputs map[string][]string
}

func loadDepGraph(path string) (*depGraph, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	g := &depGraph{inputs: make(map[string][]string)}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		i := strings.IndexByte(line, ' ')
		if i <= 0 || i+1 >= len(line) {
			continue
		}
		input, dependent := line[:i], line[i+1:]
		g.inputs[dependent] = append(g.inputs[dependent], input)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return g, nil
}

// TreeNode is one derivation in the rendered forest. Children are indices
// into Tree.Nodes rather than nested structs: the restricted graph is a DAG,
// not a tree (a derivation can be needed by several others), so a node is
// referenced from every dependent that needs it and the client expands each
// one only once.
type TreeNode struct {
	Name     string `json:"name"`
	Drv      string `json:"drv"`
	Children []int  `json:"children"`
}

type Tree struct {
	Nodes []TreeNode `json:"nodes"`
	Roots []int      `json:"roots"`
}

// nearestIn walks up from node's inputs until it reaches derivations that
// are themselves in the run (idx), collapsing the intermediate ones that
// were already in the store and never got built. Without this the tree
// would be almost entirely disconnected: a run's planned derivations are
// usually separated from each other by dozens of cached ones.
//
// Memoised per node, so the whole forest costs one pass over the graph
// rather than one walk per planned derivation.
func (g *depGraph) nearestIn(node string, idx map[string]int, memo map[string][]string) []string {
	if v, ok := memo[node]; ok {
		return v
	}
	memo[node] = nil // cycle guard; derivation graphs are acyclic, malformed input need not be

	var out []string
	seen := make(map[string]bool)
	for _, in := range g.inputs[node] {
		if _, planned := idx[in]; planned {
			if !seen[in] {
				seen[in] = true
				out = append(out, in)
			}
			continue
		}
		for _, d := range g.nearestIn(in, idx, memo) {
			if !seen[d] {
				seen[d] = true
				out = append(out, d)
			}
		}
	}
	memo[node] = out
	return out
}

// buildTree relates the run's derivations (in the order the log listed them)
// to each other. Roots are the derivations nothing else in the run depends
// on — the things actually being asked for, with everything they are
// waiting on underneath.
func buildTree(drvs []string, g *depGraph) Tree {
	idx := make(map[string]int, len(drvs))
	nodes := make([]TreeNode, len(drvs))
	for i, d := range drvs {
		idx[d] = i
		nodes[i] = TreeNode{Name: strings.TrimSuffix(storePathToName(d), ".drv"), Drv: d}
	}
	if g == nil {
		roots := make([]int, len(drvs))
		for i := range drvs {
			roots[i] = i
		}
		return Tree{Nodes: nodes, Roots: roots}
	}

	memo := make(map[string][]string)
	isChild := make([]bool, len(drvs))
	for i, d := range drvs {
		for _, c := range g.nearestIn(d, idx, memo) {
			j, ok := idx[c]
			if !ok || j == i {
				continue
			}
			nodes[i].Children = append(nodes[i].Children, j)
			isChild[j] = true
		}
	}

	var roots []int
	for i := range nodes {
		if !isChild[i] {
			roots = append(roots, i)
		}
	}
	sort.Slice(roots, func(a, b int) bool { return nodes[roots[a]].Name < nodes[roots[b]].Name })
	return Tree{Nodes: nodes, Roots: roots}
}
