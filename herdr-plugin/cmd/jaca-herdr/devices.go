package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// device mirrors Device's wire format (Sources/Core/Devices/Device.swift).
type device struct {
	ID       string `json:"id"`
	Platform string `json:"platform"`
	Model    string `json:"model"`
	State    string `json:"state"`
}

func (d device) displayModel() string {
	// The emulator AVD name can carry adb's "\r\nOK" suffix; show the first line.
	m := strings.TrimSpace(strings.SplitN(d.Model, "\n", 2)[0])
	if m == "" {
		return d.ID
	}
	return m
}

// platformName and stateLabel match DevicePlatform.displayName and DeviceState.label.
func (d device) platformName() string {
	switch d.Platform {
	case "android":
		return "Android"
	case "iosSimulator":
		return "iOS Simulator"
	case "iosDevice":
		return "iOS Device"
	case "mac":
		return "macOS"
	}
	return d.Platform
}

func (d device) stateLabel() string {
	switch d.State {
	case "connected":
		return "Connected"
	case "unauthorized":
		return "Unauthorized"
	case "offline":
		return "Offline"
	case "booted":
		return "Booted"
	case "shutdown":
		return "Shutdown"
	}
	return "Unknown"
}

func (d device) isReady() bool { return d.State == "connected" || d.State == "booted" }

// thisMac is Device.thisMac: the app lists it on its own, after the devices jacad finds.
var thisMac = device{ID: "mac", Platform: "mac", Model: "This Mac", State: "connected"}

const devicesTopic = "devices.list"

// syncTimeout bounds the calls the UI loop waits on, so a stalled jacad can't freeze the keys
// for callTimeout; teardownTimeout bounds the ones made while leaving a stream or the pane.
const (
	syncTimeout     = 5 * time.Second
	teardownTimeout = 2 * time.Second
)

// deviceOption is one thing a ready device offers: its title, as in the app's device menu
// (DeviceSidebarView.inspectMenu), the pane that does it and the name of the tab it opens in.
type deviceOption struct {
	title      string
	entrypoint string
	tab        string
}

// optionsFor are the options of a device in a network inspection mode (modeAgent or modeMITM).
// Network inspection runs the in-process agent or the device proxy, which exist for Android and
// the iOS Simulator only. This Mac has one option: its Chrome window.
func optionsFor(d device, mode string) []deviceOption {
	if d.Platform == "mac" {
		return []deviceOption{{"Inspect Network (Chrome)", "network", "Jaca network - "}}
	}
	options := []deviceOption{{"Start Logcat", "logs", "Jaca log - "}}
	if d.Platform == "android" || d.Platform == "iosSimulator" {
		// Named for how it captures, which the mode decides.
		title := "Inspect Network (Agent HTTP)"
		if mode == modeMITM {
			title = "Inspect Network (MITM HTTP)"
		}
		options = append(options, deviceOption{title, "network", "Jaca network - "})
	}
	// Offered for every device, as in the app: where it can't be done jacad says so.
	options = append(options, deviceOption{"Browse Database", "database", "Jaca database - "})
	return options
}

// devicePicker lists devices, then the options of the chosen one. Choosing an option opens it
// in a new Herdr tab (launch), or in this pane when there is no Herdr to open one.
type devicePicker struct {
	p      *pane
	launch bool
	mode   string // the network inspection mode, read once when the picker opens

	devices  []device
	loaded   bool
	selected int

	chosen    *device // set while the options step shows
	option    int
	launching bool   // a tab is being opened
	err       string // why the last tab didn't open, as Herdr reported it

	closeX0, closeX1 int // the close button's columns on the second row, as last drawn
}

// runDevicesPane is the picker: j/k move, Enter chooses, Esc goes back a step, q quits.
func runDevicesPane() int {
	return runPicker(os.Getenv("HERDR_BIN_PATH") != "" || os.Getenv("HERDR_ENV") != "")
}

func runPicker(launch bool) int {
	c, err := dial()
	if err != nil {
		fmt.Fprintln(os.Stderr, "jaca:", err)
		return 1
	}
	defer c.Close()
	if err := c.Subscribe(devicesTopic); err != nil {
		fmt.Fprintln(os.Stderr, "jaca:", err)
		return 1
	}
	mode := fetchMode(c)
	return runPane(c, func(p *pane) screen { return &devicePicker{p: p, launch: launch, mode: mode} })
}

// fetchMode reads the network inspection mode with network.mode. A jacad that doesn't answer,
// or one from before the mode, captures with the agent, so that is the mode then.
func fetchMode(c *client) string {
	var st netModeState
	if c.CallTimeout("network.mode", nil, &st, syncTimeout) != nil || (st.Mode != modeAgent && st.Mode != modeMITM) {
		return modeAgent
	}
	return st.Mode
}

