// Inventory subsumption (gauntlet P8, goal 7 wrap-up): the webapp serves
// the JSON document scripts/arcade-status.sh (make status-arcade) used to
// read from the retired jupiter-arcade-inventory unit's state file over
// SSH. Field-for-field parity is pinned by internal/inventory's fixture
// test; this file is the HTTP surface + the live unit-state probe.
//
// The route is a plain GET (no htmx gate): status consumers are scripts,
// not browsers, and the document carries nothing secret.
package web

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/inventory"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// handleInventoryJSON answers GET /inventory.json with the legacy-shaped
// document built from live store aggregates + the rom-acquire unit state.
func (s *Server) handleInventoryJSON(w http.ResponseWriter, r *http.Request) {
	summary, err := s.st.SystemSummary()
	if err != nil {
		log.Printf("web: inventory summary: %v", err)
		http.Error(w, "inventory unavailable", http.StatusInternalServerError)
		return
	}
	exo, err := s.st.ExoStatsBySystem()
	if err != nil {
		// Degrade to an exo-less section rather than failing the whole
		// document (the console sections stay truthful).
		log.Printf("web: inventory exo stats: %v", err)
		exo = map[string]store.ExoStat{}
	}
	doc := inventory.Build(summary, exo, romAcquireActiveState(r.Context()), time.Now())
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(doc); err != nil {
		log.Printf("web: inventory encode: %v", err)
	}
}

// romAcquireActiveState mirrors the legacy script's probe:
// systemctl show -p ActiveState --value jupiter-rom-acquire.service,
// errors/absence → "" → Build renders "unknown". Bounded at 2s: a wedged
// systemd must not stall the poller.
func romAcquireActiveState(ctx context.Context) string {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	bin, err := exec.LookPath("systemctl")
	if err != nil {
		return ""
	}
	out, err := exec.CommandContext(ctx, bin, "show", "-p", "ActiveState", "--value",
		inventory.RomAcquireUnit).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
