package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
)

func main() {
	metadataDir := "/tank/archive/retro/metadata/minerva-ids"
	outputDir := "/tank/archive/retro/metadata/pegasus/collections"

	os.MkdirAll(outputDir, 0755)

	collectionMap := map[string][2]string{
		"Minerva_Myrient_-_No-Intro_-_Nintendo_-_Nintendo_Entertainment_System_(Headered)_(Aftermarket).torrent-ids.json": {"Nintendo Entertainment System", "1g1r-nointro-nes"},
		"Minerva_Myrient_-_No-Intro_-_Nintendo_-_Super_Nintendo_Entertainment_System.torrent-ids.json":                   {"Super Nintendo Entertainment System", "1g1r-nointro-snes"},
		"Minerva_Myrient_-_No-Intro_-_Nintendo_-_Game_Boy.torrent-ids.json":                                             {"Game Boy", "1g1r-nointro-gb"},
		"Minerva_Myrient_-_No-Intro_-_Nintendo_-_Game_Boy_Color.torrent-ids.json":                                       {"Game Boy Color", "1g1r-nointro-gbc"},
		"Minerva_Myrient_-_No-Intro_-_Nintendo_-_Game_Boy_Advance.torrent-ids.json":                                     {"Game Boy Advance", "1g1r-nointro-gba"},
		"Minerva_Myrient_-_No-Intro_-_Nintendo_-_Nintendo_64.torrent-ids.json":                                          {"Nintendo 64", "1g1r-nointro-n64"},
		"Minerva_Myrient_-_No-Intro_-_Nintendo_-_Nintendo_DS.torrent-ids.json":                                          {"Nintendo DS", "1g1r-nointro-ds"},
		"Minerva_Myrient_-_Redump_-_Sony_-_PlayStation.torrent-ids.json":                                                {"PlayStation", "1g1r-redump-ps1"},
		"Minerva_Myrient_-_Redump_-_Sony_-_PlayStation_2.torrent-ids.json":                                              {"PlayStation 2", "1g1r-redump-ps2"},
		"Minerva_Myrient_-_Redump_-_Sony_-_PlayStation_Portable.torrent-ids.json":                                       {"PlayStation Portable", "1g1r-redump-psp"},
		"Minerva_Myrient_-_Redump_-_Sega_-_Saturn.torrent-ids.json":                                                     {"Sega Saturn", "1g1r-redump-saturn"},
		"Minerva_Myrient_-_Redump_-_Sega_-_Dreamcast.torrent-ids.json":                                                  {"Sega Dreamcast", "1g1r-redump-dreamcast"},
		"Minerva_Myrient_-_Redump_-_Nintendo_-_GameCube.torrent-ids.json":                                               {"Nintendo GameCube", "1g1r-redump-gamecube"},
		"Minerva_Myrient_-_Redump_-_Nintendo_-_Wii.torrent-ids.json":                                                    {"Nintendo Wii", "1g1r-redump-wii"},
		"Minerva_Myrient_-_Redump_-_Microsoft_-_Xbox.torrent-ids.json":                                                  {"Microsoft Xbox", "1g1r-redump-xbox"},
	}

	for jsonFile, names := range collectionMap {
		displayName := names[0]
		collectionID := names[1]

		jsonPath := filepath.Join(metadataDir, jsonFile)
		data, err := os.ReadFile(jsonPath)
		if err != nil {
			log.Printf("Skipping %s (not found)", jsonFile)
			continue
		}

		var metadata map[string]interface{}
		if err := json.Unmarshal(data, &metadata); err != nil {
			log.Printf("Error parsing %s: %v", jsonFile, err)
			continue
		}

		filesMap, ok := metadata["files"].(map[string]interface{})
		if !ok || len(filesMap) == 0 {
			log.Printf("Skipping %s (no games)", jsonFile)
			continue
		}

		var gameNames []string
		for gameName := range filesMap {
			gameNames = append(gameNames, gameName)
		}
		sort.Strings(gameNames)

		outputFile := filepath.Join(outputDir, collectionID+".txt")
		output := fmt.Sprintf("# %s - %d games\n", displayName, len(gameNames))
		output += "# Auto-generated from Minerva archive metadata\n\n"

		for _, gameName := range gameNames {
			output += fmt.Sprintf("game: %s\n", gameName)
			output += fmt.Sprintf("path: %s/%s\n", collectionID, gameName)
			output += "\n"
		}

		if err := os.WriteFile(outputFile, []byte(output), 0644); err != nil {
			log.Printf("Error writing %s: %v", outputFile, err)
			continue
		}

		fmt.Printf("Generated %s: %d games\n", collectionID, len(gameNames))
	}

	fmt.Println("Pegasus collection generation complete")
}
