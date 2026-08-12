package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The property that matters: derivations in a run are almost never direct
// inputs of each other — they are separated by intermediate derivations that
// were already in the store and so never appear in the log. A tree that only
// used direct edges would be a flat list of roots.
func TestBuildTreeCollapsesCachedIntermediates(t *testing.T) {
	g := &depGraph{inputs: map[string][]string{
		"aaa-top.drv":    {"bbb-cached.drv"},
		"bbb-cached.drv": {"ccc-leaf.drv"},
	}}

	tree := buildTree([]string{"aaa-top.drv", "ccc-leaf.drv"}, g)

	if len(tree.Roots) != 1 || tree.Roots[0] != 0 {
		t.Fatalf("expected the dependent to be the only root, got %v", tree.Roots)
	}
	if got := tree.Nodes[0].Children; len(got) != 1 || got[0] != 1 {
		t.Fatalf("expected leaf collapsed under top, got children %v", got)
	}
	if tree.Nodes[0].Name != "top" || tree.Nodes[1].Name != "leaf" {
		t.Fatalf("unexpected names: %q, %q", tree.Nodes[0].Name, tree.Nodes[1].Name)
	}
	if len(tree.Nodes[1].Children) != 0 {
		t.Fatalf("leaf should have no children, got %v", tree.Nodes[1].Children)
	}
}

// A derivation needed by two others is one node referenced twice, not two
// nodes — the client expands the first occurrence and back-references the
// rest.
func TestBuildTreeSharedDependency(t *testing.T) {
	g := &depGraph{inputs: map[string][]string{
		"aaa-one.drv": {"ccc-shared.drv"},
		"bbb-two.drv": {"ccc-shared.drv"},
	}}

	tree := buildTree([]string{"aaa-one.drv", "bbb-two.drv", "ccc-shared.drv"}, g)

	if len(tree.Roots) != 2 {
		t.Fatalf("expected 2 roots, got %v", tree.Roots)
	}
	for _, i := range []int{0, 1} {
		if got := tree.Nodes[i].Children; len(got) != 1 || got[0] != 2 {
			t.Fatalf("node %d should point at the shared dep, got %v", i, got)
		}
	}
}

// Without the edge list every derivation is its own root: the tree degrades
// to the flat listing rather than vanishing.
func TestBuildTreeWithoutGraph(t *testing.T) {
	tree := buildTree([]string{"aaa-one.drv", "bbb-two.drv"}, nil)
	if len(tree.Roots) != 2 {
		t.Fatalf("expected every derivation to be a root, got %v", tree.Roots)
	}
}

func TestLoadDepGraph(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "deps-1.txt")
	content := "bbb-cached.drv aaa-top.drv\nccc-leaf.drv bbb-cached.drv\ngarbage-without-space\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	g, err := loadDepGraph(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := g.inputs["aaa-top.drv"]; len(got) != 1 || got[0] != "bbb-cached.drv" {
		t.Fatalf("unexpected inputs for top: %v", got)
	}
	if len(g.inputs) != 2 {
		t.Fatalf("malformed line should be skipped, got %d entries", len(g.inputs))
	}
}

// The planned listing is the only place derivations that have not started
// are named, and it ends as soon as a line stops looking like a store path.
func TestPlannedListingParsing(t *testing.T) {
	s := newState()
	for _, msg := range []string{
		"these 2 derivations will be built:",
		"  /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-one.drv",
		"  /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-two.drv",
		"building '/nix/store/cccc-three.drv'...",
		"  /nix/store/dddddddddddddddddddddddddddddddd-four.drv",
	} {
		s.apply(&rawEvent{Action: "msg", Level: 3, Msg: msg})
	}

	if len(s.drvs) != 2 {
		t.Fatalf("expected 2 planned derivations, got %v", s.drvs)
	}
	if s.track[0].state() != drvPlanned {
		t.Fatalf("expected planned state, got %d", s.track[0].state())
	}
}

func TestBuildStartAndStopTrackState(t *testing.T) {
	s := newState()
	drv := "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-one.drv"
	s.apply(&rawEvent{Action: "msg", Level: 3, Msg: "these 1 derivations will be built:"})
	s.apply(&rawEvent{Action: "msg", Level: 3, Msg: "  " + drv})
	s.apply(&rawEvent{Action: "start", ID: 1, Type: int(actBuild), Fields: []interface{}{drv, "ssh-ng://builder"}})

	if len(s.drvs) != 1 {
		t.Fatalf("build start must reuse the planned entry, got %v", s.drvs)
	}
	if s.track[0].state() != drvRunning {
		t.Fatalf("expected running, got %d", s.track[0].state())
	}

	s.apply(&rawEvent{Action: "stop", ID: 1})
	if s.track[0].state() != drvDone {
		t.Fatalf("expected done, got %d", s.track[0].state())
	}
}

// nix opens two build activities per derivation (the remote builder's and
// the local one carrying its log). The first to stop must not flip the
// derivation to done while the other is still building.
func TestConcurrentBuildActivitiesForOneDrv(t *testing.T) {
	s := newState()
	drv := "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-one.drv"
	s.apply(&rawEvent{Action: "start", ID: 1, Type: int(actBuild), Fields: []interface{}{drv, "ssh-ng://builder"}})
	s.apply(&rawEvent{Action: "start", ID: 2, Type: int(actBuild), Fields: []interface{}{drv}})

	s.apply(&rawEvent{Action: "stop", ID: 1})
	if got := s.track[0].state(); got != drvRunning {
		t.Fatalf("still building on the other activity, expected running, got %d", got)
	}
	s.apply(&rawEvent{Action: "stop", ID: 2})
	if got := s.track[0].state(); got != drvDone {
		t.Fatalf("expected done once both stopped, got %d", got)
	}
}

// A copy of an output path is attributed to the derivation that produced it
// by name, so the tree keeps showing a run's upload phase.
func TestCopyPathMarksDerivationTransferring(t *testing.T) {
	s := newState()
	drv := "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-one-1.2.drv"
	out := "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-one-1.2"
	s.apply(&rawEvent{Action: "msg", Level: 3, Msg: "these 1 derivations will be built:"})
	s.apply(&rawEvent{Action: "msg", Level: 3, Msg: "  " + drv})

	s.apply(&rawEvent{Action: "start", ID: 9, Type: int(actCopyPath), Fields: []interface{}{out, "europa", "callisto"}})
	if got := s.track[0].state(); got != drvTransferring {
		t.Fatalf("expected transferring, got %d", got)
	}
	s.apply(&rawEvent{Action: "stop", ID: 9})
	if got := s.track[0].state(); got != drvPlanned {
		t.Fatalf("a copy alone must not mark it built, got %d", got)
	}
}

// Two derivations sharing a name make the copy attribution ambiguous, and a
// guess would colour the wrong node — so it is declined.
func TestAmbiguousNameIsNotAttributed(t *testing.T) {
	s := newState()
	for _, h := range []string{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "cccccccccccccccccccccccccccccccc"} {
		s.apply(&rawEvent{Action: "msg", Level: 3, Msg: "these 2 derivations will be built:"})
		s.apply(&rawEvent{Action: "msg", Level: 3, Msg: "  /nix/store/" + h + "-one-1.2.drv"})
	}
	s.apply(&rawEvent{Action: "start", ID: 9, Type: int(actCopyPath),
		Fields: []interface{}{"/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-one-1.2", "europa", "callisto"}})

	for i := range s.track {
		if s.track[i].state() != drvPlanned {
			t.Fatalf("node %d should be untouched, got %d", i, s.track[i].state())
		}
	}
}
