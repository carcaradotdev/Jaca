package main

import (
	"strings"
	"time"
)

// The network inspection mode, the capture chooser it decides, and the banner that installs
// Jaca's certificate for a device proxy capture.

// The titles of the two modes, as in the app's Settings.
const (
	agentModeTitle = "Agent HTTPS debugging"
	mitmModeTitle  = "MITM HTTPS debugging"
)

// How long the calls that change a device may take: a mode switch stops captures and waits for
// their devices to be released, and a rooted install or a simulator reboot runs several commands.
const (
	setModeTimeout = 2 * time.Minute
	deviceTimeout  = 3 * time.Minute
)

// openModeMenu is the M key: a menu of the two modes, on the current one.
func (v *netViewer) openModeMenu() {
	menu := &popupMenu{x: 2, y: 2, items: []menuItem{
		{agentModeTitle, func() { v.requestMode(modeAgent) }},
		{mitmModeTitle, func() { v.requestMode(modeMITM) }},
	}}
	if v.mode == modeMITM {
		menu.selected = 1
	}
	v.menu, v.focus = menu, netMenu
}

// requestMode asks jacad to switch the mode. The switch stops the captures the new mode doesn't
// offer, this one too, and jacad publishes the new mode and capture state when it is done.
func (v *netViewer) requestMode(mode string) {
	if mode == v.mode {
		return
	}
	v.err = ""
	go func() {
		err := v.p.c.CallTimeout("network.setMode", map[string]any{"mode": mode}, nil, setModeTimeout)
		v.p.post(func() {
			if err != nil {
				v.err = err.Error()
				return
			}
			v.setMode(netModeState{Mode: mode})
		})
	}()
}

// chooserRows draws the capture chooser into out, a column w cells wide that may grow to n rows:
// the device, then one row for each source the mode offers, the selected one reversed. It
// records each row's screen rows for the mouse.
func (v *netViewer) chooserRows(out []string, w, n int) []string {
	add := func(s string) {
		if len(out) < n {
			out = append(out, padStyled(s, w))
		}
	}
	add("")
	add("  " + sgrBold + clip(sanitize(v.device.displayModel()), w-2) + sgrReset)
	sources := v.chooserSources()
	if len(sources) == 0 {
		return out // nothing this device can capture with in the current mode
	}
	add("  " + sgrDim + clip("Choose how to capture traffic", w-2) + sgrReset)
	v.chooserRow = clampIndex(v.chooserRow, len(sources))
	for i, id := range sources {
		title := " Inspect app "
		detail := "Inspect one debuggable app in-process — call stacks behind each request, no CA."
		if id == sourceMITM {
			title, detail = " Device proxy ", transportMITMProxy.captureDetail()
		}
		style := sgrBold
		if i == v.chooserRow {
			style = sgrRev
		}
		add("")
		first := v.listTop - 1 + len(out)
		add("  " + style + title + sgrReset)
		add("")
		add("  " + sgrDim + clip(detail, w-2) + sgrReset)
		if id == sourceMITM && v.device.Platform == "iosSimulator" {
			add("  " + sgrDim + clip(simulatorSystemProxyNote, w-2) + sgrReset)
		}
		v.chooserHits = append(v.chooserHits, hit{x0: first, x1: v.listTop - 1 + len(out) - 1})
	}
	return out
}

// setupBanner is what the certificate banner shows besides its prompt: a call in flight, or
// what the last one did.
type setupBanner struct {
	busy        string // the call in flight, "" for none
	outcome     string // what the last install or reboot did, "" for nothing yet
	failed      bool   // the outcome is an error
	offerReboot bool   // a simulator install is done, and a reboot makes its apps trust the certificate
}

// showsSetupBanner is the certificate banner: the device proxy needs Jaca's certificate on the
// device and it isn't there yet, or an install or reboot is running or has a result to show.
func (v *netViewer) showsSetupBanner() bool {
	if !v.opened || v.device.isMac() {
		return false
	}
	return (v.state.ProxyNeedsSetup && !v.state.CAReady) || v.setup.busy != "" || v.setup.outcome != ""
}

// canInstallCA is whether I installs the certificate: on an Android device or an iOS Simulator,
// with the banner shown or the device proxy chosen, and no install or reboot running.
func (v *netViewer) canInstallCA() bool {
	if v.device.Platform != "android" && v.device.Platform != "iosSimulator" {
		return false
	}
	return v.setup.busy == "" && (v.showsSetupBanner() || v.sourceID() == sourceMITM)
}