func (d *devicePicker) handleEvent(ev event) {
	switch ev.Topic {
	case devicesTopic:
		var list []device
		if json.Unmarshal(ev.Data, &list) == nil {
			d.setDevices(list)
		}
	case "events.dropped":
		var note droppedNote
		if json.Unmarshal(ev.Data, &note) == nil && note.Topic == devicesTopic {
			// The skipped update may have been the latest list: fetch it.
			d.fetch()
		}
	}
}

func (d *devicePicker) fetch() {
	var list []device
	if d.p.c.CallTimeout("devices.list", nil, &list, syncTimeout) == nil {
		d.setDevices(list)
	}
}

func (d *devicePicker) setDevices(list []device) {
	d.devices, d.loaded = append(list[:len(list):len(list)], thisMac), true
	d.selected = clampIndex(d.selected, len(list))
}

func (d *devicePicker) handleKey(k []byte) bool {
	// A click on the close button is Esc.
	if m, ok := parseMouse(k); ok {
		if !m.press || m.button != 0 || m.y != 2 || m.x < d.closeX0 || m.x > d.closeX1 {
			return false
		}
		k = []byte{0x1b}
	}
	switch {
	case len(k) == 1 && (k[0] == 'q' || k[0] == 0x03):
		return true
	case isEsc(k):
		// Back a step; from the device list, out of the pane (the popup closes).
		if d.chosen == nil {
			return true
		}
		d.chosen, d.err = nil, ""
	case isUp(k):
		d.move(-1)
	case isDown(k):
		d.move(1)
	case isEnter(k):
		d.confirm()
	}
	return false
}

func (d *devicePicker) move(by int) {
	if d.chosen != nil {
		d.option = clampIndex(d.option+by, len(optionsFor(*d.chosen, d.mode)))
		return
	}
	d.selected = clampIndex(d.selected+by, len(d.devices))
}

func (d *devicePicker) confirm() {
	if d.chosen == nil {
		// Like the app's device row: only a ready device opens its options.
		if d.selected < len(d.devices) && d.devices[d.selected].isReady() {
			dev := d.devices[d.selected]
			d.chosen, d.option, d.err = &dev, 0, ""
		}
		return
	}
	if d.launching {
		return
	}
	dev := *d.chosen
	options := optionsFor(dev, d.mode)
	option := options[clampIndex(d.option, len(options))]
	if !d.launch {
		switch option.entrypoint {
		case "network":
			d.p.screen = newNetViewer(d.p, dev, d.back)
		case "database":
			d.p.screen = newDBViewer(d.p, dev, d.back)
		default:
			d.p.screen = newLogViewer(d.p, dev, d.back)
		}
		return
	}
	d.launching, d.err = true, ""
	go func() {
		err := openDeviceTab(dev, option)
		d.p.post(func() {
			d.launching = false
			if err != nil {
				d.err = err.Error()
				return
			}
			d.p.quit = true
		})
	}()
}

// back returns from a viewer that ran in this pane. Device updates went to the viewer meanwhile.
func (d *devicePicker) back() {
	d.chosen = nil
	d.p.screen = d
	d.fetch()
}

func (d *devicePicker) leave(bool) {}

func (d *devicePicker) draw() {
	rows, cols := termSize()
	var frame []string
	line := func(s string) { frame = append(frame, s) }

	room := rows - 3
	if d.err != "" {
		room--
	}
	room = max(1, room)
	// The close button at the top right, like Herdr's overlays: it goes back from the options.
	// It sits a row down and a cell in from the popup's border.
	header := func(text, label string) string {
		d.closeX0, d.closeX1 = 0, 0
		w := cols - len(label) - 1
		if w < 0 {
			return sgrBold + clip(text, cols) + sgrReset
		}
		d.closeX0, d.closeX1 = w+1, w+len(label)
		return sgrBold + fit(text, w) + sgrReset + closeButton(label)
	}
	line("")
	room--
	if d.chosen != nil {
		line(header(sanitize(d.chosen.displayModel()), escBack))
		line("")
		if d.err != "" {
			line(sgrRed + fit(sanitize(d.err), cols) + sgrReset)
		}
		for i, option := range optionsFor(*d.chosen, d.mode) {
			if i >= room {
				break
			}
			line(listRow(clip(option.title, max(0, cols-2)), i == d.option, cols))
		}
		paintRows(panelFrame(frame, rows, cols))
		return
	}

	// No heading: the popup's border already carries the pane's title.
	line(header("", escClose))
	line("") // a row between the button and the selected row's highlight
	switch {
	case !d.loaded:
	case len(d.devices) == 0:
		line("No devices connected")
	default:
		start := listWindow(d.selected, room)
		for i := start; i < len(d.devices) && i < start+room; i++ {
			dev := d.devices[i]
			name := sgrBold + fit(sanitize(dev.displayModel()), max(10, cols/2-4)) + sgrReset
			state := dev.stateLabel()
			if !dev.isReady() {
				state = sgrDim + state + sgrReset
			}
			line(listRow(name+"  "+fit(dev.platformName(), 14)+"  "+state, i == d.selected, cols))
		}
	}
	paintRows(panelFrame(frame, rows, cols))
}

