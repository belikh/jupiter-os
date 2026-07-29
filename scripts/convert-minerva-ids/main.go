package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type MetadataIndex struct {
	Files map[string]int `json:"files"`
}

func main() {
	inputDir := flag.String("input", "/tank/archive/retro/metadata/minerva-ids", "Input directory with .md files")
	outputDir := flag.String("output", "/tank/archive/retro/metadata/minerva-ids", "Output directory for .json files")
	flag.Parse()

	files, err := filepath.Glob(filepath.Join(*inputDir, "*.md"))
	if err != nil {
		log.Fatalf("Failed to glob .md files: %v", err)
	}

	if len(files) == 0 {
		log.Fatalf("No .md files found in %s", *inputDir)
	}

	log.Printf("Found %d .md files to convert", len(files))

	for _, mdFile := range files {
		if err := convertFile(mdFile, *outputDir); err != nil {
			log.Printf("Error converting %s: %v", mdFile, err)
		}
	}

	log.Printf("Conversion complete")
}

func convertFile(mdFile, outputDir string) error {
	file, err := os.Open(mdFile)
	if err != nil {
		return fmt.Errorf("open: %w", err)
	}
	defer file.Close()

	metadata := MetadataIndex{Files: make(map[string]int)}
	scanner := bufio.NewScanner(file)
	lineNum := 0

	for scanner.Scan() {
		line := scanner.Text()
		lineNum++

		// Skip header and separator lines
		if lineNum <= 2 || !strings.Contains(line, "|") {
			continue
		}

		// Parse pipe-delimited table: | ID | GAME |
		parts := strings.Split(line, "|")
		if len(parts) < 3 {
			continue
		}

		idStr := strings.TrimSpace(parts[1])
		gamePath := strings.TrimSpace(parts[2])

		if idStr == "" || gamePath == "" {
			continue
		}

		id, err := strconv.Atoi(idStr)
		if err != nil {
			continue
		}

		// Extract just the filename (game name) from the full path
		// e.g., "./Minerva_Myrient/No-Intro/Nintendo/NES/Super Mario Bros.nes" → "Super Mario Bros.nes"
		gameName := filepath.Base(gamePath)

		// Store in map (dedup by game name; later entries overwrite earlier)
		metadata.Files[gameName] = id
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("scanner: %w", err)
	}

	if len(metadata.Files) == 0 {
		return fmt.Errorf("no games found in %s", mdFile)
	}

	// Generate output filename: replace .md with .json
	jsonFile := strings.TrimSuffix(mdFile, ".md") + ".json"
	jsonFile = filepath.Join(outputDir, filepath.Base(jsonFile))

	jsonData, err := json.MarshalIndent(metadata, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}

	if err := os.WriteFile(jsonFile, jsonData, 0644); err != nil {
		return fmt.Errorf("write: %w", err)
	}

	log.Printf("Converted %s → %s (%d games)", filepath.Base(mdFile), filepath.Base(jsonFile), len(metadata.Files))
	return nil
}