// installCA is the I key: jacad installs Jaca's certificate on the capture's device, into the
// system store where it can, else into Download for the user to install.
func (v *netViewer) installCA() {
	if !v.canInstallCA() {
		return
	}
	v.err = ""
	v.setup = setupBanner{busy: "Installing Jaca's certificate…"} // COPY-PENDING
	go func() {
		var result installCAResult
		err := v.p.c.CallTimeout("network.installCA", map[string]any{"id": v.id}, &result, deviceTimeout)
		v.p.post(func() { v.setup = installOutcome(result, err) })
	}()
}

// installOutcome is what the banner shows after network.installCA.
func installOutcome(result installCAResult, err error) setupBanner {
	switch {
	case err != nil:
		return setupBanner{outcome: err.Error(), failed: true}
	case result.Outcome == "installed" && result.RebootAdvised:
		return setupBanner{outcome: "Jaca's certificate is installed in the simulator. Reboot it so its apps trust the certificate: B reboot · x dismiss", offerReboot: true} // COPY-PENDING
	case result.Outcome == "installed":
		return setupBanner{outcome: "Jaca's certificate is installed in the device's system store."}
	case result.Outcome == "needsUser":
		return setupBanner{outcome: "Jaca copied its certificate to Download/JacaProxyCA.pem. Install it in Settings > Security > Encryption & credentials > Install a certificate > CA certificate."}
	case result.Message != "":
		return setupBanner{outcome: result.Message, failed: true}
	}
	// An outcome this client doesn't know: show the prompt again rather than invent a result.
	return setupBanner{}
}

// rebootSimulator is the B key after a simulator install: jacad reboots the simulator, so its
// apps trust the new certificate.
func (v *netViewer) rebootSimulator() {
	if v.device.Platform != "iosSimulator" || v.setup.busy != "" {
		return
	}
	v.err = ""
	v.setup = setupBanner{busy: "Rebooting the simulator…"} // COPY-PENDING
	go func() {
		err := v.p.c.CallTimeout("network.rebootSimulator", map[string]any{"id": v.id}, nil, deviceTimeout)
		v.p.post(func() {
			if err != nil {
				v.setup = setupBanner{outcome: err.Error(), failed: true, offerReboot: true}
				return
			}
			v.setup = setupBanner{outcome: "The simulator restarted. Its apps now trust Jaca's certificate."} // COPY-PENDING
		})
	}()
}

// dismissSetup is the x key: it hides the banner, and tells jacad that the setup prompt was
// dismissed.
func (v *netViewer) dismissSetup() {
	if v.setup.busy != "" {
		return // the result is still to come
	}
	v.setup = setupBanner{}
	if v.state.ProxyNeedsSetup {
		v.state.ProxyNeedsSetup = false // jacad publishes the same once it has cleared it
		v.call("network.clearProxyNeedsSetup", map[string]any{"id": v.id})
	}
}

// setupBannerMaxRows is the most rows the certificate banner takes; longer text is cut.
const setupBannerMaxRows = 3

// setupBanner draws the certificate banner, cols cells wide on every row: the prompt, a call in
// flight, or what the last call did, wrapped onto up to three rows.
func (v *netViewer) setupBanner(cols int) []string {
	if cols < 4 {
		return []string{strings.Repeat(" ", max(0, cols))}
	}
	text, style := "Install Jaca's certificate on the device: I install · x dismiss", sgrYellow
	switch {
	case v.setup.busy != "":
		text = v.setup.busy
	case v.setup.outcome != "":
		text = v.setup.outcome
		if v.setup.failed {
			style = sgrRed
		}
	}
	lines := wrapCells(text, cols-2)
	if len(lines) > setupBannerMaxRows {
		lines = lines[:setupBannerMaxRows]
	}
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		out = append(out, padStyled(style+"▌"+sgrReset+" "+l, cols))
	}
	return out
}

// simulatorSystemProxyNote is CaptureSourceRegistry.simulatorSystemProxyNote: the simulator's
// device proxy changes the whole Mac, so its chooser row says so before the start.
const simulatorSystemProxyNote = "On the iOS Simulator this sets the Mac's system proxy while the capture runs. Other Mac apps pass through and are not recorded." // COPY-PENDING
