package main

import "testing"

// The network option of a device is named for the mode it captures with.
func TestNetworkOptionLabelByMode(t *testing.T) {
	label := func(platform, mode string) string {
		for _, option := range optionsFor(device{ID: "d", Platform: platform, State: "connected"}, mode) {
			if option.entrypoint == "network" {
				return option.title
			}
		}
		return ""
	}
	cases := []struct{ platform, mode, want string }{
		{"android", modeAgent, "Inspect Network (Agent HTTP)"},
		{"iosSimulator", modeAgent, "Inspect Network (Agent HTTP)"},
		{"android", modeMITM, "Inspect Network (MITM HTTP)"},
		{"iosSimulator", modeMITM, "Inspect Network (MITM HTTP)"},
		{"mac", modeAgent, "Inspect Network (Chrome)"},
		{"mac", modeMITM, "Inspect Network (Chrome)"},
		{"iosDevice", modeMITM, ""},
		{"android", "", "Inspect Network (Agent HTTP)"},
	}
	for _, c := range cases {
		if got := label(c.platform, c.mode); got != c.want {
			t.Errorf("%s in %q mode: %q, want %q", c.platform, c.mode, got, c.want)
		}
	}
}

// fetchMode falls back to the agent when jacad's answer names no mode it knows.
func TestFetchModeFallsBackToAgent(t *testing.T) {
	c, calls := pipeClient(t) // answers every call with {}
	if got := fetchMode(c); got != modeAgent {
		t.Errorf("fetchMode = %q, want %q", got, modeAgent)
	}
	if got := waitCalls(t, calls, 1); got[0]["method"] != "network.mode" {
		t.Errorf("calls: %v", got)
	}
}
