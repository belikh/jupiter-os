// fixturegen materializes the arcade-webapp fixture corpus (see
// internal/fixture). Two modes, either or both:
//
//	go run ./cmd/fixturegen --roms tests/fixtures/arcade/incoming
//	go run ./cmd/fixturegen --dats  testdata/dats
//
// --dats is the bootstrap that produced the committed DATs; re-running it
// must be a no-op diff (the unit tests assert generator↔DAT equivalence).
package main

import (
	"flag"
	"fmt"
	"log"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/fixture"
)

func main() {
	roms := flag.String("roms", "", "write the dummy ROM tree under this directory (<dir>/<system>/<rom>)")
	dats := flag.String("dats", "", "write one Logiqx DAT per system under this directory (<dir>/<system>.dat)")
	flag.Parse()

	if *roms == "" && *dats == "" {
		log.Fatal("fixturegen: nothing to do — pass --roms and/or --dats")
	}

	if *roms != "" {
		if err := fixture.WriteROMs(*roms); err != nil {
			log.Fatalf("fixturegen: --roms: %v", err)
		}
		fmt.Printf("fixturegen: ROM tree written under %s\n", *roms)
	}
	if *dats != "" {
		if err := fixture.WriteDATs(*dats); err != nil {
			log.Fatalf("fixturegen: --dats: %v", err)
		}
		fmt.Printf("fixturegen: DATs written under %s\n", *dats)
	}
}
