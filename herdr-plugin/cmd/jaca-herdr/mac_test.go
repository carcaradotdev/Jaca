package main

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestThisMacIsListedWithItsOneOption(t *testing.T) {
	d := &devicePicker{}
	d.setDevices([]device{{ID: "emulator-5554", Platform: "android", State: "device"}})
	if len(d.devices) != 2 || d.devices[1] != thisMac {
		t.Fatalf("devices: %+v", d.devices)
	}
	d.setDevices(nil)
	if len(d.devices) != 1 || d.devices[0] != thisMac {
		t.Fatalf("without devices: %+v", d.devices)
	}
	if !thisMac.isReady() || thisMac.platformName() != "macOS" {
		t.Errorf("This Mac: ready %v, platform %q", thisMac.isReady(), thisMac.platformName())
	}
	if got := optionsFor(thisMac, modeAgent); !reflect.DeepEqual(got, []deviceOption{{"Inspect Network (Chrome)", "network", "Jaca network - "}}) {
		t.Errorf("options: %+v", got)
	}
}

// macCalls sends keys to a capture of This Mac and returns the methods they called.
func macCalls(t *testing.T, running bool, keys ...string) ([]string, *netViewer) {
	t.Helper()
	v := testNetViewer(t)
	v.device = thisMac
	v.state = netState{IsRunning: running, HasRunningSource: running, HasSelectedMode: true, SelectedSourceID: "browser"}
	c, calls := pipeClient(t)
	v.p.c = c
	for _, k := range keys {
		v.handleKey([]byte(k))
	}
	deadline := time.Now().Add(time.Second)
	for len(calls()) < len(keys) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	var methods []string
	for _, call := range calls() {
		methods = append(methods, call["method"].(string))
		if p, _ := call["params"].(map[string]any); call["method"] == "network.select" && p["sourceID"] != "browser" {
			t.Errorf("select params: %v", p)
		}
	}
	return methods, v
}

func TestMacCaptureKeys(t *testing.T) {
	if got, v := macCalls(t, true, "b", "a"); !reflect.DeepEqual(got, []string{"network.openBrowser"}) || v.focus == netApps {
		t.Errorf("running: %v, focus %v", got, v.focus)
	}
	if got, _ := macCalls(t, false, "b", "p"); !reflect.DeepEqual(got, []string{"network.select"}) {
		t.Errorf("stopped: %v", got)
	}
}

func TestMacToolbarAndHelp(t *testing.T) {
	v := testNetViewer(t)
	v.device = thisMac
	v.state = netState{IsRunning: true, HasRunningSource: true, HasSelectedMode: true}
	bar := strings.Join(v.toolbar(160, 1), "")
	if !strings.Contains(bar, "Open Chrome") || !strings.Contains(bar, "browser") || strings.Contains(bar, "Inspect app") {
		t.Errorf("toolbar: %q", bar)
	}
	if keys := v.helpKeys(); keys[2] != [2]string{"b", "Open Chrome"} {
		t.Errorf("help: %v", keys[2])
	}
	v.state.IsRunning = false
	if bar := strings.Join(v.toolbar(160, 1), ""); strings.Contains(bar, "Open Chrome") {
		t.Errorf("stopped toolbar: %q", bar)
	}
}
