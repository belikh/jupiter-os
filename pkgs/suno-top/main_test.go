package main

import (
	"encoding/json"
	"testing"
)

// TestParseClipTagResult pins the tag-search result shape: POST /api/search/
// returns full clip objects, so parseClip must extract the same projections it
// does for feed/profile clips. Fixture mirrors a live "pop" tag result
// (verified 2026-09-23).
func TestParseClipTagResult(t *testing.T) {
	raw := json.RawMessage(`{
		"id": "c6b10911-7462-4a65-8523-9de0a14db7fa",
		"title": "ice on the rim",
		"handle": "yamitsuke",
		"display_name": "yamitsuke",
		"user_id": "54901eb5-d569-434a-b938-d97aeb5143e3",
		"play_count": 93458,
		"upvote_count": 1377,
		"comment_count": 42,
		"created_at": "2026-09-09T14:07:14.348Z",
		"major_model_version": "v6",
		"model_name": "chirp-hawk",
		"is_public": true,
		"metadata": {
			"prompt": "city lights on the water",
			"tags": "A pop song sung in English by a solo male vocalist",
			"duration": 173.5,
			"type": "custom",
			"is_remix": false
		}
	}`)
	cf, err := parseClip(raw)
	if err != nil {
		t.Fatalf("parseClip: %v", err)
	}
	if cf.ID != "c6b10911-7462-4a65-8523-9de0a14db7fa" {
		t.Errorf("ID = %q", cf.ID)
	}
	if cf.Handle != "yamitsuke" {
		t.Errorf("Handle = %q", cf.Handle)
	}
	if cf.PlayCount != 93458 || cf.UpvoteCount != 1377 || cf.CommentCount != 42 {
		t.Errorf("counts = %d/%d/%d", cf.PlayCount, cf.UpvoteCount, cf.CommentCount)
	}
	if !cf.CreatedAt.Valid {
		t.Error("CreatedAt not parsed")
	}
	if cf.MajorModelVersion != "v6" || cf.ModelName != "chirp-hawk" {
		t.Errorf("model = %q/%q", cf.MajorModelVersion, cf.ModelName)
	}
	if !cf.DurationSec.Valid || cf.DurationSec.Float64 != 173.5 {
		t.Errorf("DurationSec = %+v", cf.DurationSec)
	}
	if cf.Prompt != "city lights on the water" {
		t.Errorf("Prompt = %q", cf.Prompt)
	}
	if cf.PromptMode != "custom" {
		t.Errorf("PromptMode = %q", cf.PromptMode)
	}
	if cf.IsPublic == nil || !*cf.IsPublic {
		t.Errorf("IsPublic = %v", cf.IsPublic)
	}
}

func TestTagPageAdvance(t *testing.T) {
	tests := []struct {
		name                     string
		from, pageLen, total, up int64
		floor                    int64
		wantNext                 int64
		wantDone                 bool
	}{
		{"mid walk", 0, 100, 10000, 500, 100, 100, false},
		{"empty page", 100, 0, 10000, 0, 100, 100, true},
		{"reached total", 9900, 100, 10000, 500, 100, 10000, true},
		{"page below floor", 200, 100, 10000, 50, 100, 300, true},
		{"floor disabled", 200, 100, 10000, 5, 0, 300, false},
		{"unknown total, more to come", 0, 100, 0, 500, 100, 100, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			next, done := tagPageAdvance(tt.from, tt.pageLen, tt.total, tt.up, tt.floor)
			if next != tt.wantNext || done != tt.wantDone {
				t.Errorf("tagPageAdvance(%d,%d,%d,%d,%d) = (%d,%v), want (%d,%v)",
					tt.from, tt.pageLen, tt.total, tt.up, tt.floor, next, done, tt.wantNext, tt.wantDone)
			}
		})
	}
}

// TestCollectPlaylistRefs covers both editorial item shapes (explicit
// playlist_shortcut and playlist feed containers) and cross-feed dedupe.
func TestCollectPlaylistRefs(t *testing.T) {
	const fixture = `{
		"feeds": [
			{"items": [
				{"content_type": "playlist_shortcut", "content_item": {
					"playlist_id": "2d25a0e5-320a-4ec3-ae4c-ec42fff8b54f",
					"playlist_name": "Golden Hour",
					"playlist_song_count": 19,
					"playlist_user_handle": "suno"}},
				{"content_type": "playlist_shortcut", "content_item": {
					"playlist_id": "893a59bb-1514-40f9-8280-3d3c2112c1ed",
					"playlist_name": "Sad Hour"}}
			]},
			{"items": [
				{"content_type": "generic_feed", "content_item": {
					"feed_container_type": "playlist",
					"feed_container_id": "0d597d0c-cdb2-4f9c-b4da-57931929f0d0"}},
				{"content_type": "playlist_shortcut", "content_item": {
					"playlist_id": "2d25a0e5-320a-4ec3-ae4c-ec42fff8b54f",
					"playlist_name": "Golden Hour"}},
				{"content_type": "banner", "content_item": {"id": "v6-release-banner-free"}}
			]}
		]
	}`
	var er editorialResponse
	if err := json.Unmarshal([]byte(fixture), &er); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	refs := collectPlaylistRefs(er)
	if len(refs) != 3 {
		t.Fatalf("refs = %d (%v), want 3", len(refs), refs)
	}
	if refs[0].id != "2d25a0e5-320a-4ec3-ae4c-ec42fff8b54f" || refs[0].name != "Golden Hour" || refs[0].songCount != 19 {
		t.Errorf("refs[0] = %+v", refs[0])
	}
	if refs[2].id != "0d597d0c-cdb2-4f9c-b4da-57931929f0d0" {
		t.Errorf("container ref = %+v", refs[2])
	}
}

// TestProfilePlaylistUnmarshal pins the profile `playlists` shape the creator
// crawl now consumes; a null-clip entry elsewhere in the profile must not
// disturb it. Fixture mirrors a live profile response (verified 2026-09-23).
func TestProfilePlaylistUnmarshal(t *testing.T) {
	const fixture = `{
		"handle": "lightjourner",
		"clips": [],
		"playlists": [
			{"id": "b22174d7-9ca5-480c-87bf-bf1e5e75ce3f", "name": "SSC ENTRIES",
			 "song_count": 5, "user_handle": "lightjourner", "is_public": true,
			 "is_hidden": false, "is_trashed": false},
			{"id": "2d25a0e5-320a-4ec3-ae4c-ec42fff8b54f", "name": "Private Mix",
			 "song_count": 3, "user_handle": "lightjourner", "is_public": false}
		]
	}`
	var pr profileResponse
	if err := json.Unmarshal([]byte(fixture), &pr); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(pr.Playlists) != 2 {
		t.Fatalf("playlists = %d", len(pr.Playlists))
	}
	if pr.Playlists[0].ID != "b22174d7-9ca5-480c-87bf-bf1e5e75ce3f" || pr.Playlists[0].SongCount != 5 {
		t.Errorf("playlists[0] = %+v", pr.Playlists[0])
	}
	if pr.Playlists[1].IsPublic == nil || *pr.Playlists[1].IsPublic {
		t.Errorf("private playlist IsPublic = %v", pr.Playlists[1].IsPublic)
	}
}