// panelFrame fills a whole pane with the panel background, as the picker's popup shows it.
func panelFrame(frame []string, rows, cols int) []string {
	for len(frame) < rows {
		frame = append(frame, "")
	}
	for i, row := range frame {
		frame[i] = onPanel(row, cols)
	}
	return frame
}

// deviceEnv carries the chosen device (its wire JSON) from the picker to the logs pane.
const deviceEnv = "JACA_HERDR_DEVICE"

// herdrContext is the part of HERDR_PLUGIN_CONTEXT_JSON this plugin reads.
type herdrContext struct {
	WorkspaceID    string `json:"workspace_id"`
	FocusedPaneCwd string `json:"focused_pane_cwd"`
	WorkspaceCwd   string `json:"workspace_cwd"`
	Worktree       *struct {
		CheckoutPath string `json:"checkout_path"`
		RepoRoot     string `json:"repo_root"`
	} `json:"worktree"`
}

func readHerdrContext() herdrContext {
	var ctx herdrContext
	if raw := os.Getenv("HERDR_PLUGIN_CONTEXT_JSON"); raw != "" {
		_ = json.Unmarshal([]byte(raw), &ctx)
	}
	return ctx
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// openDeviceTab opens an option's pane for d in a new Herdr tab named after the device.
func openDeviceTab(d device, option deviceOption) error {
	raw, err := json.Marshal(d)
	if err != nil {
		return err
	}
	return openTab(option.entrypoint, option.tab+d.displayModel(), deviceEnv+"="+string(raw))
}

// openTab opens one of the plugin's panes in a new Herdr tab called name, in the workspace the
// picker was opened from, and has the tab focused once the picker has exited. env are the
// NAME=value pairs the pane is started with.
func openTab(entrypoint, name string, env ...string) error {
	herdr := envOr("HERDR_BIN_PATH", "herdr")
	args := []string{"plugin", "pane", "open", "--plugin", envOr("HERDR_PLUGIN_ID", "dev.srsouza.jaca"),
		"--entrypoint", entrypoint, "--placement", "tab", "--focus"}
	for _, pair := range env {
		args = append(args, "--env", pair)
	}
	// A plugin pane gets the context JSON; a popup opened by a custom keybinding gets the id alone.
	if ws := envOr("HERDR_ACTIVE_WORKSPACE_ID", readHerdrContext().WorkspaceID); ws != "" {
		args = append(args, "--workspace", ws)
	}
	out, err := exec.Command(herdr, args...).CombinedOutput()
	var reply struct {
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
		Result struct {
			PluginPane struct {
				Pane struct {
					TabID string `json:"tab_id"`
				} `json:"pane"`
			} `json:"plugin_pane"`
		} `json:"result"`
	}
	_ = json.Unmarshal(out, &reply)
	switch {
	case reply.Error != nil && reply.Error.Message != "":
		return errors.New(reply.Error.Message)
	case err != nil:
		if text := strings.TrimSpace(string(bytes.SplitN(bytes.TrimSpace(out), []byte("\n"), 2)[0])); text != "" {
			return errors.New(text)
		}
		return err
	}
	if tab := reply.Result.PluginPane.Pane.TabID; tab != "" {
		// The tab is open either way; the name tells it apart from the other tabs.
		_ = exec.Command(herdr, "tab", "rename", tab, name).Run()
		focusTabAfterExit(tab)
	}
	return nil
}

// focusTabAfterExit starts a detached copy of this binary that focuses tab once this process is
// gone. A popup is modal and Herdr puts the focus back where it was when the popup closes, so
// the --focus given while it is still open doesn't last.
func focusTabAfterExit(tab string) {
	self, err := os.Executable()
	if err != nil {
		return
	}
	cmd := exec.Command(self, "focus-tab", tab, strconv.Itoa(os.Getpid()))
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} // outlives the popup's terminal
	_ = cmd.Start()
}

// focusTabWhenGone waits (up to 5s) for process pid to exit, then focuses tab.
func focusTabWhenGone(tab string, pid int) int {
	for i := 0; i < 100 && syscall.Kill(pid, 0) == nil; i++ {
		time.Sleep(50 * time.Millisecond)
	}
	// Herdr restores the previous focus as it closes the popup; give it a moment to finish.
	time.Sleep(150 * time.Millisecond)
	if err := exec.Command(envOr("HERDR_BIN_PATH", "herdr"), "tab", "focus", tab).Run(); err != nil {
		return 1
	}
	return 0
}

func (d device) isMac() bool { return d.Platform == "mac" }
