package main

// mqtt.go — retained MQTT contract + HA discovery publication.

import (
	"encoding/json"
	"fmt"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
)

type mqttPublisher struct{ c mqtt.Client }

func newMQTTPublisher(url string) (*mqttPublisher, error) {
	opts := mqtt.NewClientOptions().
		AddBroker(url).
		SetClientID("roster-writer").
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetConnectRetryInterval(10 * time.Second).
		SetKeepAlive(30 * time.Second)
	c := mqtt.NewClient(opts)
	tok := c.Connect()
	if !tok.WaitTimeout(15 * time.Second) {
		return nil, fmt.Errorf("connect timeout")
	}
	if err := tok.Error(); err != nil {
		return nil, err
	}
	return &mqttPublisher{c: c}, nil
}

func (p *mqttPublisher) close() { p.c.Disconnect(250) }

func (p *mqttPublisher) pub(topic, payload string) error {
	tok := p.c.Publish(topic, 1, true, payload)
	if !tok.WaitTimeout(10 * time.Second) {
		return fmt.Errorf("publish %s: timeout", topic)
	}
	return tok.Error()
}

// publishContract publishes the state, the JSON attributes, and the HA
// discovery config — all retained. The attribute set mirrors the n8n-era
// sensor contract (PARITY.md) plus writer stamps for degradation watching.
func (p *mqttPublisher) publishContract(cfg config, c Contract, now time.Time) error {
	attrs := map[string]any{
		"shift_date":         c.ShiftDate,
		"day":                c.Day,
		"start_local":        c.StartLocal,
		"end_local":          c.EndLocal,
		"location":           c.Location,
		"duration_hours":     c.DurationHours,
		"starts_in_hours":    c.StartsInHours,
		"end_iso":            c.EndISO,
		"this_week_count":    c.ThisWeekCount,
		"this_week_hours":    c.ThisWeekHours,
		"upcoming":           c.Upcoming,
		"writer_updated_utc": now.UTC().Format("2006-01-02 15:04:05"),
		"writer":             "roster-writer",
	}
	ab, err := json.Marshal(attrs)
	if err != nil {
		return err
	}
	disc := map[string]any{
		"name":                  "Next Shift",
		"unique_id":             "jupiter_" + cfg.objectID,
		"object_id":             cfg.objectID,
		"state_topic":           cfg.topicBase + "/state",
		"json_attributes_topic": cfg.topicBase + "/attributes",
		"device_class":          "timestamp",
		"icon":                  "mdi:calendar-clock",
		"device": map[string]any{
			"identifiers":  []string{"jupiter_platform"},
			"name":         "Jupiter Platform",
			"manufacturer": "Jupiter Quarters",
		},
	}
	db, err := json.Marshal(disc)
	if err != nil {
		return err
	}
	if err := p.pub(cfg.topicBase+"/state", c.State); err != nil {
		return err
	}
	if err := p.pub(cfg.topicBase+"/attributes", string(ab)); err != nil {
		return err
	}
	return p.pub(cfg.discoveryPre+"/sensor/jupiter_"+cfg.objectID+"/config", string(db))
}
