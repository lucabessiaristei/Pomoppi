// SettingsWindow.swift — a real titled top-level window (unlike
// WidgetWindow's layered popup) holding a SysTabControl32 with the same 6
// tabs/order as macOS's SettingsView.swift (General, Rhythm, Appearance,
// Keys, Sound, Diary — Window renamed General and moved first, Color
// scheme moved into it from Appearance, SETTINGS_PLAN.md S2; Log folded
// into Diary in the 2026-09-20 redesign), bound directly to SettingsStore.
// One singleton instance, mirroring macOS's single reused `Settings` scene;
// see WINDOWS_PORT_PLAN.md's W6/W7 entry for how this file grew phase by
// phase.
import Foundation
import PomoppiCore
import PomoppiRender
import WinSDK

// Same "WNDPROC can't capture, dispatch through a shared instance" shape as
// pomoppiWidgetWndProc in WidgetWindow.swift.
private func pomoppiSettingsWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let window = SettingsWindow.shared, let hwnd, window.hwnd == hwnd else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    return window.handleMessage(message: message, wParam: wParam, lParam: lParam)
}

// A page's real controls (checkboxes/steppers, added in part 2) are its own
// children, not the top-level settings window's — Win32 always sends
// WM_COMMAND (BN_CLICKED, EN_KILLFOCUS) and WM_NOTIFY (UDN_DELTAPOS) to a
// control's *immediate* parent, which is the page, never a grandparent.
// Plain DefWindowProcW (the page class's part-1 WndProc, back when a page
// only ever hosted one placeholder STATIC with nothing to route) just
// swallows both, so none of it ever reached pomoppiSettingsWndProc above —
// confirmed live: checkboxes still flipped their own visual check state
// (BS_AUTOCHECKBOX manages that itself, independent of whoever's listening)
// and stepper arrows still nudged the displayed number by the up-down's own
// unmodified default of 1 (also independent of any listener), but nothing
// ever reached handleCommand/handleUpDownDeltaPos, so settingsStore was
// never actually updated and ringSeconds' step-of-5 override never ran.
// Forwarding just these two message types up to the real parent (the
// settings window) is enough — handleMessage's own dispatch already
// resolves the sending control by its own HWND out of wParam/lParam, so it
// doesn't care which window physically received the message.
// WM_KEYDOWN/WM_SYSKEYDOWN forward the same way, added in W7 for the Keys
// tab's shortcut recorder: unlike WM_COMMAND/WM_NOTIFY (always sent to a
// control's immediate parent regardless of focus), keyboard messages go
// straight to whichever HWND currently owns input focus — the settings
// window explicitly hands the Keys page that focus while a row is
// recording (see SettingsWindow.startRecording) specifically so its own
// keydown arrives here to forward, rather than silently going nowhere.
// WM_SYSKEYDOWN has to be included too: Windows reclassifies any key
// pressed while Alt is already held as a "system" keydown (normally meant
// for menu mnemonics), and every one of Shortcuts.actions' own default
// accelerators uses Alt — without it, no default binding could ever be
// re-recorded to a new Alt combo at all.
// WM_DRAWITEM forwards the same way, added in W7 for the Appearance tab's
// owner-drawn picker cards (BS_OWNERDRAW buttons showing a rendered
// PixelCanvas preview instead of stock button chrome) — like
// WM_COMMAND/WM_NOTIFY, Windows always sends WM_DRAWITEM to the control's
// immediate parent, never a grandparent. WM_HSCROLL forwards the same way
// too, added for the opacity Trackbar32: a horizontal trackbar's scroll
// notification is, like BN_CLICKED, delivered to its immediate parent.
// WM_ERASEBKGND and WM_CTLCOLORSTATIC/WM_CTLCOLORBTN/WM_CTLCOLOREDIT forward
// the same way too, added for dark mode: WM_ERASEBKGND is sent to whichever
// window is actually being erased (a page itself, not the settings window),
// and WM_CTLCOLORSTATIC/BTN/EDIT are sent to a STATIC/BUTTON/EDIT's
// immediate parent — which is always the page, same story as WM_COMMAND/
// WM_NOTIFY above, not the settings window either way. See applyTheme/
// handleEraseBackground/handleCtlColor for what each one actually does once
// it arrives there.
//
private func pomoppiSettingsPageWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if message == UINT(WM_COMMAND) || message == UINT(WM_NOTIFY) || message == UINT(WM_KEYDOWN) || message == UINT(WM_SYSKEYDOWN) || message == UINT(WM_DRAWITEM) || message == UINT(WM_HSCROLL) || message == UINT(WM_ERASEBKGND) || message == UINT(WM_CTLCOLORSTATIC) || message == UINT(WM_CTLCOLORBTN) || message == UINT(WM_CTLCOLOREDIT),
       let hwnd, let parent = GetParent(hwnd) {
        return SendMessageW(parent, message, wParam, lParam)
    }
    return DefWindowProcW(hwnd, message, wParam, lParam)
}

// The Appearance page's custom scroll rail (added to replace the native
// WS_VSCROLL scrollbar the user found visually dated) is its own window
// class rather than a BS_OWNERDRAW BUTTON reusing pageClassName's
// WM_DRAWITEM-via-parent-forwarding pattern above: a real owner-draw
// BUTTON's own default WndProc captures WM_LBUTTONDOWN/WM_MOUSEMOVE/
// WM_LBUTTONUP itself to drive its own press/release click tracking (fine
// for every other owner-drawn control on this tab, which only ever needs a
// single click), which would need subclassing to get out of the way for a
// dragged thumb's continuous WM_MOUSEMOVE deltas. Simpler to own the
// WndProc outright, the same "can't capture, dispatch through the shared
// instance" shape as pomoppiSettingsWndProc/pomoppiSettingsPageWndProc
// above, and build a real DRAWITEMSTRUCT by hand on WM_PAINT so painting
// still goes through handleDrawItem's existing dispatch (see
// SettingsWindow.handleScrollRailMessage) rather than inventing a second
// drawing path just for this one control.
private func pomoppiScrollRailWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let window = SettingsWindow.shared, let hwnd, window.appearanceScrollRail == hwnd else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    return window.handleScrollRailMessage(hwnd: hwnd, message: message, wParam: wParam, lParam: lParam)
}

// SysTabControl32 has no dark visual style (setControlDarkTheme's own
// comment below has the confirmed-no-op finding for it specifically) —
// this subclasses the stock tab control via comctl32's SetWindowSubclass
// rather than replacing it with an owned window class outright, so light
// mode keeps the native control byte-for-byte. Only WM_PAINT/WM_ERASEBKGND
// are intercepted, and only while isDarkModeActive is true; everything
// else (and every message at all in light mode) falls straight through to
// DefSubclassProc, comctl32's documented "call the original proc" for this
// subclassing API — unlike GWLP_WNDPROC's classic dance, SetWindowSubclass
// needs no manually-stored previous-proc pointer for that. Same "can't
// capture, dispatch through the shared instance" shape as every other
// WndProc free function in this file.
private func pomoppiTabControlSubclassProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM, _ subclassID: UINT_PTR, _ refData: DWORD_PTR) -> LRESULT {
    guard let window = SettingsWindow.shared, let hwnd, window.tabControl == hwnd, window.isDarkModeActive,
          message == UINT(WM_PAINT) || message == UINT(WM_ERASEBKGND) else {
        return DefSubclassProc(hwnd, message, wParam, lParam)
    }
    return window.handleTabControlPaintMessage(hwnd: hwnd, message: message)
}

// A stepper's own two children each have a dark-mode gap no visual style
// covers, so both get the same "can't capture, dispatch through the
// shared instance" WndProc-takeover treatment as pomoppiTabControlSubclassProc
// just above, installed once per stepper (addStepper) rather than a
// single shared control — one proc for both rather than two nearly-
// identical ones, dispatching on which stepper field the hwnd actually
// is (isStepperUpDown/isStepperEdit, non-private for exactly this
// reason):
//   - msctls_updown32 (the arrow buttons): no dark visual style at all —
//     same confirmed-no-op finding setControlDarkTheme's own comment
//     already has for it specifically (DarkMode_Explorer restyles the
//     buddy edit's background, never the up-down itself). Takes over
//     WM_PAINT/WM_ERASEBKGND — see handleUpDownPaintMessage.
//   - the buddy EDIT: setControlDarkTheme does restyle its background
//     (see that function's own comment) and handleCtlColor's
//     WM_CTLCOLOREDIT case fixes its text, but neither touches the
//     WS_EX_CLIENTEDGE sunken border DefWindowProc draws on WM_NCPAINT,
//     which stayed bright system white — confirmed live via screenshot.
//     Takes over WM_NCPAINT only — see handleStepperEditNCPaint.
private func pomoppiStepperSubclassProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM, _ subclassID: UINT_PTR, _ refData: DWORD_PTR) -> LRESULT {
    guard let window = SettingsWindow.shared, let hwnd, window.isDarkModeActive else {
        return DefSubclassProc(hwnd, message, wParam, lParam)
    }
    if window.isStepperUpDown(hwnd), message == UINT(WM_PAINT) || message == UINT(WM_ERASEBKGND) {
        return window.handleUpDownPaintMessage(hwnd: hwnd, message: message)
    }
    if window.isStepperEdit(hwnd), message == UINT(WM_NCPAINT) {
        return window.handleStepperEditNCPaint(hwnd: hwnd)
    }
    return DefSubclassProc(hwnd, message, wParam, lParam)
}

final class SettingsWindow {
    // Only one settings window ever exists at a time — show(settingsStore:)
    // is the sole entry point, mirroring macOS's single reused `Settings`
    // scene (see AppDelegate.showSettingsWindow's invariant in CLAUDE.md).
    static var shared: SettingsWindow?

    let hwnd: HWND
    private let settingsStore: SettingsStore
    // Owned by main.swift (the same instance the timer's onPhaseComplete
    // logs through) — the Diary tab's Logging section reads its
    // synchronous, nonisolated fileSizeBytes()/eraseAllSync() helpers
    // directly (see SessionLogger's own comments for why those two are
    // safe to call off-actor from a synchronous Win32 message loop with
    // no MainActor-integrated executor to hop back through).
    private let sessionLogger: SessionLogger
    // Owned by main.swift (the same instance the timer's onPhaseComplete
    // plays through) — the Sound tab's Play button plays the selected
    // pack's focus-end sound through it directly.
    private let chimePlayer: ChimePlayer
    // Owned by main.swift (WidgetWindow's own instance) — the Keys tab's
    // shortcut recorder needs to unregister every live global hotkey while
    // capturing a new one (see startRecording below), and reregisterShortcuts
    // re-applies the table afterward via main.swift's own registration logic.
    private let globalShortcutManager: GlobalShortcutManager
    private let reregisterShortcuts: () -> Void
    // Owned by main.swift (WidgetWindow's own instance) — the footer strip
    // reads/triggers checks through it directly, same "own object passed
    // in, no separate view-model wrapper" shape as sessionLogger/chimePlayer
    // above.
    private let updateChecker: AppUpdateChecker
    // Not `private` — same reason `hwnd`/`appearanceScrollRail` aren't:
    // pomoppiTabControlSubclassProc needs it to identify which HWND it's
    // dispatching for, same shape as every other WndProc free function in
    // this file.
    var tabControl: HWND?
    private var pages: [HWND] = []

    // WM_COMMAND's lParam is always the sending control's HWND regardless
    // of control type, and WM_NOTIFY's NMHDR.hwndFrom is the same for
    // common controls — both dispatch tables below are looked up by HWND
    // rather than by a hand-rolled resource ID, since there's no dialog
    // template/resource file in this codebase to hang IDs off of.
    private struct CheckboxControl {
        let hwnd: HWND
        let onToggle: (Bool) -> Void
    }

    // A numeric stepper is a buddy-paired EDIT + msctls_updown32; tracked
    // by both HWNDs since WM_COMMAND (EN_KILLFOCUS, from the edit) and
    // WM_NOTIFY (UDN_DELTAPOS, from the up-down) arrive on different HWNDs
    // for the same logical control.
    private struct StepperControl {
        let editHwnd: HWND
        let upDownHwnd: HWND
        let min: Int32
        let max: Int32
        let step: Int32
        let onChange: (Int32) -> Void
    }

    private var checkboxes: [CheckboxControl] = []
    private var steppers: [StepperControl] = []

    // Same HWND-keyed dispatch shape as the two above, for the Keys tab's
    // plain push buttons (Restore Default Shortcuts, and each row's own
    // recorder button — its onClick just toggles recording, see buildKeysTab).
    private struct PushButtonControl {
        let hwnd: HWND
        let onClick: () -> Void
    }
    private var pushButtons: [PushButtonControl] = []

    // The plain (non-owner-drawn) push buttons among pushButtons above —
    // pushButtons also holds every owner-drawn card/swatch/scale option
    // (they all fire the same BN_CLICKED), so this is tracked separately
    // rather than filtered out of that list, purely so applyTheme has
    // something to hand to setControlDarkTheme (see addButton, the only
    // place this is appended to).
    private var plainPushButtons: [HWND] = []

    // A shortcut row's own button, tracked separately from pushButtons so
    // refreshShortcutButtons can look one up by action id after a binding
    // changes (write, cancel, or Restore Default Shortcuts all funnel
    // through it).
    private struct ShortcutRecorderControl {
        let buttonHwnd: HWND
        let actionID: String
    }
    private var shortcutRecorders: [ShortcutRecorderControl] = []

    // The Appearance tab's picker-grid buttons (roommate/window-edge/
    // background — added in W7): BS_OWNERDRAW push buttons drawn via
    // handleDrawItem/drawPickerCard instead of stock button chrome. `kind`
    // says which PomoppiSettings field a card's own click (routed through
    // the ordinary pushButtons/BN_CLICKED dispatch, same as any other
    // button) and its selection-border check both read against; `itemID`
    // is that field's candidate value this specific card represents.
    private enum PickerKind {
        case friend, frameStyle, background
    }
    private struct PickerCardControl {
        let hwnd: HWND
        let kind: PickerKind
        let itemID: String
    }
    private var pickerCards: [PickerCardControl] = []

    // Rendered picker-card previews, keyed by everything their pixels
    // depend on. Building one (AppearancePreviews.friendIcon/
    // frameEdgeCard/backgroundPatternCard) walks the whole 110x124 frame
    // grid pixel by pixel through String/hex parsing — fine once, but
    // drawPickerCard used to rebuild every card from scratch on every
    // WM_DRAWITEM, and a scroll step repaints all of them at once: with a
    // dozen-plus cards per page that alone pushed each step well past a
    // display frame, the other half of the drag flicker fixed alongside
    // WS_CLIPCHILDREN (see createPage). Keyed rather than explicitly
    // invalidated so a color/theme/frame-style change simply misses and
    // re-renders — no call site has to remember to clear it. Cleared
    // outright once it grows past a sanity bound (every entry is one
    // small PixelCanvas, so it'd take hundreds of distinct color picks to
    // ever get there).
    private struct PickerCardCacheKey: Hashable {
        let kind: PickerKind
        let itemID: String
        let inkColor: String
        let paperColor: String
        // Only background cards actually depend on this; the other two
        // kinds pass "" so a frame-style change doesn't evict them.
        let frameStyle: String
    }
    private var pickerCardCache: [PickerCardCacheKey: AppearancePreviews.Card] = [:]
    private static let pickerCardCacheLimit = 256

    // The Appearance tab's theme-preset swatches: a plain two-color card
    // (paper fill + ink dot, no PixelCanvas involved — these aren't art
    // previews) that sets ink AND paper together on click. Mirrors macOS's
    // ThemePresetPicker/themePresets exactly (same 11 presets, same names —
    // deliberately 11, not 12: at this tab's column math, 11 items fill a
    // single row exactly, where 12 stranded one swatch alone on a second
    // row).
    private struct ThemePreset {
        let name: String
        let ink: String
        let paper: String
    }
    private static let themePresets: [ThemePreset] = [
        ThemePreset(name: "Classic", ink: "#000000", paper: "#FFFFFF"),
        ThemePreset(name: "LCD Green", ink: "#276231", paper: "#80B391"),
        ThemePreset(name: "Pine", ink: "#E0FFC2", paper: "#064734"),
        ThemePreset(name: "Midnight", ink: "#E2E8F0", paper: "#0F172A"),
        ThemePreset(name: "OLED", ink: "#FFFFFF", paper: "#000000"),
        ThemePreset(name: "Amber", ink: "#FFB000", paper: "#1A1100"),
        ThemePreset(name: "Cocoa", ink: "#2B1B12", paper: "#F4E9DC"),
        ThemePreset(name: "Sakura", ink: "#5D2A42", paper: "#FFD6EC"),
        ThemePreset(name: "Lavender", ink: "#372856", paper: "#E8DDFF"),
        ThemePreset(name: "Mint", ink: "#1F473E", paper: "#D5F2E6"),
        ThemePreset(name: "Peach", ink: "#683525", paper: "#FFE1CF"),
    ]
    private struct ThemeSwatchControl {
        let hwnd: HWND
        let preset: ThemePreset
    }
    private var themeSwatches: [ThemeSwatchControl] = []

    // The ink/paper ChooseColorW pickers: each is a plain owner-drawn
    // swatch button (fills with the current color, thin border) that opens
    // the common color dialog on click. `keyPath` says which
    // PomoppiSettings field this row edits — both rows share the exact
    // same wiring, only the keyPath differs.
    private struct ColorPickerControl {
        let hwnd: HWND
        let keyPath: WritableKeyPath<PomoppiSettings, String>
    }
    private var colorPickers: [ColorPickerControl] = []
    // ChooseColorW's custom-color swatches persist only for as long as the
    // array backing lpCustColors stays alive — kept at instance scope (not
    // a local var inside pickColor) so a color picked as "custom" in one
    // call is still offered as a recent custom color the next time this
    // same settings window instance opens the dialog again.
    private var customColors: [DWORD] = [DWORD](repeating: 0x00FF_FFFF, count: 16)

    // The scale picker's 4 options (1x-4x) — plain owner-drawn buttons
    // standing in for macOS's segmented Picker; each shows its own
    // "N×" text and a highlighted background when selected.
    private struct ScaleOptionControl {
        let hwnd: HWND
        let value: Int
    }
    private var scaleOptions: [ScaleOptionControl] = []

    // The color-scheme picker's 3 options (Auto/Light/Dark, top of the
    // General tab) — same owner-drawn-segmented-button shape as
    // scaleOptions just above (see drawSegmentedOption, the shared paint
    // both go through), kept as its own array/struct rather than folded
    // into ScaleOptionControl since "value" here is a String
    // (PomoppiSettings.colorSchemeIDs), not scale's Int, and each group
    // needs its own targeted invalidate (only that group's own selection
    // border moves on a click).
    private struct SchemeOptionControl {
        let hwnd: HWND
        let value: String
    }
    private var schemeOptions: [SchemeOptionControl] = []

    // The Sound tab's chime picker (Classic/Soft/Bell) — same owner-drawn-
    // segmented-button shape as scaleOptions/schemeOptions above, sharing
    // their own drawSegmentedOption for painting rather than a third copy
    // of it; kept as its own array/struct for the same "each group needs
    // its own targeted invalidate" reason schemeOptions' own comment gives.
    private struct ChimeOptionControl {
        let hwnd: HWND
        let value: String
    }
    private var chimeOptions: [ChimeOptionControl] = []

    // The opacity Trackbar32 and its live "NN%" readout — both cached so
    // handleOpacityScroll (WM_HSCROLL) can update the label text without
    // re-querying settingsStore for anything but the trackbar's own
    // current position.
    private var opacityTrackbar: HWND?
    private var opacityValueLabel: HWND?

    // The Diary tab's Session history section's history-size readout —
    // refreshed after Erase History completes, same "cache the label,
    // update its text in place" pattern as opacityValueLabel above. (Log
    // was its own tab until the 2026-09-20 redesign folded it into Diary.)
    private var sessionHistorySizeLabel: HWND?

    // The Diary tab's own other live-updated labels/button, same pattern
    // as sessionHistorySizeLabel above. Two status labels rather than one —
    // Export and Sync each report their own last outcome independently,
    // mirroring macOS DiaryTab's separate exportStatus/syncStatus @State.
    private var diarySessionCountLabel: HWND?
    private var diaryExportStatusLabel: HWND?
    private var diaryFolderLabel: HWND?
    private var diarySyncButton: HWND?
    private var diarySyncStatusLabel: HWND?

    // Hint footers created via addHint (SETTINGS_PLAN.md's S4) —
    // handleCtlColor looks a painted STATIC up here to decide whether it
    // gets the dimmed hint text color instead of the ordinary one, in
    // both themes. Most hints are static text baked in at creation, same
    // as everything else on this window; these two are the live
    // exceptions (SETTINGS_PLAN.md S4), re-rendered from the *other*
    // control's own change handler rather than their own.
    private var hintLabels: Set<HWND> = []
    private var trayClickHintLabel: HWND?
    private var askForTaskHintLabel: HWND?
    // What addHint's own last call measured its height at — read back by
    // the call site immediately after for its own y += bookkeeping (see
    // addHint's comment for why this beats a tuple return here).
    private var lastHintHeight: Int32 = 18

    // The footer strip under the tab control, visible on every tab
    // (release/update plan, phase R6b) — mirrors macOS's UpdateFooter.
    // Direct children of `hwnd` itself, not any one page (see createFooter's
    // own comment for why that's fine for WM_COMMAND/WM_CTLCOLOR* dispatch).
    private var footerVersionLabel: HWND?
    private var footerActionButton: HWND?
    // The manual "Check for updates" button's own little state machine —
    // separate from updateChecker.latestResult, same split as macOS's
    // UpdateFooter (@State manualState alongside @ObservedObject
    // updateChecker): a background check resolving to .updateAvailable
    // always takes priority once this is back at .idle, but a check
    // in-flight or just-resolved through *this* button has to keep showing
    // "Checking…"/"Up to date" for a moment even if the background timer
    // fires in the same window.
    private enum ManualCheckState {
        case idle, checking, upToDate, failed
    }
    private var manualCheckState: ManualCheckState = .idle
    private static let manualCheckRevertTimerID: UINT_PTR = 1
    private var manualCheckRevertPending = false

    // The Appearance page's own scroll state — it's the only page whose
    // content is taller than the window's own floor size (11 theme
    // swatches + 3 picker grids + 2 color rows + size/opacity controls
    // easily clears 650px against a ~450px visible page area at 560x480),
    // so it's the only page with its own scroll rail (see
    // createAppearanceScrollRail). `appearanceContentHeight` is set once at
    // the end of buildAppearanceTab from the running `y` every add*/build*
    // helper below already returns/advances.
    private var appearancePage: HWND?
    private var appearanceContentHeight: Int32 = 0
    private var appearanceScrollY: Int32 = 0
    // The custom scroll rail itself (replaces the native WS_VSCROLL
    // scrollbar this page used to have — see pomoppiScrollRailWndProc's own
    // comment for why it's a whole separate window class rather than an
    // owner-draw button). Deliberately not registered via
    // trackAppearanceControl below: unlike every other tracked control on
    // this page, the rail must stay fixed in the viewport as content
    // scrolls past it, never moving itself. Not `private` — same reason
    // `hwnd` above isn't: pomoppiScrollRailWndProc needs it to identify
    // which HWND it's dispatching for, same shape as every other WndProc
    // free function in this file.
    var appearanceScrollRail: HWND?
    // Set only while the thumb itself (not the track) is being dragged —
    // see handleScrollRailMouseDown/handleScrollRailMouseMove. The grab
    // offset is where inside the thumb (from its top edge) the drag
    // started, so the thumb stays put under the cursor instead of
    // jumping to center on it.
    private var railDragging = false
    private var railGrabOffset: Int32 = 0

    // Every one of the Appearance page's own children (labels included),
    // recorded at its un-scrolled ("base") position the moment it's
    // created. scrollAppearance repositions each one explicitly (one
    // DeferWindowPos batch) rather than ScrollWindowEx — see scrollAppearance's own
    // comment for why: ScrollWindowEx's SW_SCROLLCHILDREN blit-and-shift
    // approach turned out to visibly corrupt this page live in the VM
    // (confirmed by screenshot — stale fragments of labels/cards left
    // behind after scrolling), a real, documented MSDN caveat of that
    // flag, not a fluke of this one call.
    private struct AppearanceControlPosition {
        let hwnd: HWND
        let baseX: Int32
        let baseY: Int32
    }
    private var appearanceControlPositions: [AppearanceControlPosition] = []

    private func trackAppearanceControl(_ hwnd: HWND, x: Int32, y: Int32) {
        appearanceControlPositions.append(AppearanceControlPosition(hwnd: hwnd, baseX: x, baseY: y))
    }

    // The Keys tab's own page — SetFocus target while recording, so the
    // capture keystroke's WM_(SYS)KEYDOWN has somewhere of ours to land
    // (see startRecording/handleShortcutRecorderKeyDown below).
    private var keysPage: HWND?
    // The action id currently listening for its next keydown, or nil — only
    // one row records at a time (see toggleShortcutRecording).
    private var recordingActionID: String?

    // Whether this window is currently drawing itself dark — set from
    // systemPrefersDarkTheme() at creation and again on every live
    // WM_SETTINGCHANGE (see applyTheme/handleSettingChange). Every
    // owner-drawn paint below reads this fresh rather than being told
    // per-call, so a live theme flip repaints correctly with no extra
    // bookkeeping at each call site.
    private var isDarkMode = false
    // Non-private read-only window onto isDarkMode above — same reason
    // `hwnd`/`appearanceScrollRail`/`tabControl` aren't private themselves:
    // pomoppiTabControlSubclassProc needs to know whether to intercept
    // WM_PAINT/WM_ERASEBKGND at all before calling in.
    var isDarkModeActive: Bool { isDarkMode }
    // Non-private for the same reason as isDarkModeActive just above —
    // pomoppiStepperSubclassProc needs to know whether a given HWND is
    // one of steppers' own up-downs or edits without steppers itself
    // becoming non-private.
    func isStepperUpDown(_ hwnd: HWND) -> Bool {
        steppers.contains(where: { $0.upDownHwnd == hwnd })
    }
    func isStepperEdit(_ hwnd: HWND) -> Bool {
        steppers.contains(where: { $0.editHwnd == hwnd })
    }

    // Stable, index-backed identity for each tab — createPage dispatches on
    // this rather than the tab's own *display* title (see createPage's own
    // comment for why that string used to be the dispatch key, and the bug
    // that came from it). `title` is still what actually populates the
    // strip and feeds drawTabControlDark's own by-index text lookup.
    private enum Tab: Int, CaseIterable {
        case general, rhythm, appearance, keys, sound, diary

        var title: String {
            switch self {
            case .general: return "General"
            case .rhythm: return "Rhythm"
            case .appearance: return "Appearance"
            case .keys: return "Keys"
            case .sound: return "Sound"
            case .diary: return "Diary"
            }
        }
    }

    // Exact order macOS's SettingsView.swift uses.
    private static let tabTitles = Tab.allCases.map(\.title)

    // clientWidth/clientHeight is the *minimum* size now, not a fixed one
    // (WS_THICKFRAME below makes the window user-resizable) — in the
    // ballpark of macOS's idealWidth/idealHeight (520x400), and proven to
    // fit every tab's content (Appearance excepted, which scrolls). Never
    // let a drag-resize go smaller than this (see WM_GETMINMAXINFO in
    // handleMessage) — a smaller window with no scrollbar anywhere but
    // Appearance would make some controls on other tabs unreachable.
    private static let clientWidth: Int32 = 560
    // The footer strip (release/update plan, phase R6b) is additional room
    // below the tab control, not a bite taken out of the original budget —
    // every tab's own content keeps exactly the vertical space it was
    // already proven to fit in. The base grew from 480 to 552 in
    // SETTINGS_PLAN.md's S4: the Keys tab's own two new hints (after
    // "Global shortcuts" and after "While the widget is focused") pushed
    // its always-visible, never-scrolling content past the old 480 —
    // confirmed live, the second hint clipped clean off the bottom of the
    // page under the old budget. General/Rhythm/Sound/Diary all still fit
    // with room to spare at the new height; only Keys was actually tight.
    private static let footerHeight: Int32 = 28
    private static let clientHeight: Int32 = 552 + footerHeight

    // WS_THICKFRAME (aka WS_SIZEBOX) is what makes the window user-
    // resizable — shared between window creation and WM_GETMINMAXINFO's
    // AdjustWindowRectEx call so both agree on exactly the same frame
    // geometry.
    private static let windowStyle = DWORD(WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_THICKFRAME)

    private static let className: [UInt16] = Array("PomoppiSettingsWindowClass".utf16) + [0]
    private static let windowTitle: [UInt16] = Array("Pomoppi Settings".utf16) + [0]
    private static let pageClassName: [UInt16] = Array("PomoppiSettingsPageClass".utf16) + [0]
    private static let scrollRailClassName: [UInt16] = Array("PomoppiScrollRailClass".utf16) + [0]
    private static let tabClassName: [UInt16] = Array("SysTabControl32".utf16) + [0]
    private static let staticClassName: [UInt16] = Array("STATIC".utf16) + [0]
    private static let buttonClassName: [UInt16] = Array("BUTTON".utf16) + [0]
    private static let editClassName: [UInt16] = Array("EDIT".utf16) + [0]
    private static let upDownClassName: [UInt16] = Array("msctls_updown32".utf16) + [0]
    private static let trackbarClassName: [UInt16] = Array("msctls_trackbar32".utf16) + [0]
    private static let hInstance = GetModuleHandleW(nil)

    // Shared row geometry for the plain vertical stacks the 3 real tabs
    // below use — not a pixel match for macOS's Form/Section layout (see
    // the task's stated philosophy), just enough spacing to read cleanly,
    // with a bit of extra gap between logical groups.
    private static let rowMargin: Int32 = 16
    private static let rowHeight: Int32 = 26
    private static let groupGap: Int32 = 14

    private static var classesRegistered = false
    private static var commonControlsInitialized = false

    // Loads the exe's own embedded icon resource (ID 1 — see Pomoppi.rc,
    // compiled+linked in only by Scripts/make-windows-app.js's release
    // build, never a plain debug swift build) at an explicit pixel size,
    // so the titlebar/taskbar/Alt-Tab get a crisp match against the .ico's
    // own baked 16-256px frames instead of one fixed bitmap stretched
    // blurry. LoadImageW returns a plain HANDLE, not HICON — Win32 itself
    // only tells them apart by the uType argument, so the result is
    // reinterpreted via the same Int-bitPattern round-trip this file
    // already uses to recover a typed pointer from an untyped one (see
    // handleMessage's own NMHDR/NMUPDOWN reconstruction below). MAKEINTRESOURCE(1)
    // doesn't import as a usable symbol in this overlay (same story as
    // IDC_ARROW just below) — reconstruct via UnsafePointer<WCHAR>(bitPattern:).
    private static func loadAppIcon(width: Int32, height: Int32) -> HICON? {
        guard let handle = LoadImageW(hInstance, UnsafePointer<WCHAR>(bitPattern: 1), UINT(IMAGE_ICON), width, height, UINT(LR_DEFAULTCOLOR)) else {
            return nil
        }
        return HICON(bitPattern: Int(bitPattern: handle))
    }

    // A normal titled window and a normal titled window's own child page —
    // neither is WidgetWindow's layered/tool-window popup, so both get a
    // plain background brush rather than being left to draw nothing.
    // hbrBackground here is fixed for the process's lifetime once
    // RegisterClassW runs — dark mode can't just swap it live, and instead
    // repaints over it via WM_ERASEBKGND (see applyTheme/
    // handleEraseBackground).
    private static func registerClassesIfNeeded() {
        guard !classesRegistered else { return }

        let windowAtom: ATOM = className.withUnsafeBufferPointer { classNamePtr in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = pomoppiSettingsWndProc
            windowClass.hInstance = hInstance
            windowClass.lpszClassName = classNamePtr.baseAddress
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            // Only this window class gets a real icon — WidgetWindow's own
            // popup is WS_EX_TOOLWINDOW (no titlebar/taskbar presence by
            // design) and pageClassName's children never surface an icon
            // of their own either way.
            windowClass.hIcon = loadAppIcon(width: GetSystemMetrics(SM_CXICON), height: GetSystemMetrics(SM_CYICON))
            return RegisterClassW(&windowClass)
        }
        guard windowAtom != 0 else {
            fatalError("RegisterClassW (settings window) failed with error \(GetLastError())")
        }

        // The page container forwards WM_COMMAND/WM_NOTIFY up to the real
        // settings window (see pomoppiSettingsPageWndProc) — its own real
        // children (checkboxes, steppers) need that to ever be heard.
        let pageAtom: ATOM = pageClassName.withUnsafeBufferPointer { classNamePtr in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = pomoppiSettingsPageWndProc
            windowClass.hInstance = hInstance
            windowClass.lpszClassName = classNamePtr.baseAddress
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            return RegisterClassW(&windowClass)
        }
        guard pageAtom != 0 else {
            fatalError("RegisterClassW (settings page) failed with error \(GetLastError())")
        }

        // The Appearance page's scroll rail — its own class rather than a
        // stock BUTTON (see pomoppiScrollRailWndProc's comment for why),
        // with the same plain page-matching background and arrow cursor as
        // the top-level window itself (nothing else in this file bothers
        // setting hCursor on a child, but this one is real, standalone,
        // click-and-drag chrome rather than something a BUTTON/EDIT/etc.
        // already handles for free).
        let scrollRailAtom: ATOM = scrollRailClassName.withUnsafeBufferPointer { classNamePtr in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = pomoppiScrollRailWndProc
            windowClass.hInstance = hInstance
            windowClass.lpszClassName = classNamePtr.baseAddress
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            return RegisterClassW(&windowClass)
        }
        guard scrollRailAtom != 0 else {
            fatalError("RegisterClassW (scroll rail) failed with error \(GetLastError())")
        }

        classesRegistered = true
    }

    // Process-wide, once, before the first SysTabControl32/msctls_updown32
    // is created — ICC_TAB_CLASSES for the tab strip (part 1), plus
    // ICC_UPDOWN_CLASS for the Rhythm/Sound numeric steppers (part 2), plus
    // ICC_BAR_CLASSES for the Appearance tab's opacity msctls_trackbar32
    // (part 2 of W7).
    private static func initCommonControlsIfNeeded() {
        guard !commonControlsInitialized else { return }
        var icc = INITCOMMONCONTROLSEX()
        icc.dwSize = DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size)
        icc.dwICC = DWORD(ICC_TAB_CLASSES) | DWORD(ICC_UPDOWN_CLASS) | DWORD(ICC_BAR_CLASSES)
        InitCommonControlsEx(&icc)
        commonControlsInitialized = true
    }

    // The single entry point every "open settings" trigger funnels through
    // (widget gear/`,` key, tray menu, global hotkey — see WidgetWindow's
    // onOpenSettingsRequested and main.swift's wiring): creates the window
    // on first call, or brings the existing one to front on every call
    // after that — never a second instance.
    static func show(settingsStore: SettingsStore, sessionLogger: SessionLogger, chimePlayer: ChimePlayer, globalShortcutManager: GlobalShortcutManager, updateChecker: AppUpdateChecker, reregisterShortcuts: @escaping () -> Void) {
        if let existing = shared {
            if IsIconic(existing.hwnd) {
                ShowWindow(existing.hwnd, SW_RESTORE)
            }
            SetForegroundWindow(existing.hwnd)
            return
        }
        let window = SettingsWindow(settingsStore: settingsStore, sessionLogger: sessionLogger, chimePlayer: chimePlayer, globalShortcutManager: globalShortcutManager, updateChecker: updateChecker, reregisterShortcuts: reregisterShortcuts)
        shared = window
        ShowWindow(window.hwnd, SW_SHOW)
        SetForegroundWindow(window.hwnd)
    }

    private init(settingsStore: SettingsStore, sessionLogger: SessionLogger, chimePlayer: ChimePlayer, globalShortcutManager: GlobalShortcutManager, updateChecker: AppUpdateChecker, reregisterShortcuts: @escaping () -> Void) {
        self.settingsStore = settingsStore
        self.sessionLogger = sessionLogger
        self.chimePlayer = chimePlayer
        self.globalShortcutManager = globalShortcutManager
        self.updateChecker = updateChecker
        self.reregisterShortcuts = reregisterShortcuts
        Self.registerClassesIfNeeded()
        Self.initCommonControlsIfNeeded()

        // CreateWindowExW's width/height are the *window's* size, including
        // the title bar/borders the requested style adds — grow the desired
        // client rect through AdjustWindowRectEx rather than guessing a
        // margin by hand, same technique as any other fixed-content Win32
        // dialog-shaped window.
        var rect = RECT(left: 0, top: 0, right: Self.clientWidth, bottom: Self.clientHeight)
        AdjustWindowRectEx(&rect, Self.windowStyle, false, 0)
        let windowWidth = rect.right - rect.left
        let windowHeight = rect.bottom - rect.top

        let screenWidth = GetSystemMetrics(SM_CXSCREEN)
        let screenHeight = GetSystemMetrics(SM_CYSCREEN)
        let x = (screenWidth - windowWidth) / 2
        let y = (screenHeight - windowHeight) / 2

        guard let createdHwnd = (Self.className.withUnsafeBufferPointer { classNamePtr in
            Self.windowTitle.withUnsafeBufferPointer { titlePtr in
                CreateWindowExW(
                    0,
                    classNamePtr.baseAddress,
                    titlePtr.baseAddress,
                    Self.windowStyle,
                    x, y, windowWidth, windowHeight,
                    nil, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (settings window) failed with error \(GetLastError())")
        }
        hwnd = createdHwnd

        // Belt-and-suspenders alongside registerClassesIfNeeded's own
        // windowClass.hIcon: explicitly setting both icon sizes on the
        // window itself guarantees the titlebar, taskbar button, and
        // Alt-Tab all pick up the real icon regardless of any DPI/
        // class-icon subtlety.
        if let bigIcon = Self.loadAppIcon(width: GetSystemMetrics(SM_CXICON), height: GetSystemMetrics(SM_CYICON)) {
            SendMessageW(hwnd, UINT(WM_SETICON), WPARAM(UInt(ICON_BIG)), LPARAM(Int(bitPattern: bigIcon)))
        }
        if let smallIcon = Self.loadAppIcon(width: GetSystemMetrics(SM_CXSMICON), height: GetSystemMetrics(SM_CYSMICON)) {
            SendMessageW(hwnd, UINT(WM_SETICON), WPARAM(UInt(ICON_SMALL)), LPARAM(Int(bitPattern: smallIcon)))
        }

        // Detected once here, before any tab/control exists (a second
        // detection happens later, live, in handleSettingChange) — the
        // actual recolor work waits for applyTheme() just below, since
        // that needs the tab control/steppers/trackbar setUpTabsAndPages
        // is about to create.
        isDarkMode = resolveDarkMode()
        setUpTabsAndPages()
        createFooter()
        applyTheme()
        updateChecker.onUpdate = { [weak self] in self?.refreshUpdateFooter() }
    }

    // -- tab control + pages -------------------------------------------------

    private func setUpTabsAndPages() {
        var clientRect = RECT()
        GetClientRect(hwnd, &clientRect)
        // The tab control (and, through TCM_ADJUSTRECT below, every page)
        // stops footerHeight short of the bottom, leaving room for the
        // version/update strip createFooter() adds there — see
        // clientHeight's own comment for why that's extra room, not a bite
        // out of any tab's existing layout.
        let tabAreaHeight = clientRect.bottom - clientRect.top - Self.footerHeight

        guard let tab = (Self.tabClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS),
                0, 0, clientRect.right - clientRect.left, tabAreaHeight,
                hwnd, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (tab control) failed with error \(GetLastError())")
        }
        tabControl = tab
        // pomoppiTabControlSubclassProc's own dark-mode-only gate decides
        // when this actually intercepts anything — installed unconditionally
        // here since there's only ever one tab control for this to matter
        // for.
        _ = SetWindowSubclass(tab, pomoppiTabControlSubclassProc, 1, 0)

        for (index, title) in Self.tabTitles.enumerated() {
            var wide = Array(title.utf16) + [0]
            wide.withUnsafeMutableBufferPointer { buf in
                var item = TCITEMW()
                item.mask = UINT(TCIF_TEXT)
                item.pszText = buf.baseAddress
                withUnsafeMutablePointer(to: &item) { itemPtr in
                    _ = SendMessageW(tab, UINT(TCM_INSERTITEMW), WPARAM(index), LPARAM(Int(bitPattern: itemPtr)))
                }
            }
        }

        // TCM_ADJUSTRECT with the tab control's own bounding rect (its own
        // full client rect, since it's already sized to tabAreaHeight above)
        // gives back the display area under the tab strip — the standard
        // Win32 technique for laying out a tab control's content pages by
        // hand (no dialog-template/property-sheet machinery in this
        // codebase).
        var displayRect = RECT(left: 0, top: 0, right: clientRect.right - clientRect.left, bottom: tabAreaHeight)
        withUnsafeMutablePointer(to: &displayRect) { rectPtr in
            _ = SendMessageW(tab, UINT(TCM_ADJUSTRECT), WPARAM(0), LPARAM(Int(bitPattern: rectPtr)))
        }

        // Windows' counterpart to macOS's `@AppStorage`-remembered tab — the
        // settings window is destroyed on close, so this is the only place
        // last session's tab survives (see loadRememberedTabIndex's own
        // comment). Read once here; selectTab persists any later change.
        let rememberedIndex = Self.loadRememberedTabIndex()
        for (index, tab) in Tab.allCases.enumerated() {
            let page = createPage(tab: tab, rect: displayRect)
            pages.append(page)
            ShowWindow(page, index == rememberedIndex ? SW_SHOW : SW_HIDE)
        }
        SendMessageW(tab, UINT(TCM_SETCURSEL), WPARAM(rememberedIndex), 0)
    }

    // WM_SIZE (user drag-resize, now that WS_THICKFRAME makes that
    // possible) — resizes the tab strip and every page to match the new
    // client rect via the exact same TCM_ADJUSTRECT technique
    // setUpTabsAndPages already uses once at creation. Deliberately not a
    // real layout system: existing child controls inside each page stay at
    // their own absolute positions, nothing reflows or anchors to the new
    // edges — a bigger window just leaves more inert margin below/right of
    // whatever a tab already draws, same look as today's "short tab in a
    // fixed window", just user-controlled now instead of a fixed 560x480.
    private func handleResize() {
        guard let tab = tabControl else { return }
        var clientRect = RECT()
        GetClientRect(hwnd, &clientRect)
        let tabAreaHeight = clientRect.bottom - clientRect.top - Self.footerHeight
        SetWindowPos(tab, nil, 0, 0, clientRect.right - clientRect.left, tabAreaHeight, UINT(SWP_NOZORDER) | UINT(SWP_NOACTIVATE))
        repositionFooter(clientRect: clientRect)

        var displayRect = RECT(left: 0, top: 0, right: clientRect.right - clientRect.left, bottom: tabAreaHeight)
        withUnsafeMutablePointer(to: &displayRect) { rectPtr in
            _ = SendMessageW(tab, UINT(TCM_ADJUSTRECT), WPARAM(0), LPARAM(Int(bitPattern: rectPtr)))
        }
        let pageWidth = displayRect.right - displayRect.left
        let pageHeight = displayRect.bottom - displayRect.top
        for page in pages {
            SetWindowPos(page, nil, displayRect.left, displayRect.top, pageWidth, pageHeight, UINT(SWP_NOZORDER) | UINT(SWP_NOACTIVATE))
        }

        // Appearance is the only page whose own scroll math depends on the
        // page's visible height — every other page just gets more/less
        // inert margin, nothing to recompute.
        if let rail = appearanceScrollRail {
            let railWidth = GetSystemMetrics(SM_CXVSCROLL)
            SetWindowPos(rail, nil, pageWidth - railWidth, 0, railWidth, pageHeight, UINT(SWP_NOZORDER) | UINT(SWP_NOACTIVATE))
            // scrollAppearance's own clamp (maxScroll = max(0,
            // appearanceContentHeight - visibleHeight)) already re-derives
            // a valid appearanceScrollY from the new pageHeight — a by-0
            // "scroll" is enough to trigger that clamp (and the resulting
            // reposition/repaint) without duplicating its math here. A
            // no-op delta when nothing needs to move (window grew and
            // appearanceScrollY was already 0) is exactly scrollAppearance's
            // own early-return case, so this is safe to call unconditionally
            // on every resize. Confirmed live: shrinking the window back
            // down after growing it past appearanceContentHeight correctly
            // re-clamps rather than leaving the page scrolled past its own
            // (now shorter) content.
            scrollAppearance(by: 0)
            // scrollAppearance above only repaints if the scroll offset
            // actually changed (its own early-return) — the rail's *thumb
            // size* still depends on the new pageHeight even when the
            // offset didn't move (e.g. growing from an already-top-scrolled
            // page), so it needs its own unconditional invalidate here.
            InvalidateRect(rail, nil, true)
        }
    }

    // -- update footer (release/update plan, phase R6b) -----------------------

    // The version/update line under the tab strip, visible on every tab —
    // mirrors macOS's UpdateFooter. Direct children of `hwnd` itself, not
    // any one page: WM_COMMAND/WM_CTLCOLORSTATIC/WM_CTLCOLORBTN all arrive
    // at pomoppiSettingsWndProc directly that way, with no page-forwarding
    // needed (pomoppiSettingsPageWndProc's own forwarding only exists for a
    // *page's* own children — see its comment).
    private func createFooter() {
        var clientRect = RECT()
        GetClientRect(hwnd, &clientRect)
        footerVersionLabel = addLabel(
            "Pomoppi \(pomoppiVersion) ·", in: hwnd,
            x: Self.rowMargin, y: clientRect.bottom - Self.footerHeight + 6, width: 140)
        footerActionButton = addButton(
            "Check for updates", in: hwnd,
            x: Self.rowMargin + 140, y: clientRect.bottom - Self.footerHeight + 3,
            width: clientRect.right - clientRect.left - Self.rowMargin - 140, height: 20
        ) { [weak self] in
            self?.handleFooterActionClick()
        }
        refreshUpdateFooter()
    }

    // Repositions the footer's own children to track the bottom of a
    // resized window — same "absolute positions, just moved" idea as every
    // other SetWindowPos in handleResize, not a real layout system.
    private func repositionFooter(clientRect: RECT) {
        let y = clientRect.bottom - Self.footerHeight
        let width = clientRect.right - clientRect.left
        if let footerVersionLabel {
            SetWindowPos(footerVersionLabel, nil, Self.rowMargin, y + 6, 140, 18, UINT(SWP_NOZORDER) | UINT(SWP_NOACTIVATE))
        }
        if let footerActionButton {
            SetWindowPos(footerActionButton, nil, Self.rowMargin + 140, y + 3, width - Self.rowMargin - 140, 20, UINT(SWP_NOZORDER) | UINT(SWP_NOACTIVATE))
        }
    }

    // Redraws the footer's action control from updateChecker.latestResult
    // and this window's own manualCheckState — called after either one
    // changes (a background check resolving while this window is open, via
    // updateChecker.onUpdate, or the button's own click-driven state
    // machine below). Priority order mirrors macOS's UpdateFooter.actionView:
    // an update found in the background wins over "Check for updates"/
    // "Up to date"/"Couldn't check", but never mid-check — a click
    // shouldn't flash straight past "Checking…".
    private func refreshUpdateFooter() {
        guard let footerActionButton else { return }
        if case .updateAvailable(let tag, _) = updateChecker.latestResult, manualCheckState != .checking {
            setWindowText(footerActionButton, "Update available: \(tag) — Download")
            EnableWindow(footerActionButton, true)
            return
        }
        switch manualCheckState {
        case .idle:
            setWindowText(footerActionButton, "Check for updates")
            EnableWindow(footerActionButton, true)
        case .checking:
            setWindowText(footerActionButton, "Checking…")
            EnableWindow(footerActionButton, false)
        case .upToDate:
            setWindowText(footerActionButton, "Up to date")
            EnableWindow(footerActionButton, false)
        case .failed:
            setWindowText(footerActionButton, "Couldn't check — try again")
            EnableWindow(footerActionButton, true)
        }
    }

    // The footer button's own click — either opens the release page (when
    // an update is already known) or kicks off an explicit check.
    private func handleFooterActionClick() {
        if case .updateAvailable(_, let pageURL) = updateChecker.latestResult, manualCheckState != .checking {
            Self.openURL(pageURL)
            return
        }
        checkForUpdatesNow()
    }

    // The explicit-check-only path (unlike the silent 10s/24h background
    // one AppUpdateChecker itself runs): a genuine fetch failure here is
    // worth surfacing as "Couldn't check — try again" rather than staying
    // silent. checkExplicitly's own completion already arrives marshaled
    // onto this thread (see AppUpdateChecker.postToMainThread), so every
    // Win32 call below is safe to make directly.
    private func checkForUpdatesNow() {
        if manualCheckRevertPending {
            KillTimer(hwnd, Self.manualCheckRevertTimerID)
            manualCheckRevertPending = false
        }
        manualCheckState = .checking
        refreshUpdateFooter()
        updateChecker.checkExplicitly { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.updateAvailable):
                self.manualCheckState = .idle
            case .success(.noUpdate):
                self.manualCheckState = .upToDate
                self.manualCheckRevertPending = true
                SetTimer(self.hwnd, Self.manualCheckRevertTimerID, 5000, nil)
            case .failure:
                self.manualCheckState = .failed
            }
            self.refreshUpdateFooter()
        }
    }

    // Win32's NSWorkspace.shared.open(_:) equivalent — same small helper
    // TrayController.openURL already duplicates for its own "Update
    // available" menu item, matching this port's usual small-duplication-
    // over-shared-abstraction ethos (see CLAUDE.md's Windows invariants).
    private static func openURL(_ url: URL) {
        let operation = Array("open".utf16) + [0]
        let target = Array(url.absoluteString.utf16) + [0]
        _ = operation.withUnsafeBufferPointer { opPtr in
            target.withUnsafeBufferPointer { targetPtr in
                ShellExecuteW(nil, opPtr.baseAddress, targetPtr.baseAddress, nil, nil, SW_SHOWNORMAL)
            }
        }
    }

    // pomoppiTabControlSubclassProc's own gate already confirmed
    // isDarkModeActive before calling in — WM_ERASEBKGND just claims the
    // erase (drawTabControlDark below fills the whole client rect itself,
    // so there's nothing left for a real erase to do), WM_PAINT does the
    // actual drawing.
    func handleTabControlPaintMessage(hwnd: HWND, message: UINT) -> LRESULT {
        if message == UINT(WM_ERASEBKGND) { return 1 }
        drawTabControlDark(hwnd: hwnd)
        return 0
    }

    // Hand-painted dark tab strip — comctl32 has no dark visual style for
    // SysTabControl32 (see setControlDarkTheme's own comment), so this is
    // the Notepad++-style workaround: subclass + own WM_PAINT. Selected
    // tab reuses darkBackgroundHex (the page's own fill) so it reads as
    // connected to the page below it; unselected tabs get darkScrollTrackHex
    // instead, one shade lighter than the page so the strip still reads as
    // its own surface. Outline in darkElevatedHex, same "1px border" grammar
    // drawSelectionBorder uses elsewhere on this file, but built from plain
    // FillRect edges here rather than DrawEdge/Rectangle since the selected
    // tab needs to selectively drop just its bottom edge.
    private func drawTabControlDark(hwnd: HWND) {
        var paint = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &paint) else { return }
        defer { EndPaint(hwnd, &paint) }
        guard let backgroundBrush = WindowsTheme.darkBackgroundBrush,
              let elevatedBrush = CreateSolidBrush(Self.colorref(hex: Self.darkElevatedHex)),
              let selectedBrush = CreateSolidBrush(Self.colorref(hex: WindowsTheme.darkBackgroundHex)),
              let unselectedBrush = CreateSolidBrush(Self.colorref(hex: Self.darkScrollTrackHex)) else { return }
        defer {
            DeleteObject(elevatedBrush)
            DeleteObject(selectedBrush)
            DeleteObject(unselectedBrush)
        }

        var clientRect = RECT()
        GetClientRect(hwnd, &clientRect)
        FillRect(hdc, &clientRect, backgroundBrush)

        // WM_GETFONT rather than GetStockObject(DEFAULT_GUI_FONT) (unlike
        // drawScaleOption/drawPickerCard's owner-drawn buttons elsewhere in
        // this file) — the tab control manages its own font rather than
        // going through applyDefaultFont like every other raw control here
        // (see that function's own comment), so querying it back is what
        // keeps this repaint's label metrics identical to light mode's
        // native one.
        var previousFont: HGDIOBJ?
        if let font = HGDIOBJ(bitPattern: Int(SendMessageW(hwnd, UINT(WM_GETFONT), 0, 0))) {
            previousFont = SelectObject(hdc, font)
        }
        SetBkMode(hdc, Int32(TRANSPARENT))
        SetTextColor(hdc, Self.colorref(hex: WindowsTheme.darkTextHex))

        let count = Int(SendMessageW(hwnd, UINT(TCM_GETITEMCOUNT), 0, 0))
        let selectedIndex = Int(SendMessageW(hwnd, UINT(TCM_GETCURSEL), 0, 0))
        var selectedItemRect: RECT?
        for index in 0..<count {
            var itemRect = RECT()
            withUnsafeMutablePointer(to: &itemRect) { rectPtr in
                _ = SendMessageW(hwnd, UINT(TCM_GETITEMRECT), WPARAM(index), LPARAM(Int(bitPattern: rectPtr)))
            }
            let isSelected = index == selectedIndex
            if isSelected { selectedItemRect = itemRect }

            var fillRect = itemRect
            FillRect(hdc, &fillRect, isSelected ? selectedBrush : unselectedBrush)

            var topEdge = RECT(left: itemRect.left, top: itemRect.top, right: itemRect.right, bottom: itemRect.top + 1)
            var leftEdge = RECT(left: itemRect.left, top: itemRect.top, right: itemRect.left + 1, bottom: itemRect.bottom)
            var rightEdge = RECT(left: itemRect.right - 1, top: itemRect.top, right: itemRect.right, bottom: itemRect.bottom)
            FillRect(hdc, &topEdge, elevatedBrush)
            FillRect(hdc, &leftEdge, elevatedBrush)
            FillRect(hdc, &rightEdge, elevatedBrush)
            // Selected tab skips its own bottom edge so it merges straight
            // into the page fill below (also darkBackgroundHex).
            if !isSelected {
                var bottomEdge = RECT(left: itemRect.left, top: itemRect.bottom - 1, right: itemRect.right, bottom: itemRect.bottom)
                FillRect(hdc, &bottomEdge, elevatedBrush)
            }

            var textRect = itemRect
            let wide = Array(Self.tabTitles[index].utf16) + [0]
            _ = wide.withUnsafeBufferPointer { ptr in
                DrawTextW(hdc, ptr.baseAddress, -1, &textRect, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
            }
        }
        if let previousFont { SelectObject(hdc, previousFont) }

        // The strip/page boundary line, at the display area's own top edge
        // (TCM_ADJUSTRECT, the exact same technique setUpTabsAndPages/
        // handleResize already use) — spans the full width except under
        // the selected tab, so the strip and the page below read as one
        // connected surface there rather than a visible seam.
        var displayRect = clientRect
        withUnsafeMutablePointer(to: &displayRect) { rectPtr in
            _ = SendMessageW(hwnd, UINT(TCM_ADJUSTRECT), WPARAM(0), LPARAM(Int(bitPattern: rectPtr)))
        }
        let lineY = displayRect.top - 1
        if let selectedItemRect {
            if selectedItemRect.left > clientRect.left {
                var leftSegment = RECT(left: clientRect.left, top: lineY, right: selectedItemRect.left, bottom: lineY + 1)
                FillRect(hdc, &leftSegment, elevatedBrush)
            }
            if selectedItemRect.right < clientRect.right {
                var rightSegment = RECT(left: selectedItemRect.right, top: lineY, right: clientRect.right, bottom: lineY + 1)
                FillRect(hdc, &rightSegment, elevatedBrush)
            }
        } else {
            var fullLine = RECT(left: clientRect.left, top: lineY, right: clientRect.right, bottom: lineY + 1)
            FillRect(hdc, &fullLine, elevatedBrush)
        }
    }

    // pomoppiStepperSubclassProc's own gate already confirmed dark mode
    // and stepper-up-down membership before calling in — same shape as
    // handleTabControlPaintMessage: WM_ERASEBKGND just claims the erase
    // (drawUpDownDark below fills the whole client rect itself), WM_PAINT
    // does the actual drawing.
    func handleUpDownPaintMessage(hwnd: HWND, message: UINT) -> LRESULT {
        if message == UINT(WM_ERASEBKGND) { return 1 }
        drawUpDownDark(hwnd: hwnd)
        return 0
    }

    // Hand-painted dark up-down — msctls_updown32 has no dark visual style
    // (see pomoppiStepperSubclassProc's own comment), so this is the same
    // WM_PAINT-takeover workaround as drawTabControlDark, just for this
    // control: a flat darkScrollTrackHex fill (reads the same "distinct
    // surface" role a stepper's up-down plays against the page as the
    // scroll rail's own track does — see drawScrollRail), a 1px
    // darkElevatedHex outline plus a 1px separator between the up/down
    // halves, and each arrow as a few centered FillRect rows of shrinking
    // width in darkTextHex rather than a real triangle/font glyph.
    private func drawUpDownDark(hwnd: HWND) {
        var paint = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &paint) else { return }
        defer { EndPaint(hwnd, &paint) }
        var clientRect = RECT()
        GetClientRect(hwnd, &clientRect)
        guard let trackBrush = CreateSolidBrush(Self.colorref(hex: Self.darkScrollTrackHex)),
              let elevatedBrush = CreateSolidBrush(Self.colorref(hex: Self.darkElevatedHex)),
              let arrowBrush = CreateSolidBrush(Self.colorref(hex: WindowsTheme.darkTextHex)) else { return }
        defer {
            DeleteObject(trackBrush)
            DeleteObject(elevatedBrush)
            DeleteObject(arrowBrush)
        }
        FillRect(hdc, &clientRect, trackBrush)

        let width = clientRect.right - clientRect.left
        let height = clientRect.bottom - clientRect.top
        let halfHeight = height / 2

        var outlineTop = RECT(left: clientRect.left, top: clientRect.top, right: clientRect.right, bottom: clientRect.top + 1)
        var outlineBottom = RECT(left: clientRect.left, top: clientRect.bottom - 1, right: clientRect.right, bottom: clientRect.bottom)
        var outlineLeft = RECT(left: clientRect.left, top: clientRect.top, right: clientRect.left + 1, bottom: clientRect.bottom)
        var outlineRight = RECT(left: clientRect.right - 1, top: clientRect.top, right: clientRect.right, bottom: clientRect.bottom)
        var separator = RECT(left: clientRect.left, top: clientRect.top + halfHeight, right: clientRect.right, bottom: clientRect.top + halfHeight + 1)
        FillRect(hdc, &outlineTop, elevatedBrush)
        FillRect(hdc, &outlineBottom, elevatedBrush)
        FillRect(hdc, &outlineLeft, elevatedBrush)
        FillRect(hdc, &outlineRight, elevatedBrush)
        FillRect(hdc, &separator, elevatedBrush)

        drawUpDownArrow(hdc: hdc, centerX: clientRect.left + width / 2, centerY: clientRect.top + halfHeight / 2, pointingUp: true, brush: arrowBrush)
        drawUpDownArrow(hdc: hdc, centerX: clientRect.left + width / 2, centerY: clientRect.top + halfHeight + halfHeight / 2, pointingUp: false, brush: arrowBrush)
    }

    // A tiny solid triangle built from a few centered FillRect rows of
    // shrinking width, same "flat GDI primitives only" spirit as
    // drawScrollRailGrip's own decoration above — no font glyph, no
    // DrawFrameControl (both would need the classic system look this
    // control just lost by having its own WM_PAINT taken over).
    private func drawUpDownArrow(hdc: HDC?, centerX: Int32, centerY: Int32, pointingUp: Bool, brush: HBRUSH) {
        let widths: [Int32] = [7, 5, 3, 1]
        let ordered = pointingUp ? Array(widths.reversed()) : widths
        let top = centerY - Int32(ordered.count) / 2
        for (rowIndex, rowWidth) in ordered.enumerated() {
            var row = RECT(left: centerX - rowWidth / 2, top: top + Int32(rowIndex), right: centerX - rowWidth / 2 + rowWidth, bottom: top + Int32(rowIndex) + 1)
            FillRect(hdc, &row, brush)
        }
    }

    // pomoppiStepperSubclassProc's own gate already confirmed dark mode
    // and stepper-edit membership before calling in. WM_NCPAINT is what
    // actually draws a WS_EX_CLIENTEDGE control's own sunken border —
    // confirmed live as the one remaining bright-white surface in dark
    // mode even after setControlDarkTheme/handleCtlColor already covered
    // the edit's interior background/text (see setControlDarkTheme's own
    // comment). GetWindowDC (not BeginPaint, which clips to the client
    // area) is the documented way to get an HDC covering the non-client
    // area for a manual WM_NCPAINT repaint, clipped/originated to a
    // (0,0,w,h) rect matching the window's own full size — window
    // coordinates, not client ones, is exactly why GetWindowRect (not
    // GetClientRect) feeds it. The client edge is 2px (WS_EX_CLIENTEDGE
    // is a sunken 3D border, two 1px rings) — painting only those two
    // outermost rings (drawNCFrameRing below) and never touching
    // anything further in leaves the actual client rect, which the
    // control's own WM_PAINT/WM_ERASEBKGND/WM_CTLCOLOREDIT already paint
    // correctly, untouched.
    func handleStepperEditNCPaint(hwnd: HWND) -> LRESULT {
        var windowRect = RECT()
        GetWindowRect(hwnd, &windowRect)
        let width = windowRect.right - windowRect.left
        let height = windowRect.bottom - windowRect.top
        guard width > 4, height > 4, let hdc = GetWindowDC(hwnd) else { return 0 }
        defer { ReleaseDC(hwnd, hdc) }
        guard let outerBrush = CreateSolidBrush(Self.colorref(hex: Self.darkElevatedHex)),
              let innerBrush = CreateSolidBrush(Self.colorref(hex: WindowsTheme.darkBackgroundHex)) else { return 0 }
        defer {
            DeleteObject(outerBrush)
            DeleteObject(innerBrush)
        }
        drawNCFrameRing(hdc: hdc, left: 0, top: 0, right: width, bottom: height, brush: outerBrush)
        drawNCFrameRing(hdc: hdc, left: 1, top: 1, right: width - 1, bottom: height - 1, brush: innerBrush)
        return 0
    }

    // Paints a single 1px rectangular outline (not a filled block, so
    // whatever is already inside it — the next ring in, or the client
    // rect itself — is left alone) — the plain-outline equivalent of
    // drawUpDownDark's own outline block, just parameterized over an
    // arbitrary ring rather than one fixed rect, since this needs two
    // concentric ones.
    private func drawNCFrameRing(hdc: HDC?, left: Int32, top: Int32, right: Int32, bottom: Int32, brush: HBRUSH) {
        var topEdge = RECT(left: left, top: top, right: right, bottom: top + 1)
        var bottomEdge = RECT(left: left, top: bottom - 1, right: right, bottom: bottom)
        var leftEdge = RECT(left: left, top: top, right: left + 1, bottom: bottom)
        var rightEdge = RECT(left: right - 1, top: top, right: right, bottom: bottom)
        FillRect(hdc, &topEdge, brush)
        FillRect(hdc, &bottomEdge, brush)
        FillRect(hdc, &leftEdge, brush)
        FillRect(hdc, &rightEdge, brush)
    }

    private func createPage(tab: Tab, rect: RECT) -> HWND {
        let width = rect.right - rect.left
        let height = rect.bottom - rect.top
        guard let page = (Self.pageClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                // No WS_CLIPSIBLINGS here — all 6 pages share this exact
                // same rect (only one is ever SW_SHOW'd at a time via
                // selectTab/setUpTabsAndPages, the rest SW_HIDE'd) rather
                // than being laid out apart from each other. Confirmed live:
                // with WS_CLIPSIBLINGS set, Windows clips this page's own
                // paint region against the other 5 fully-overlapping sibling
                // pages regardless of whether those siblings are actually
                // WS_VISIBLE, leaving the visible page's effective clip
                // region empty — WM_PAINT/WM_ERASEBKGND/WM_NCPAINT all still
                // fire completely normally (bookkeeping is unaffected), but
                // every GDI draw call the page or any of its children make
                // (background fill, border, this page's own STATIC
                // placeholder text) silently lands outside that empty clip
                // region and never reaches the screen. WS_CLIPSIBLINGS only
                // matters when overlapping siblings can be visible at the
                // same time, which never happens here.
                //
                // WS_CLIPCHILDREN is the opposite story and only the
                // Appearance page needs it: without it, every page-level
                // erase (WM_ERASEBKGND's COLOR_BTNFACE/dark fill) paints
                // straight over every child too, and each child then
                // repaints itself on top — a visible blank-then-refill
                // flash on every repaint. Harmless on a static page that
                // only ever repaints once, but Appearance repaints on
                // every scroll step, and during a thumb drag that's many
                // times a second — confirmed live as flicker. With the
                // flag set, the page's own erase is clipped to the gaps
                // between children (the only place its background is
                // actually visible), and children are never painted over
                // by their parent at all.
                DWORD(tab == .appearance ? WS_CHILD | WS_CLIPCHILDREN : WS_CHILD),
                rect.left, rect.top, width, height,
                hwnd, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (settings page) failed with error \(GetLastError())")
        }

        // Dispatches on `tab` itself, not its display title — the title
        // string used to be the switch key here, and an unmatched title
        // (any rename that forgot to update this switch, or, in the future,
        // a translated one — see LOCALIZATION_PLAN.md's L4) silently fell
        // through to a "coming in a later phase" placeholder instead of
        // failing loudly. Switching on Tab instead makes that case
        // unrepresentable: every case is handled, and the compiler enforces
        // it stays that way as the enum grows.
        switch tab {
        case .general:
            buildGeneralTab(page: page, width: width)
        case .rhythm:
            buildRhythmTab(page: page, width: width)
        case .appearance:
            appearancePage = page
            // Layout uses a narrower width than the page's own physical
            // size so nothing sits under the scroll rail this page alone
            // gets (see createAppearanceScrollRail, which reuses this exact
            // same reserved gutter rather than the page needing a second
            // width adjustment of its own).
            buildAppearanceTab(page: page, width: width - GetSystemMetrics(SM_CXVSCROLL))
            createAppearanceScrollRail(page: page, pageWidth: width, pageHeight: height)
        case .keys:
            buildKeysTab(page: page, width: width)
        case .sound:
            buildSoundTab(page: page, width: width)
        case .diary:
            buildDiaryTab(page: page, width: width)
        }
        return page
    }

    // -- General/Rhythm/Sound tab content --------------------------------------

    // Mirrors macOS's RhythmTab (SettingsView.swift): 3 minute steppers, a
    // sessions-per-long-break stepper, then 3 automation checkboxes.
    private func buildRhythmTab(page: HWND, width: Int32) {
        let settings = settingsStore.get()
        let labelWidth: Int32 = 220
        let rowWidth = width - 2 * Self.rowMargin
        var y = Self.rowMargin

        addStepper(
            "Default focus length (minutes)", in: page, value: Int32(settings.focusMinutes),
            min: 1, max: 180, step: 1, x: Self.rowMargin, y: y, labelWidth: labelWidth
        ) { [settingsStore] newValue in
            settingsStore.update { $0.focusMinutes = Double(newValue) }
        }
        y += Self.rowHeight
        addHint("Or click the clock on the widget.", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += lastHintHeight + Self.groupGap

        addStepper(
            "Short break length (minutes)", in: page, value: Int32(settings.shortBreakMinutes),
            min: 1, max: 180, step: 1, x: Self.rowMargin, y: y, labelWidth: labelWidth
        ) { [settingsStore] newValue in
            settingsStore.update { $0.shortBreakMinutes = Double(newValue) }
        }
        y += Self.rowHeight

        addStepper(
            "Long break length (minutes)", in: page, value: Int32(settings.longBreakMinutes),
            min: 1, max: 180, step: 1, x: Self.rowMargin, y: y, labelWidth: labelWidth
        ) { [settingsStore] newValue in
            settingsStore.update { $0.longBreakMinutes = Double(newValue) }
        }
        y += Self.rowHeight

        addStepper(
            "Long break every (sessions)", in: page, value: Int32(settings.longBreakEvery),
            min: 2, max: 10, step: 1, x: Self.rowMargin, y: y, labelWidth: labelWidth
        ) { [settingsStore] newValue in
            settingsStore.update { $0.longBreakEvery = Int(newValue) }
        }
        y += Self.rowHeight
        addHint("Or click the dots on the widget.", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += lastHintHeight + Self.groupGap

        addCheckbox(
            "Start breaks automatically", in: page, checked: settings.autoStartBreaks,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.autoStartBreaks = checked }
        }
        y += Self.rowHeight

        addCheckbox(
            "Start the next focus automatically", in: page, checked: settings.autoStartFocus,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.autoStartFocus = checked }
        }
        y += Self.rowHeight

        addCheckbox(
            "Ask what I’m working on before each focus", in: page, checked: settings.askForTaskName,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.askForTaskName = checked }
        }
        y += Self.rowHeight
        askForTaskHintLabel = addHint(Self.askForTaskHintText(loggingEnabled: settings.loggingEnabled), in: page, x: Self.rowMargin, y: y, width: rowWidth)
    }

    // The askForTaskName hint's own two variants, keyed only on
    // loggingEnabled — logging on makes the prompt mandatory regardless of
    // this setting's own value (SPEC.md §5/§7's target tab map), so the
    // hint describes that override rather than the setting's own current
    // checked state. Shared by buildRhythmTab's initial paint and
    // refreshAskForTaskHint's live update, same "one switch, not two
    // drifting copies" shape as trayClickHintText above.
    private static func askForTaskHintText(loggingEnabled: Bool) -> String {
        loggingEnabled
            ? "Session logging is on, so Pomoppi always asks — this setting only applies while logging is off."
            : "Pomoppi asks before each focus session. Leave it blank to skip."
    }

    // Called from the Diary tab's own "Record every session" checkbox
    // (SETTINGS_PLAN.md S4) — it's what overrides askForTaskName, so its
    // toggle is the other control this live hint has to react to, across
    // pages, the same "controls bake their text in at creation" gap
    // refreshTrayClickHint above exists for.
    private func refreshAskForTaskHint(loggingEnabled: Bool) {
        guard let askForTaskHintLabel else { return }
        setWindowText(askForTaskHintLabel, Self.askForTaskHintText(loggingEnabled: loggingEnabled))
    }

    // -- Appearance tab content -----------------------------------------------

    // Mirrors macOS's AppearanceTab's three CardPickerGrid sections (roommate/
    // window-edge/background) — the theme-preset grid, ink/paper
    // ChooseColorW pickers, and the size/opacity controls are a separate,
    // later chunk of this phase (see WINDOWS_PORT_PLAN.md's W7 entry).
    private func buildAppearanceTab(page: HWND, width: Int32) {
        let rowWidth = width - 2 * Self.rowMargin
        var y = Self.rowMargin

        addLabel("Roommate", in: page, x: Self.rowMargin, y: y, width: rowWidth, trackForScroll: true)
        y += 20
        y += addPickerGrid(
            kind: .friend, items: PomoppiSettings.friendIDs, in: page,
            x: Self.rowMargin, y: y, availableWidth: rowWidth,
            // 38 = 32 (image area, after drawPickerCard's 3px margin each
            // side) + 6 — the native 32x32 sprite at an exact 1x (the
            // user's preferred size for this grid specifically). A
            // non-integer ratio here (the old 56, i.e. 50/32 = 1.5625x)
            // can't produce uniform pixel blocks no matter how careful the
            // nearest-neighbor resample is — some source pixels must map
            // to 1 dest pixel and others to 2, which reads as "grainy" on
            // real pixel art. Confirmed live: even after fixing draw(into:)
            // itself (PixelCanvas+GDI.swift) to resample cleanly, cards
            // stayed visibly uneven until the ratio became a true integer.
            cardWidth: 38, cardHeight: 38,
            leftAlignLabel: true
        ) { [settingsStore] friend in
            settingsStore.update { $0.friend = friend }
        }
        y += Self.groupGap

        addLabel("Window edge", in: page, x: Self.rowMargin, y: y, width: rowWidth, trackForScroll: true)
        y += 20
        y += addPickerGrid(
            kind: .frameStyle, items: PomoppiSettings.frameStyles, in: page,
            x: Self.rowMargin, y: y, availableWidth: rowWidth,
            // 61x68 = 55x62 (image area, after the 3px margin) + 6 — the
            // frame preview's native crop (WidgetLayout.frameWidth/2,
            // frameHeight/2) at an exact 1x, same reasoning as the friend
            // grid above.
            cardWidth: 61, cardHeight: 68
        ) { [settingsStore] style in
            settingsStore.update { $0.frameStyle = style }
        }
        y += Self.groupGap

        addLabel("Background", in: page, x: Self.rowMargin, y: y, width: rowWidth, trackForScroll: true)
        y += 20
        y += addPickerGrid(
            kind: .background, items: PomoppiSettings.backgroundIDs, in: page,
            x: Self.rowMargin, y: y, availableWidth: rowWidth,
            // 116x68 = 110x62 (image area, after the 3px margin) + 6 — the
            // background preview's native crop (WidgetLayout.frameWidth,
            // frameHeight/2) at an exact 1x, same reasoning as the friend
            // grid above.
            cardWidth: 116, cardHeight: 68
        ) { [settingsStore] background in
            settingsStore.update { $0.background = background }
        }
        y += Self.groupGap

        addLabel("Theme", in: page, x: Self.rowMargin, y: y, width: rowWidth, trackForScroll: true)
        y += 20
        y += addThemePresetGrid(in: page, x: Self.rowMargin, y: y, availableWidth: rowWidth)
        y += Self.groupGap

        y += addColorPickerRow(label: "Ink", keyPath: \.inkColor, in: page, x: Self.rowMargin, y: y)
        y += addColorPickerRow(label: "Paper", keyPath: \.paperColor, in: page, x: Self.rowMargin, y: y)
        y += Self.groupGap

        addLabel("Size & transparency", in: page, x: Self.rowMargin, y: y, width: rowWidth, trackForScroll: true)
        y += 20
        y += addScalePicker(in: page, x: Self.rowMargin, y: y)
        y += addOpacitySlider(in: page, x: Self.rowMargin, y: y)
        addHint("1× is very small — 104×128 physical pixels.", in: page, x: Self.rowMargin, y: y, width: rowWidth, trackForScroll: true)
        y += lastHintHeight
        y += Self.rowMargin

        appearanceContentHeight = y
    }

    // A plain flow layout (left-to-right, wrapping at `availableWidth`) of
    // owner-drawn picker cards, one per item, each with a capitalized
    // STATIC label underneath — not a LazyVGrid-style adaptive column count
    // that re-centres per row, just enough to lay a handful of same-size
    // cards out legibly (every grid here fits on one row at this window's
    // fixed 560pt width, so wrapping is untested but kept as a safety net
    // rather than assumed away). Returns the total height consumed, so the
    // caller can advance its own running `y` past it.
    @discardableResult
    private func addPickerGrid(
        kind: PickerKind, items: [String], in page: HWND,
        x: Int32, y: Int32, availableWidth: Int32,
        cardWidth: Int32, cardHeight: Int32,
        leftAlignLabel: Bool = false,
        onSelect: @escaping (String) -> Void
    ) -> Int32 {
        let gap: Int32 = 10
        let labelHeight: Int32 = 16
        // A label can be wider than the card it sits under — friend cards
        // shrank to an exact 1x of their 32x32 sprite (38px) and names like
        // "Namidappi" don't fit that at the default GUI font, clipping
        // instead of wrapping. Measure this grid's own longest label
        // rather than special-casing the friend grid: any future card/
        // label-width combination gets the same safety net for free.
        // Frame-style/background names are already short enough that this
        // collapses to cardWidth, a no-op.
        let maxLabelWidth = items.map { measureTextWidth(displayName($0)) }.max() ?? 0
        let cellContentWidth = max(cardWidth, maxLabelWidth)
        let cellWidth = cellContentWidth + gap
        let columns = max(1, (availableWidth + gap) / cellWidth)
        let rowHeight = cardHeight + labelHeight + gap

        for (index, item) in items.enumerated() {
            let col = Int32(index) % columns
            let row = Int32(index) / columns
            // The card itself keeps its own position/size exactly as
            // before — only the label below it grows to absorb the extra
            // width, either centered on the card's horizontal center (the
            // default) or, for grids like the roommate one that want the
            // picture and name sharing one left edge, left-aligned flush
            // with the card's own left edge instead.
            let cardX = x + col * cellWidth
            let cardY = y + row * rowHeight
            addPickerCard(kind: kind, itemID: item, in: page, x: cardX, y: cardY, width: cardWidth, height: cardHeight, onSelect: onSelect)
            let labelX = leftAlignLabel ? cardX : cardX - (cellContentWidth - cardWidth) / 2
            addLabel(displayName(item), in: page, x: labelX, y: cardY + cardHeight + 2, width: cellContentWidth, height: labelHeight, centered: !leftAlignLabel, trackForScroll: true)
        }

        let rowCount = (Int32(items.count) + columns - 1) / columns
        return rowCount * rowHeight
    }

    // Measure-without-painting: grab a throwaway screen DC, swap in the
    // same DEFAULT_GUI_FONT applyDefaultFont puts on every label, ask
    // GetTextExtentPoint32W how wide the text renders, then put the DC's
    // own font back before releasing it. Used by addPickerGrid to size a
    // grid's label column to its actual longest name rather than guessing.
    private func measureTextWidth(_ text: String) -> Int32 {
        guard let hdc = GetDC(nil), let font = GetStockObject(DEFAULT_GUI_FONT) else { return 0 }
        defer { ReleaseDC(nil, hdc) }
        let previousFont = SelectObject(hdc, font)
        var size = SIZE()
        let wide = Array(text.utf16)
        wide.withUnsafeBufferPointer { ptr in
            _ = GetTextExtentPoint32W(hdc, ptr.baseAddress, Int32(ptr.count), &size)
        }
        SelectObject(hdc, previousFont)
        return size.cx
    }

    // A BS_OWNERDRAW push button: still fires the ordinary BN_CLICKED ->
    // WM_COMMAND that pushButtons/handleCommand already dispatch (owner-draw
    // only replaces painting, not click semantics), so selecting a card
    // reuses that exact path rather than a separate one. `onSelect` commits
    // the new setting; invalidateAllPickerCards then repaints every card so
    // the moved selection border (and, for a frameStyle change, the
    // background cards whose preview also depends on it) shows immediately.
    private func addPickerCard(
        kind: PickerKind, itemID: String, in page: HWND,
        x: Int32, y: Int32, width: Int32, height: Int32,
        onSelect: @escaping (String) -> Void
    ) {
        guard let button = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | BS_OWNERDRAW),
                x, y, width, height,
                page, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (picker card) failed with error \(GetLastError())")
        }
        pickerCards.append(PickerCardControl(hwnd: button, kind: kind, itemID: itemID))
        trackAppearanceControl(button, x: x, y: y)
        pushButtons.append(PushButtonControl(hwnd: button, onClick: { [weak self] in
            onSelect(itemID)
            self?.invalidateAllPickerCards()
        }))
    }

    private func invalidateAllPickerCards() {
        for card in pickerCards {
            InvalidateRect(card.hwnd, nil, true)
        }
    }

    // id strings are already lowercase (PomoppiSettings.friendIDs etc.) —
    // just capitalize the first letter rather than pulling in Foundation's
    // .capitalized for one line.
    private func displayName(_ id: String) -> String {
        guard let first = id.first else { return id }
        return first.uppercased() + id.dropFirst()
    }

    // The WM_DRAWITEM handler (forwarded here via pomoppiSettingsPageWndProc
    // + this window's own handleMessage, or built by hand for the scroll
    // rail — see handleScrollRailPaint): looks up which owner-drawn control
    // owns the drawn HWND — across all five kinds this tab now has (picker
    // cards, theme swatches, color-picker swatches, scale options, the
    // scroll rail) — builds its current appearance fresh from
    // settingsStore every time (not cached at button-creation time, so a
    // later color/theme change always repaints every dependent control
    // correctly), and draws it plus a selection border where relevant.
    private func handleDrawItem(lParam: LPARAM) -> LRESULT {
        guard let drawItem = UnsafeMutablePointer<DRAWITEMSTRUCT>(bitPattern: UInt(bitPattern: Int(lParam))) else { return 0 }
        let hwndItem = drawItem.pointee.hwndItem
        if let control = pickerCards.first(where: { $0.hwnd == hwndItem }) {
            drawPickerCard(control, drawItem: drawItem.pointee)
            return 1
        }
        if let swatch = themeSwatches.first(where: { $0.hwnd == hwndItem }) {
            drawThemeSwatch(swatch, drawItem: drawItem.pointee)
            return 1
        }
        if let picker = colorPickers.first(where: { $0.hwnd == hwndItem }) {
            drawColorSwatch(picker, drawItem: drawItem.pointee)
            return 1
        }
        if let option = scaleOptions.first(where: { $0.hwnd == hwndItem }) {
            drawScaleOption(option, drawItem: drawItem.pointee)
            return 1
        }
        if let option = schemeOptions.first(where: { $0.hwnd == hwndItem }) {
            drawSchemeOption(option, drawItem: drawItem.pointee)
            return 1
        }
        if let option = chimeOptions.first(where: { $0.hwnd == hwndItem }) {
            drawChimeOption(option, drawItem: drawItem.pointee)
            return 1
        }
        if let rail = appearanceScrollRail, rail == hwndItem {
            drawScrollRail(drawItem: drawItem.pointee)
            return 1
        }
        return 0
    }

    // Returns the cached preview for this card's current inputs, rendering
    // and caching it first on a miss — see pickerCardCache.
    private func pickerCardPreview(_ control: PickerCardControl, settings: PomoppiSettings) -> AppearancePreviews.Card? {
        let key = PickerCardCacheKey(
            kind: control.kind, itemID: control.itemID,
            inkColor: settings.inkColor, paperColor: settings.paperColor,
            frameStyle: control.kind == .background ? settings.frameStyle : "")
        if let cached = pickerCardCache[key] { return cached }
        let built: AppearancePreviews.Card?
        switch control.kind {
        case .friend:
            built = AppearancePreviews.friendIcon(friendID: control.itemID, inkColor: settings.inkColor, paperColor: settings.paperColor)
        case .frameStyle:
            built = AppearancePreviews.frameEdgeCard(frameStyle: control.itemID, inkColor: settings.inkColor, paperColor: settings.paperColor)
        case .background:
            built = AppearancePreviews.backgroundPatternCard(
                backgroundID: control.itemID, frameStyle: settings.frameStyle, inkColor: settings.inkColor, paperColor: settings.paperColor)
        }
        guard let built else { return nil }
        if pickerCardCache.count >= Self.pickerCardCacheLimit { pickerCardCache.removeAll() }
        pickerCardCache[key] = built
        return built
    }

    private func drawPickerCard(_ control: PickerCardControl, drawItem: DRAWITEMSTRUCT) {
        let settings = settingsStore.get()
        guard let card = pickerCardPreview(control, settings: settings) else { return }
        let isSelected: Bool
        switch control.kind {
        case .friend: isSelected = settings.friend == control.itemID
        case .frameStyle: isSelected = settings.frameStyle == control.itemID
        case .background: isSelected = settings.background == control.itemID
        }

        let hdc = drawItem.hDC
        var rect = drawItem.rcItem
        if let faceBrush = CreateSolidBrush(isDarkMode ? Self.colorref(hex: WindowsTheme.darkBackgroundHex) : GetSysColor(COLOR_BTNFACE)) {
            FillRect(hdc, &rect, faceBrush)
            DeleteObject(faceBrush)
        }

        // Inset a little from the button edge so the selection border below
        // has room to draw outside the image itself.
        let margin: Int32 = 3
        let imageRect = RECT(left: rect.left + margin, top: rect.top + margin, right: rect.right - margin, bottom: rect.bottom - margin)
        card.canvas.draw(into: hdc, destRect: imageRect, cropX: card.cropX, cropY: card.cropY, cropWidth: card.cropWidth, cropHeight: card.cropHeight)

        // A real Win32 bevel via drawBevel (DrawEdge in light mode, a
        // hand-painted dark one otherwise — see that function's own
        // comment for why) rather than a flat colored stroke — see
        // drawSelectionBorder's own comment just below for the full
        // reasoning (raised/sunken + accent ring), duplicated here rather
        // than called into since this card's border has always drawn its
        // own copy of this block (it predates drawSelectionBorder's own
        // extraction).
        drawBevel(hdc: hdc, rect: rect, sunken: isSelected)
        if isSelected {
            let inset: Int32 = 2
            let accentRect = RECT(left: rect.left + inset, top: rect.top + inset, right: rect.right - inset, bottom: rect.bottom - inset)
            if let accentPen = CreatePen(PS_SOLID, 2, GetSysColor(COLOR_HIGHLIGHT)) {
                let previousPen = SelectObject(hdc, accentPen)
                let previousBrush = SelectObject(hdc, GetStockObject(NULL_BRUSH))
                Rectangle(hdc, accentRect.left, accentRect.top, accentRect.right, accentRect.bottom)
                SelectObject(hdc, previousPen)
                SelectObject(hdc, previousBrush)
                DeleteObject(accentPen)
            }
        }
    }

    // DrawEdge's own bevel colors (COLOR_BTNSHADOW/COLOR_BTNHIGHLIGHT/
    // COLOR_3DDKSHADOW/...) come from GetSysColor like everything else,
    // and — confirmed live via a pixel-level screenshot comparison, same
    // RGB values at the same physical spot in both themes — don't
    // themselves shift under the OS dark/light setting either, same as
    // COLOR_BTNFACE. That's exactly the complaint, not a non-issue: those
    // colors are tuned for COLOR_BTNFACE's light gray, and against
    // darkBackgroundHex the bright COLOR_BTNHIGHLIGHT edge reads as a
    // glaring white line rather than a subtle highlight — confirmed live
    // via screenshot (zoom_bottom.png). Dark mode paints the bevel by hand
    // instead: raised = darkElevatedHex top/left, darkBevelShadowHex
    // bottom/right; sunken is the reverse — same 1px-per-edge FillRect
    // technique drawTabControlDark already uses for the tab strip's own
    // outline, just picking two shades that actually sit on either side of
    // darkBackgroundHex instead of COLOR_BTNFACE.
    private func drawBevel(hdc: HDC?, rect: RECT, sunken: Bool) {
        guard isDarkMode else {
            var edgeRect = rect
            // BF_RECT itself doesn't import (ClangImporter marks it
            // "structure not supported" since it's defined as an OR of the
            // four edge flags rather than its own literal) — spelled out
            // by hand instead.
            DrawEdge(hdc, &edgeRect, UINT(sunken ? EDGE_SUNKEN : EDGE_RAISED), UINT(BF_LEFT | BF_TOP | BF_RIGHT | BF_BOTTOM))
            return
        }
        guard let lightBrush = CreateSolidBrush(Self.colorref(hex: Self.darkElevatedHex)),
              let shadowBrush = CreateSolidBrush(Self.colorref(hex: Self.darkBevelShadowHex)) else { return }
        defer {
            DeleteObject(lightBrush)
            DeleteObject(shadowBrush)
        }
        let topLeftBrush = sunken ? shadowBrush : lightBrush
        let bottomRightBrush = sunken ? lightBrush : shadowBrush
        var top = RECT(left: rect.left, top: rect.top, right: rect.right, bottom: rect.top + 1)
        var left = RECT(left: rect.left, top: rect.top, right: rect.left + 1, bottom: rect.bottom)
        var bottom = RECT(left: rect.left, top: rect.bottom - 1, right: rect.right, bottom: rect.bottom)
        var right = RECT(left: rect.right - 1, top: rect.top, right: rect.right, bottom: rect.bottom)
        FillRect(hdc, &top, topLeftBrush)
        FillRect(hdc, &left, topLeftBrush)
        FillRect(hdc, &bottom, bottomRightBrush)
        FillRect(hdc, &right, bottomRightBrush)
    }

    // A generic bordered-rectangle helper every owner-drawn control below
    // ends its own painting with — pulled out once drawPickerCard's own
    // border block started repeating a third time (theme swatches, color
    // swatches, scale options all want the same frame). drawBevel above
    // (EDGE_RAISED unselected, EDGE_SUNKEN selected — the user's own
    // explicit ask, replacing a flat single-color stroke this used to
    // draw) rather than GDI+'s RoundRect, which has no anti-aliasing and
    // reads worse, not better, at these card sizes (rejected in design
    // review). Selected state keeps a thin COLOR_HIGHLIGHT ring inset
    // inside the sunken bevel — confirmed identical pixel-for-pixel
    // between themes (it tracks the user's accent-color choice, not
    // light/dark specifically), which is exactly why it still reads fine
    // in both: a strong, fixed accent blue has enough contrast against
    // either a light or a dark page background on its own — so selection
    // is never just a squint-at-the-bevel-direction question, an
    // accessibility point from design review.
    private func drawSelectionBorder(hdc: HDC?, rect: RECT, isSelected: Bool) {
        drawBevel(hdc: hdc, rect: rect, sunken: isSelected)
        guard isSelected else { return }
        let inset: Int32 = 2
        let accentRect = RECT(left: rect.left + inset, top: rect.top + inset, right: rect.right - inset, bottom: rect.bottom - inset)
        guard let accentPen = CreatePen(PS_SOLID, 2, GetSysColor(COLOR_HIGHLIGHT)) else { return }
        let previousPen = SelectObject(hdc, accentPen)
        let previousBrush = SelectObject(hdc, GetStockObject(NULL_BRUSH))
        Rectangle(hdc, accentRect.left, accentRect.top, accentRect.right, accentRect.bottom)
        SelectObject(hdc, previousPen)
        SelectObject(hdc, previousBrush)
        DeleteObject(accentPen)
    }

    // hex "#RRGGBB" -> (r,g,b) — a local copy of PixelCanvas's own private
    // rgb(hex:) (that one stays private to PixelCanvas.swift), needed here
    // for the plain GDI-brush swatches below that don't go through
    // PixelCanvas/AppearancePreviews at all.
    private static func rgbComponents(hex: String) -> (UInt8, UInt8, UInt8) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return (0, 0, 0) }
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    private static func colorref(hex: String) -> COLORREF {
        let (r, g, b) = rgbComponents(hex: hex)
        return COLORREF(DWORD(r) | (DWORD(g) << 8) | (DWORD(b) << 16))
    }

    // -- Appearance tab: theme presets ----------------------------------------

    // Mirrors macOS's ThemePresetPicker: a plain two-color swatch (paper
    // fill + ink dot) per preset, no PixelCanvas involved since there's no
    // art to preview here, just the two colors themselves. Same flow-layout
    // shape as addPickerGrid, just with a smaller/plainer card.
    @discardableResult
    private func addThemePresetGrid(in page: HWND, x: Int32, y: Int32, availableWidth: Int32) -> Int32 {
        let swatchSize: Int32 = 36
        let gap: Int32 = 10
        let labelHeight: Int32 = 14
        let cellWidth = swatchSize + gap
        let columns = max(1, (availableWidth + gap) / cellWidth)
        let rowHeight = swatchSize + labelHeight + 2 + gap

        for (index, preset) in Self.themePresets.enumerated() {
            let col = Int32(index) % columns
            let row = Int32(index) / columns
            let swatchX = x + col * cellWidth
            let swatchY = y + row * rowHeight
            guard let button = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, nil,
                    DWORD(WS_CHILD | WS_VISIBLE | BS_OWNERDRAW),
                    swatchX, swatchY, swatchSize, swatchSize,
                    page, nil, Self.hInstance, nil)
            }) else {
                fatalError("CreateWindowExW (theme swatch) failed with error \(GetLastError())")
            }
            themeSwatches.append(ThemeSwatchControl(hwnd: button, preset: preset))
            trackAppearanceControl(button, x: swatchX, y: swatchY)
            pushButtons.append(PushButtonControl(hwnd: button, onClick: { [weak self, settingsStore] in
                settingsStore.update {
                    $0.inkColor = preset.ink
                    $0.paperColor = preset.paper
                }
                self?.invalidateEverythingColorDependent()
            }))
            addLabel(preset.name, in: page, x: swatchX - 7, y: swatchY + swatchSize + 2, width: swatchSize + 14, height: labelHeight, centered: true, trackForScroll: true)
        }

        let rowCount = (Int32(Self.themePresets.count) + columns - 1) / columns
        return rowCount * rowHeight
    }

    private func drawThemeSwatch(_ swatch: ThemeSwatchControl, drawItem: DRAWITEMSTRUCT) {
        let settings = settingsStore.get()
        let isSelected = settings.inkColor == swatch.preset.ink && settings.paperColor == swatch.preset.paper
        let hdc = drawItem.hDC
        var rect = drawItem.rcItem

        if let paperBrush = CreateSolidBrush(Self.colorref(hex: swatch.preset.paper)) {
            FillRect(hdc, &rect, paperBrush)
            DeleteObject(paperBrush)
        }

        // The ink dot: a filled circle centred in the swatch, inset by a
        // third on each side (mirrors the ZStack's Circle sized well
        // inside the RoundedRectangle on macOS). NULL_PEN skips an outline
        // so the fill alone defines the dot's edge.
        let inset = (rect.right - rect.left) / 3
        if let inkBrush = CreateSolidBrush(Self.colorref(hex: swatch.preset.ink)) {
            let previousBrush = SelectObject(hdc, inkBrush)
            let previousPen = SelectObject(hdc, GetStockObject(NULL_PEN))
            Ellipse(hdc, rect.left + inset, rect.top + inset, rect.right - inset, rect.bottom - inset)
            SelectObject(hdc, previousBrush)
            SelectObject(hdc, previousPen)
            DeleteObject(inkBrush)
        }

        drawSelectionBorder(hdc: hdc, rect: rect, isSelected: isSelected)
    }

    // -- Appearance tab: ink/paper color pickers -------------------------------

    // Mirrors macOS's ColorPicker("Ink"/"Paper", ...): a plain swatch
    // button showing the current color that opens the Win32 common color
    // dialog (ChooseColorW) on click. `keyPath` is the only thing that
    // differs between the Ink and Paper rows — everything else is shared.
    @discardableResult
    private func addColorPickerRow(label: String, keyPath: WritableKeyPath<PomoppiSettings, String>, in page: HWND, x: Int32, y: Int32) -> Int32 {
        addLabel(label, in: page, x: x, y: y + 3, width: 100, trackForScroll: true)
        let swatchWidth: Int32 = 60
        guard let button = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | BS_OWNERDRAW),
                x + 108, y, swatchWidth, 22,
                page, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (color picker) failed with error \(GetLastError())")
        }
        colorPickers.append(ColorPickerControl(hwnd: button, keyPath: keyPath))
        trackAppearanceControl(button, x: x + 108, y: y)
        pushButtons.append(PushButtonControl(hwnd: button, onClick: { [weak self] in
            self?.pickColor(keyPath: keyPath)
        }))
        return Self.rowHeight
    }

    private func drawColorSwatch(_ picker: ColorPickerControl, drawItem: DRAWITEMSTRUCT) {
        let hex = settingsStore.get()[keyPath: picker.keyPath]
        let hdc = drawItem.hDC
        var rect = drawItem.rcItem
        if let fillBrush = CreateSolidBrush(Self.colorref(hex: hex)) {
            FillRect(hdc, &rect, fillBrush)
            DeleteObject(fillBrush)
        }
        drawSelectionBorder(hdc: hdc, rect: rect, isSelected: false)
    }

    // ChooseColorW is a real modal common dialog — it runs its own message
    // loop until OK/Cancel, blocking this WndProc for that stretch, same as
    // any other Win32 common dialog (identical in spirit to how a
    // recording row's key capture already "blocks" the rest of the UI
    // conceptually, just via a real OS-owned modal here instead of our own
    // state machine). lpCustColors must point at memory that outlives the
    // call, hence `customColors` living at instance scope rather than as a
    // local var here.
    private func pickColor(keyPath: WritableKeyPath<PomoppiSettings, String>) {
        let currentHex = settingsStore.get()[keyPath: keyPath]
        var colorDialog = CHOOSECOLORW()
        colorDialog.lStructSize = DWORD(MemoryLayout<CHOOSECOLORW>.size)
        colorDialog.hwndOwner = hwnd
        colorDialog.rgbResult = Self.colorref(hex: currentHex)
        colorDialog.Flags = DWORD(CC_RGBINIT) | DWORD(CC_FULLOPEN)

        let picked = customColors.withUnsafeMutableBufferPointer { buffer -> Bool in
            colorDialog.lpCustColors = buffer.baseAddress
            return ChooseColorW(&colorDialog)
        }
        guard picked else { return }

        let r = UInt8(colorDialog.rgbResult & 0xFF)
        let g = UInt8((colorDialog.rgbResult >> 8) & 0xFF)
        let b = UInt8((colorDialog.rgbResult >> 16) & 0xFF)
        let hex = String(format: "#%02X%02X%02X", r, g, b)
        settingsStore.update { $0[keyPath: keyPath] = hex }
        invalidateEverythingColorDependent()
    }

    // ink/paper affect the picker-card previews (friend/frameStyle/
    // background all tint with the current colors) and the theme-preset
    // grid's own selection border (an exact ink+paper match), plus both
    // color-picker swatches themselves — every color-dependent surface,
    // invalidated together rather than tracking which one caller actually
    // needs which subset (cheap: at most ~20 tiny owner-drawn buttons).
    private func invalidateEverythingColorDependent() {
        invalidateAllPickerCards()
        for swatch in themeSwatches { InvalidateRect(swatch.hwnd, nil, true) }
        for picker in colorPickers { InvalidateRect(picker.hwnd, nil, true) }
    }

    // -- Appearance tab: scale + opacity ---------------------------------------

    // Mirrors macOS's segmented Picker("Size", ...) over [1,2,3,4] — 4
    // plain owner-drawn buttons standing in for the segmented control Win32
    // has no native equivalent of, each showing its own "N×" and a
    // highlighted fill when selected.
    @discardableResult
    private func addScalePicker(in page: HWND, x: Int32, y: Int32) -> Int32 {
        addLabel("Size", in: page, x: x, y: y + 3, width: 100, trackForScroll: true)
        let buttonWidth: Int32 = 50
        let height: Int32 = 24
        let gap: Int32 = 6
        for (index, value) in [1, 2, 3, 4].enumerated() {
            let bx = x + 108 + Int32(index) * (buttonWidth + gap)
            guard let button = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, nil,
                    DWORD(WS_CHILD | WS_VISIBLE | BS_OWNERDRAW),
                    bx, y, buttonWidth, height,
                    page, nil, Self.hInstance, nil)
            }) else {
                fatalError("CreateWindowExW (scale option) failed with error \(GetLastError())")
            }
            scaleOptions.append(ScaleOptionControl(hwnd: button, value: value))
            trackAppearanceControl(button, x: bx, y: y)
            pushButtons.append(PushButtonControl(hwnd: button, onClick: { [weak self, settingsStore] in
                settingsStore.update { $0.scale = value }
                self?.invalidateAllScaleOptions()
            }))
        }
        return height
    }

    private func invalidateAllScaleOptions() {
        for option in scaleOptions {
            InvalidateRect(option.hwnd, nil, true)
        }
    }

    // The Appearance tab's own first section, ahead of Roommate — same 3
    // owner-drawn segmented buttons as addScalePicker above, just over
    // PomoppiSettings.colorSchemeIDs instead of the [1,2,3,4] scale values.
    // A click here also has to re-resolve and re-apply isDarkMode itself
    // (addScalePicker's onSelect only ever touches PomoppiSettings.scale,
    // never this window's own dark/light paint), unlike every other
    // Appearance control's onSelect closure.
    private func addColorSchemePicker(in page: HWND, x: Int32, y: Int32) -> Int32 {
        let buttonWidth: Int32 = 64
        let height: Int32 = 24
        let gap: Int32 = 6
        for (index, value) in PomoppiSettings.colorSchemeIDs.enumerated() {
            let bx = x + Int32(index) * (buttonWidth + gap)
            guard let button = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, nil,
                    DWORD(WS_CHILD | WS_VISIBLE | BS_OWNERDRAW),
                    bx, y, buttonWidth, height,
                    page, nil, Self.hInstance, nil)
            }) else {
                fatalError("CreateWindowExW (color scheme option) failed with error \(GetLastError())")
            }
            schemeOptions.append(SchemeOptionControl(hwnd: button, value: value))
            pushButtons.append(PushButtonControl(hwnd: button, onClick: { [weak self, settingsStore] in
                settingsStore.update { $0.colorScheme = value }
                guard let self else { return }
                self.isDarkMode = self.resolveDarkMode()
                self.applyTheme()
                self.invalidateAllSchemeOptions()
            }))
        }
        return height
    }

    private func invalidateAllSchemeOptions() {
        for option in schemeOptions {
            InvalidateRect(option.hwnd, nil, true)
        }
    }

    // The Sound tab's chime picker — same owner-drawn segmented shape as
    // addColorSchemePicker just above, over PomoppiSettings.chimeIDs
    // instead of colorSchemeIDs. Built from the array rather than hardcoded
    // (same rule CLAUDE.md gives for the friend/background pickers), so a
    // fourth pack needs no changes here.
    @discardableResult
    private func addChimePicker(in page: HWND, x: Int32, y: Int32, width: Int32) -> Int32 {
        let ids = PomoppiSettings.chimeIDs
        let height: Int32 = 24
        let gap: Int32 = 6
        let buttonWidth = (width - gap * Int32(ids.count - 1)) / Int32(ids.count)
        for (index, value) in ids.enumerated() {
            let bx = x + Int32(index) * (buttonWidth + gap)
            guard let button = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, nil,
                    DWORD(WS_CHILD | WS_VISIBLE | BS_OWNERDRAW),
                    bx, y, buttonWidth, height,
                    page, nil, Self.hInstance, nil)
            }) else {
                fatalError("CreateWindowExW (chime option) failed with error \(GetLastError())")
            }
            chimeOptions.append(ChimeOptionControl(hwnd: button, value: value))
            // Each option is its own button, so unlike macOS's segmented
            // Picker this fires BN_CLICKED on every click, including a
            // reselect of the already-selected option — previewing the
            // chime here on every click, no separate Play/Test button
            // needed for a replay case that doesn't exist on this side.
            pushButtons.append(PushButtonControl(hwnd: button, onClick: { [weak self, settingsStore] in
                settingsStore.update { $0.chime = value }
                self?.invalidateAllChimeOptions()
                self?.chimePlayer.play(chime: value, focusEnd: true)
            }))
        }
        return height
    }

    private func invalidateAllChimeOptions() {
        for option in chimeOptions {
            InvalidateRect(option.hwnd, nil, true)
        }
    }

    private func drawScaleOption(_ option: ScaleOptionControl, drawItem: DRAWITEMSTRUCT) {
        let isSelected = settingsStore.get().scale == option.value
        drawSegmentedOption(text: "\(option.value)×", isSelected: isSelected, drawItem: drawItem)
    }

    private func drawSchemeOption(_ option: SchemeOptionControl, drawItem: DRAWITEMSTRUCT) {
        let isSelected = settingsStore.get().colorScheme == option.value
        drawSegmentedOption(text: displayName(option.value), isSelected: isSelected, drawItem: drawItem)
    }

    private func drawChimeOption(_ option: ChimeOptionControl, drawItem: DRAWITEMSTRUCT) {
        let isSelected = settingsStore.get().chime == option.value
        drawSegmentedOption(text: displayName(option.value), isSelected: isSelected, drawItem: drawItem)
    }

    // The shared paint both scale (Size & transparency, "N×") and
    // color-scheme (top of Appearance, "Auto"/"Light"/"Dark") owner-drawn
    // segmented buttons go through — only the display text and the
    // isSelected test differ between the two callers just above, so this
    // is the one place their bevel/text painting logic lives.
    private func drawSegmentedOption(text: String, isSelected: Bool, drawItem: DRAWITEMSTRUCT) {
        let hdc = drawItem.hDC
        var rect = drawItem.rcItem
        // Selected already uses COLOR_HIGHLIGHT/COLOR_HIGHLIGHTTEXT, which
        // (like drawPickerCard's own accent ring) read fine unmodified in
        // both themes on their own — confirmed live, a fixed accent color
        // with enough contrast either way, not something that actually
        // changes value under dark mode (see drawSelectionBorder's own
        // comment) — only the unselected fill/text below need an explicit
        // override.
        let backgroundColor = isSelected ? GetSysColor(COLOR_HIGHLIGHT) : (isDarkMode ? Self.colorref(hex: WindowsTheme.darkBackgroundHex) : GetSysColor(COLOR_BTNFACE))
        if let backgroundBrush = CreateSolidBrush(backgroundColor) {
            FillRect(hdc, &rect, backgroundBrush)
            DeleteObject(backgroundBrush)
        }

        let textUTF16 = Array(text.utf16) + [0]
        SetBkMode(hdc, Int32(TRANSPARENT))
        SetTextColor(hdc, isSelected ? GetSysColor(COLOR_HIGHLIGHTTEXT) : (isDarkMode ? Self.colorref(hex: WindowsTheme.darkTextHex) : GetSysColor(COLOR_BTNTEXT)))
        var textRect = rect
        _ = textUTF16.withUnsafeBufferPointer { ptr in
            DrawTextW(hdc, ptr.baseAddress, -1, &textRect, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
        }

        drawSelectionBorder(hdc: hdc, rect: rect, isSelected: false)
    }

    // Mirrors macOS's Slider(value: opacity, in: 0.3...1.0, step: 0.1) plus
    // its trailing "NN%" readout. Trackbar32 positions are plain integers,
    // so opacity (a Double 0.3...1.0) maps to ticks 3...10 and back by a
    // factor of 10 — TBM_SETRANGE's lParam is the traditional
    // MAKELONG(min, max) packing (unlike UDM_SETRANGE32's separate
    // wParam/lParam), safe to build by hand here since both bounds fit
    // comfortably in 16 bits.
    @discardableResult
    private func addOpacitySlider(in page: HWND, x: Int32, y: Int32) -> Int32 {
        addLabel("Opacity", in: page, x: x, y: y + 3, width: 100, trackForScroll: true)
        let settings = settingsStore.get()
        let trackWidth: Int32 = 200
        let height: Int32 = 24
        guard let trackbar = (Self.trackbarClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE) | DWORD(bitPattern: TBS_HORZ) | DWORD(bitPattern: TBS_AUTOTICKS),
                x + 108, y, trackWidth, height,
                page, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (opacity trackbar) failed with error \(GetLastError())")
        }
        applyDefaultFont(trackbar)
        SendMessageW(trackbar, UINT(TBM_SETRANGE), WPARAM(1), LPARAM(Int(3) | (Int(10) << 16)))
        SendMessageW(trackbar, UINT(TBM_SETPOS), WPARAM(1), LPARAM(Int((settings.opacity * 10).rounded())))
        opacityTrackbar = trackbar
        trackAppearanceControl(trackbar, x: x + 108, y: y)

        let percent = Int((settings.opacity * 100).rounded())
        opacityValueLabel = addLabel("\(percent)%", in: page, x: x + 108 + trackWidth + 8, y: y + 4, width: 44, height: 18, trackForScroll: true)
        return height
    }

    // WM_HSCROLL from the opacity trackbar (forwarded here via
    // pomoppiSettingsPageWndProc + handleMessage) — fires on every arrow
    // click, drag step, and thumb release alike, so just re-reading the
    // trackbar's own current position covers every notification code
    // without switching on which one this particular message was.
    private func handleOpacityScroll(lParam: LPARAM) {
        guard let trackbar = opacityTrackbar, HWND(bitPattern: Int(lParam)) == trackbar else { return }
        let pos = Int(SendMessageW(trackbar, UINT(TBM_GETPOS), 0, 0))
        let opacity = Double(pos) / 10.0
        settingsStore.update { $0.opacity = opacity }
        if let label = opacityValueLabel {
            setWindowText(label, "\(Int((opacity * 100).rounded()))%")
        }
    }

    // NM_CUSTOMDRAW from the opacity trackbar (forwarded here the exact
    // same WM_NOTIFY route as TCN_SELCHANGE/UDN_DELTAPOS just above) —
    // msctls_trackbar32 has no dark visual style either (same story as
    // the tab strip and the up-down controls, see setControlDarkTheme's
    // own comment), but unlike either of those this control actually
    // documents a custom-draw notification of its own, so this takes that
    // route instead of a second WM_PAINT subclass. Light mode returns
    // CDRF_DODEFAULT at every stage, unconditionally — native rendering,
    // byte-for-byte unchanged.
    private func handleOpacityTrackbarCustomDraw(lParam: LPARAM) -> LRESULT {
        guard let draw = UnsafeMutablePointer<NMCUSTOMDRAW>(bitPattern: UInt(bitPattern: Int(lParam))) else {
            return LRESULT(CDRF_DODEFAULT)
        }
        guard isDarkMode else { return LRESULT(CDRF_DODEFAULT) }

        if draw.pointee.dwDrawStage == DWORD(CDDS_PREPAINT) {
            // The strip behind the channel/thumb/tics — confirmed live as
            // a light halo around the channel without this, since none of
            // the CDDS_ITEMPREPAINT fills below cover the control's own
            // full rect.
            var rect = draw.pointee.rc
            if let brush = WindowsTheme.darkBackgroundBrush { FillRect(draw.pointee.hdc, &rect, brush) }
            return LRESULT(CDRF_NOTIFYITEMDRAW)
        }

        guard draw.pointee.dwDrawStage == DWORD(CDDS_ITEMPREPAINT) else { return LRESULT(CDRF_DODEFAULT) }
        var rect = draw.pointee.rc
        switch draw.pointee.dwItemSpec {
        case UInt64(TBCD_CHANNEL):
            if let fillBrush = CreateSolidBrush(Self.colorref(hex: Self.darkScrollTrackHex)) {
                FillRect(draw.pointee.hdc, &rect, fillBrush)
                DeleteObject(fillBrush)
            }
            // A plain flat outline (not drawBevel's raised/sunken pair) —
            // the channel is a groove the thumb sits in, not a clickable
            // card/button, so one shade is enough to set it apart from the
            // page fill behind it.
            if let outlineBrush = CreateSolidBrush(Self.colorref(hex: Self.darkElevatedHex)) {
                var top = RECT(left: rect.left, top: rect.top, right: rect.right, bottom: rect.top + 1)
                var bottom = RECT(left: rect.left, top: rect.bottom - 1, right: rect.right, bottom: rect.bottom)
                var left = RECT(left: rect.left, top: rect.top, right: rect.left + 1, bottom: rect.bottom)
                var right = RECT(left: rect.right - 1, top: rect.top, right: rect.right, bottom: rect.bottom)
                FillRect(draw.pointee.hdc, &top, outlineBrush)
                FillRect(draw.pointee.hdc, &bottom, outlineBrush)
                FillRect(draw.pointee.hdc, &left, outlineBrush)
                FillRect(draw.pointee.hdc, &right, outlineBrush)
                DeleteObject(outlineBrush)
            }
            return LRESULT(CDRF_SKIPDEFAULT)
        case UInt64(TBCD_THUMB):
            if let thumbBrush = CreateSolidBrush(Self.colorref(hex: Self.darkElevatedHex)) {
                FillRect(draw.pointee.hdc, &rect, thumbBrush)
                DeleteObject(thumbBrush)
            }
            drawBevel(hdc: draw.pointee.hdc, rect: rect, sunken: false)
            return LRESULT(CDRF_SKIPDEFAULT)
        default:
            // TBCD_TICS (TBS_AUTOTICKS' own tick marks) — hidden outright
            // rather than hand-painted: purely decorative on this slider,
            // and the user's own ask accepted hiding them as the simpler
            // option.
            return LRESULT(CDRF_SKIPDEFAULT)
        }
    }

    // -- Appearance tab: scrolling ---------------------------------------------

    // Repositions every tracked child to its recorded base position minus
    // the new scroll offset, rather than ScrollWindowEx's SW_SCROLLCHILDREN
    // (tried first — see AppearanceControlPosition's own comment for why
    // that broke live: MSDN documents that SW_SCROLLCHILDREN "does not
    // properly update the screen" for children straddling the scroll
    // boundary, and this page's owner-drawn buttons hit exactly that
    // case, confirmed by a real screenshot showing stale ghosted fragments
    // after scrolling). Owner-drawn buttons need no changes of their own:
    // DRAWITEMSTRUCT.rcItem is always in the control's own client-rect
    // terms, independent of where it currently sits.
    //
    // The moves go through one BeginDeferWindowPos/EndDeferWindowPos batch
    // so Windows repositions all of them in a single pass (every child
    // shifts by the same delta, so the batch is effectively one region
    // move): each child's already-painted pixels are copied to its new
    // spot, only the strips that actually changed get invalidated (the
    // page background a child vacated, the part of a child that just
    // scrolled in from outside the page's client area), and the trailing
    // RDW_UPDATENOW flushes exactly those pending paints synchronously —
    // so a drag's rapid-fire WM_MOUSEMOVE deltas never queue up behind
    // posted WM_PAINTs. This used to force a full RDW_INVALIDATE|RDW_ERASE
    // repaint of the page and every child on every step instead; with the
    // page erasing straight over its children (no WS_CLIPCHILDREN then)
    // and every picker card re-rendering its preview from scratch, one
    // step took several display frames and the erase-then-refill was
    // visible as flicker throughout a thumb drag. The page's own erase is
    // now clipped to the gaps between children (WS_CLIPCHILDREN, see
    // createPage) and card previews are cached (pickerCardCache), so even
    // the full-repaint paths that remain (applyTheme, a resize) are cheap.
    private func scrollAppearance(by delta: Int32) {
        guard let page = appearancePage else { return }
        var clientRect = RECT()
        GetClientRect(page, &clientRect)
        let visibleHeight = clientRect.bottom - clientRect.top
        let maxScroll = max(0, appearanceContentHeight - visibleHeight)
        let newScrollY = min(max(0, appearanceScrollY + delta), maxScroll)
        guard newScrollY != appearanceScrollY else { return }
        appearanceScrollY = newScrollY

        var batch = BeginDeferWindowPos(Int32(appearanceControlPositions.count))
        for control in appearanceControlPositions {
            batch = DeferWindowPos(
                batch, control.hwnd, nil, control.baseX, control.baseY - newScrollY, 0, 0,
                UINT(SWP_NOZORDER) | UINT(SWP_NOSIZE) | UINT(SWP_NOACTIVATE))
        }
        EndDeferWindowPos(batch)
        // The rail doesn't move, so nothing above invalidated it — its
        // thumb still has to be repainted at the new offset. No erase:
        // drawScrollRail repaints the full track itself, and an erase
        // first would just be one more blank-then-refill flash per step.
        if let rail = appearanceScrollRail {
            InvalidateRect(rail, nil, false)
        }
        RedrawWindow(page, nil, nil, UINT(RDW_UPDATENOW) | UINT(RDW_ALLCHILDREN))
    }

    // WM_MOUSEWHEEL isn't a scrollbar notification at all — it's delivered
    // straight to whichever HWND currently owns keyboard focus (the
    // Appearance page's own owner-drawn buttons grab focus on click, same
    // as any BUTTON-derived control), *not* whatever the cursor happens to
    // be hovering. This app never has to chase that down by hand, though:
    // DefWindowProc itself walks an unhandled WM_MOUSEWHEEL up the parent
    // chain automatically (a real, documented Win32 behavior, not
    // something this app opts into), so neither pomoppiSettingsPageWndProc
    // nor any owner-drawn button needs its own forwarding case for this
    // message the way WM_COMMAND/WM_NOTIFY/WM_HSCROLL above do — it simply
    // arrives here once it bubbles all the way up to the top-level window.
    // Guarded to the Appearance page specifically so the exact same
    // message, delivered while any other tab happens to have focus, is a
    // no-op rather than silently repositioning an invisible page's
    // controls.
    private func handleMouseWheel(wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        guard let appearancePage, IsWindowVisible(appearancePage) else {
            return DefWindowProcW(hwnd, UINT(WM_MOUSEWHEEL), wParam, lParam)
        }
        // GET_WHEEL_DELTA_WPARAM: wParam's high word, a *signed* 16-bit
        // multiple of WHEEL_DELTA (120) per notch — reconstructed via
        // Int16(bitPattern:) rather than this file's usual
        // Int32(truncatingIfNeeded:) idiom (see handleCommand's
        // notificationCode extraction for that one) since that one doesn't
        // sign-extend a 16-bit negative value out of a 32-bit unsigned
        // intermediate. Positive = wheel rotated forward/away from the
        // user; that sign already reflects whatever scroll-direction
        // preference the user has set system-wide (mouse wheel settings,
        // or a touchpad driver's own "reverse scrolling" toggle) —
        // forwarded through unmodified into scrollAppearance's existing
        // up=negative/down=positive convention, so forward/positive
        // decreases the offset, matching every other scroll entry point
        // (the rail's own drag/track-click below included) without this
        // code re-deciding direction.
        let highWord = UInt16(truncatingIfNeeded: UInt32(truncatingIfNeeded: wParam) >> 16)
        let notches = Double(Int16(bitPattern: highWord)) / 120.0
        // 60px per notch — tuned by feel against a real wheel in the VM,
        // not a derived value.
        scrollAppearance(by: Int32((-notches * 60).rounded()))
        return 0
    }

    // -- Appearance tab: scroll rail ---------------------------------------

    // Reuses the exact gutter width buildAppearanceTab's caller already
    // reserved for a scrollbar (see createPage's Appearance case) —
    // spanning the page's own full visible height, flush against its right
    // edge. Not tracked via trackAppearanceControl: every other control on
    // this page scrolls with the content, but the rail itself is the thing
    // doing the scrolling and must stay put.
    private func createAppearanceScrollRail(page: HWND, pageWidth: Int32, pageHeight: Int32) {
        let railWidth = GetSystemMetrics(SM_CXVSCROLL)
        guard let rail = (Self.scrollRailClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE),
                pageWidth - railWidth, 0, railWidth, pageHeight,
                page, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (scroll rail) failed with error \(GetLastError())")
        }
        appearanceScrollRail = rail
    }

    // Same three numbers SetScrollInfo used to receive before this control
    // replaced the native scrollbar (content height, current scroll
    // offset, and the page's own visible height — here just `visibleHeight`
    // since the rail is always resized to exactly match it, see
    // createAppearanceScrollRail/handleResize) — shared by the paint
    // handler (draws the thumb) and the mouse-down handler (hit-tests
    // against it) so painting and interaction can never disagree about
    // where the thumb actually is.
    private func railThumbRect(visibleHeight: Int32) -> RECT {
        let railWidth = GetSystemMetrics(SM_CXVSCROLL)
        let metrics = railMetrics(visibleHeight: visibleHeight)
        guard metrics.maxScroll > 0 else {
            // Nothing to scroll: a full-height thumb reads as "everything
            // is already visible" rather than an oddly-floating short one
            // sitting at the top of an otherwise-empty rail.
            return RECT(left: 0, top: 0, right: railWidth, bottom: visibleHeight)
        }
        let thumbY = (metrics.travel * appearanceScrollY) / metrics.maxScroll
        return RECT(left: 0, top: thumbY, right: railWidth, bottom: thumbY + metrics.thumbHeight)
    }

    // The thumb-to-content ratio railThumbRect maps the scroll offset
    // through (offset -> thumb top) and handleScrollRailMouseMove maps
    // back through (thumb top -> offset) — one place for the math so the
    // two directions can't drift apart. `travel` is how far the thumb's
    // top edge can move (rail height minus thumb height); it covers
    // `maxScroll` pixels of content.
    private func railMetrics(visibleHeight: Int32) -> (maxScroll: Int32, thumbHeight: Int32, travel: Int32) {
        let contentHeight = max(appearanceContentHeight, visibleHeight)
        let maxScroll = contentHeight - visibleHeight
        let minThumbHeight: Int32 = 24
        let thumbHeight = min(visibleHeight, max(minThumbHeight, visibleHeight * visibleHeight / contentHeight))
        return (maxScroll, thumbHeight, visibleHeight - thumbHeight)
    }

    // hwnd here is always appearanceScrollRail itself (pomoppiScrollRailWndProc
    // already guarded that before calling in) — threaded through as a
    // parameter anyway rather than force-unwrapping the instance property
    // again in every case below.
    func handleScrollRailMessage(hwnd: HWND, message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        switch Int32(message) {
        case WM_PAINT:
            handleScrollRailPaint(hwnd: hwnd)
            return 0
        case WM_LBUTTONDOWN:
            handleScrollRailMouseDown(hwnd: hwnd, lParam: lParam)
            return 0
        case WM_MOUSEMOVE:
            handleScrollRailMouseMove(hwnd: hwnd, lParam: lParam)
            return 0
        case WM_LBUTTONUP:
            handleScrollRailMouseUp()
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }

    // Builds a real DRAWITEMSTRUCT by hand and hands it to handleDrawItem
    // exactly like a genuine WM_DRAWITEM would carry one — this control is
    // its own window class rather than a stock owner-draw BUTTON (see
    // pomoppiScrollRailWndProc's comment), so nothing generates that
    // message for it automatically; building one here is simpler than
    // teaching handleDrawItem a second, rail-specific entry point.
    private func handleScrollRailPaint(hwnd: HWND) {
        var paint = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &paint) else { return }
        defer { EndPaint(hwnd, &paint) }
        var clientRect = RECT()
        GetClientRect(hwnd, &clientRect)
        var drawItem = DRAWITEMSTRUCT()
        drawItem.hwndItem = hwnd
        drawItem.hDC = hdc
        drawItem.rcItem = clientRect
        withUnsafeMutablePointer(to: &drawItem) { ptr in
            _ = handleDrawItem(lParam: LPARAM(Int(bitPattern: ptr)))
        }
    }

    // WM_MOUSEMOVE/WM_LBUTTONDOWN/WM_LBUTTONUP pack client-area coordinates
    // into lParam as two signed 16-bit words (the GET_X_LPARAM/GET_Y_LPARAM
    // macros, which don't import into Swift — see WidgetInput.swift's own
    // logicalPoint for the same story); only Y matters here, the rail is a
    // vertical strip with no horizontal hit-testing of its own.
    private func railMouseY(fromLParam lParam: LPARAM) -> Int32 {
        let raw = UInt32(truncatingIfNeeded: lParam)
        return Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: raw >> 16)))
    }

    // Hit-tests against the thumb rect painting already uses: inside it
    // starts a drag (SetCapture so WM_MOUSEMOVE keeps arriving here even
    // once the cursor wanders outside the rail's own narrow strip
    // mid-drag), above/below it pages up/down exactly like SB_PAGEUP/
    // SB_PAGEDOWN used to.
    private func handleScrollRailMouseDown(hwnd: HWND, lParam: LPARAM) {
        var clientRect = RECT()
        GetClientRect(hwnd, &clientRect)
        let visibleHeight = clientRect.bottom - clientRect.top
        let y = railMouseY(fromLParam: lParam)
        let thumb = railThumbRect(visibleHeight: visibleHeight)
        if y >= thumb.top && y < thumb.bottom {
            railDragging = true
            railGrabOffset = y - thumb.top
            SetCapture(hwnd)
        } else if y < thumb.top {
            scrollAppearance(by: -visibleHeight)
        } else {
            scrollAppearance(by: visibleHeight)
        }
    }

    // The thumb follows the cursor, the way a native scrollbar's does:
    // the point grabbed on mouse-down (railGrabOffset, measured from the
    // thumb's top edge) stays under the cursor, and the thumb's new top
    // edge maps back to a content offset through railMetrics' ratio. This
    // used to pass the raw cursor delta straight into scrollAppearance as
    // a content delta instead — which made the thumb fall behind the
    // cursor by exactly the content/rail ratio on every drag, so a full
    // top-to-bottom drag needed the cursor to travel the whole content
    // height. Absolute rather than incremental so a cursor that wandered
    // past the rail's ends (SetCapture keeps the moves coming) snaps
    // straight back into sync once it returns, no accumulated drift;
    // scrollAppearance's own clamp handles the out-of-range part.
    private func handleScrollRailMouseMove(hwnd: HWND, lParam: LPARAM) {
        guard railDragging else { return }
        var clientRect = RECT()
        GetClientRect(hwnd, &clientRect)
        let metrics = railMetrics(visibleHeight: clientRect.bottom - clientRect.top)
        guard metrics.travel > 0 else { return }
        let thumbTop = railMouseY(fromLParam: lParam) - railGrabOffset
        let target = (thumbTop * metrics.maxScroll) / metrics.travel
        scrollAppearance(by: target - appearanceScrollY)
    }

    private func handleScrollRailMouseUp() {
        guard railDragging else { return }
        railDragging = false
        ReleaseCapture()
    }

    // Painted through the exact same WM_DRAWITEM/handleDrawItem path as
    // every other owner-drawn control on this tab, reusing
    // drawSelectionBorder's "1px shadow / 2px highlight" grammar for the
    // thumb rather than inventing new chrome.
    private func drawScrollRail(drawItem: DRAWITEMSTRUCT) {
        let hdc = drawItem.hDC
        var rect = drawItem.rcItem
        // COLOR_SCROLLBAR — the actual system scrollbar-track color,
        // distinct from COLOR_BTNFACE/button-face gray — rather than the
        // page's own background fill, which made the rail barely read as
        // a scrollbar element at all. Flat fill only, no DrawEdge: the
        // user's explicit ask was a plain gray track with no 3D bevel,
        // leaving the raised-bevel treatment to the thumb alone below.
        if let trackBrush = CreateSolidBrush(isDarkMode ? Self.colorref(hex: Self.darkScrollTrackHex) : GetSysColor(COLOR_SCROLLBAR)) {
            FillRect(hdc, &rect, trackBrush)
            DeleteObject(trackBrush)
        }
        var thumbRect = railThumbRect(visibleHeight: rect.bottom - rect.top)
        // darkElevatedHex rather than darkBackgroundHex for the thumb —
        // the plain background color would make it blend straight into
        // the track it's meant to stand out against.
        if let thumbBrush = CreateSolidBrush(isDarkMode ? Self.colorref(hex: Self.darkElevatedHex) : GetSysColor(COLOR_BTNHIGHLIGHT)) {
            FillRect(hdc, &thumbRect, thumbBrush)
            DeleteObject(thumbBrush)
        }
        drawSelectionBorder(hdc: hdc, rect: thumbRect, isSelected: false)
        drawScrollRailGrip(hdc: hdc, thumbRect: thumbRect)
    }

    // The classic Win32-era "something to grab here" decoration — three
    // short horizontal bars centered in the thumb, the same drag-handle
    // texture old toolbar handles/splitter bars used. Drawn in a shade
    // darker than the thumb fill for contrast (COLOR_BTNSHADOW in light
    // mode; darkBackgroundHex reused in dark mode since it's darker than
    // the thumb's own darkElevatedHex fill). Skipped on a thumb too short
    // to have room for it — in practice railThumbRect's own minThumbHeight
    // (24px) never shrinks below this guard, so the grip is effectively
    // unconditional today, but the guard stays in case that constant ever
    // changes.
    private func drawScrollRailGrip(hdc: HDC?, thumbRect: RECT) {
        let thumbHeight = thumbRect.bottom - thumbRect.top
        guard thumbHeight >= 20 else { return }
        let thumbWidth = thumbRect.right - thumbRect.left
        let lineWidth = max(4, thumbWidth / 2)
        let lineLeft = thumbRect.left + (thumbWidth - lineWidth) / 2
        let lineRight = lineLeft + lineWidth
        let centerY = (thumbRect.top + thumbRect.bottom) / 2
        let spacing: Int32 = 3
        guard let gripBrush = CreateSolidBrush(isDarkMode ? Self.colorref(hex: WindowsTheme.darkBackgroundHex) : GetSysColor(COLOR_BTNSHADOW)) else { return }
        for offset: Int32 in [-spacing, 0, spacing] {
            var lineRect = RECT(left: lineLeft, top: centerY + offset, right: lineRight, bottom: centerY + offset + 1)
            FillRect(hdc, &lineRect, gripBrush)
        }
        DeleteObject(gripBrush)
    }

    // Mirrors macOS's GeneralTab: Color scheme (moved in from Appearance,
    // SETTINGS_PLAN.md S2 — it governs Pomoppi's own windows' chrome, never
    // the widget), then widget behavior, the reverseTrayClick swap (added
    // in Phase W2b), then startup checkboxes.
    private func buildGeneralTab(page: HWND, width: Int32) {
        let settings = settingsStore.get()
        let rowWidth = width - 2 * Self.rowMargin
        var y = Self.rowMargin

        addLabel("Color scheme", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20
        y += addColorSchemePicker(in: page, x: Self.rowMargin, y: y)
        addHint(
            "Applies to Pomoppi's own windows. The widget's colors are under Appearance.",
            in: page, x: Self.rowMargin, y: y, width: rowWidth
        )
        y += lastHintHeight + Self.groupGap

        addCheckbox(
            "Keep the widget on top of other windows", in: page, checked: settings.alwaysOnTop,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.alwaysOnTop = checked }
        }
        y += Self.rowHeight

        addCheckbox(
            "Pop to the front when a session ends", in: page, checked: settings.raiseOnEnd,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.raiseOnEnd = checked }
        }
        y += Self.rowHeight + Self.groupGap

        // macOS's copy says "menu bar icon" — adapted to "tray icon" here,
        // the term this codebase's own TrayController already uses, since
        // Windows has no menu bar.
        addCheckbox(
            "Swap the tray icon's left and right clicks", in: page, checked: settings.reverseTrayClick,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [weak self, settingsStore] checked in
            settingsStore.update { $0.reverseTrayClick = checked }
            self?.refreshTrayClickHint(reversed: checked)
        }
        y += Self.rowHeight
        trayClickHintLabel = addHint(Self.trayClickHintText(reversed: settings.reverseTrayClick), in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += lastHintHeight + Self.groupGap

        addCheckbox(
            "Open Pomoppi when I log in", in: page, checked: settings.launchAtLogin,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.launchAtLogin = checked }
        }
        y += Self.rowHeight

        addCheckbox(
            "Start without showing the widget", in: page, checked: settings.startHidden,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.startHidden = checked }
        }
        y += Self.rowHeight
        addHint(
            "Launch at login only registers when Pomoppi is running as an installed app. \u{201C}Start hidden\u{201D} applies the next time Pomoppi launches.",
            in: page, x: Self.rowMargin, y: y, width: rowWidth
        )
        y += lastHintHeight + Self.groupGap

        addLabel("Updates", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20

        addCheckbox(
            "Automatically check for updates", in: page, checked: settings.checkForUpdates,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.checkForUpdates = checked }
        }
        y += Self.rowHeight
        addHint("Checks lucabessiaristei/Pomoppi on GitHub roughly once a day.", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += lastHintHeight + Self.groupGap

        addButton("Reset Pomoppi…", in: page, x: Self.rowMargin, y: y, width: 160, height: 24) { [weak self] in
            self?.confirmResetToDefaults()
        }
        y += 24
        addHint(
            "Erases every setting and your whole session history, and puts Pomoppi back to how it shipped.",
            in: page, x: Self.rowMargin, y: y, width: rowWidth
        )
    }

    // The tray-icon hint's own two variants — kept as a pure function so
    // both buildGeneralTab (initial paint) and refreshTrayClickHint (the
    // checkbox's own live update) build the exact same string off the
    // exact same switch, rather than two copies of the same two literals
    // drifting apart.
    private static func trayClickHintText(reversed: Bool) -> String {
        reversed
            ? "Left-click opens the menu, right-click raises the widget."
            : "Left-click raises the widget, right-click opens the menu."
    }

    // reverseTrayClick's own checkbox calls this directly on toggle
    // (SETTINGS_PLAN.md S4) — already live on macOS for free (Form's
    // footer: reads straight off @Published state); Windows' controls
    // bake their text in at creation, so this is the explicit repaint
    // macOS doesn't need.
    private func refreshTrayClickHint(reversed: Bool) {
        guard let trayClickHintLabel else { return }
        setWindowText(trayClickHintLabel, Self.trayClickHintText(reversed: reversed))
    }

    // MessageBoxW-based confirmation, same shape as confirmEraseSessionLog
    // below — resetting is user-visible and irreversible (every setting AND
    // the whole session log), so this needs its own explicit "are you sure,"
    // not just a plain click. Replaces the old installer-side fresh/update
    // toggle by design (release/update plan, phase R6).
    private func confirmResetToDefaults() {
        let text = Array("Reset Pomoppi to defaults? This erases all settings and session history.".utf16) + [0]
        let title = Array("Reset to Defaults".utf16) + [0]
        let result = text.withUnsafeBufferPointer { textPtr in
            title.withUnsafeBufferPointer { titlePtr in
                MessageBoxW(hwnd, textPtr.baseAddress, titlePtr.baseAddress, UINT(MB_YESNO) | UINT(MB_ICONWARNING))
            }
        }
        guard result == IDYES else { return }
        // sessionLogger.eraseAllSync() then settingsStore.reset() — reset()
        // persists defaults and fires onChange, which main.swift already
        // wires to re-apply the widget, global shortcuts, login item and
        // update checking live (no restart). Every control on this window
        // bakes its value in at creation though, so rebuild() tears the
        // whole tab control/pages/footer down and puts them back at the
        // fresh defaults.
        sessionLogger.eraseAllSync()
        settingsStore.reset()
        rebuild()
    }

    // Reused verbatim by LOCALIZATION_PLAN.md's L4 (a language switch has
    // the same "strings are baked in" problem) — a general rebuild, not a
    // reset-specific patch. Destroying the tab control and every page also
    // destroys their children (every checkbox/stepper/button/card on them),
    // so only the top-level HWNDs need an explicit DestroyWindow; the
    // per-control dispatch arrays just need clearing so applyTheme/handlers
    // don't keep iterating stale, now-invalid handles.
    func rebuild() {
        if recordingActionID != nil {
            stopRecording()
        }
        if let tabControl { DestroyWindow(tabControl) }
        for page in pages { DestroyWindow(page) }
        if let footerVersionLabel { DestroyWindow(footerVersionLabel) }
        if let footerActionButton { DestroyWindow(footerActionButton) }

        tabControl = nil
        pages = []
        checkboxes = []
        steppers = []
        pushButtons = []
        plainPushButtons = []
        shortcutRecorders = []
        pickerCards = []
        themeSwatches = []
        colorPickers = []
        scaleOptions = []
        schemeOptions = []
        chimeOptions = []
        opacityTrackbar = nil
        opacityValueLabel = nil
        sessionHistorySizeLabel = nil
        diarySessionCountLabel = nil
        diaryExportStatusLabel = nil
        diaryFolderLabel = nil
        diarySyncButton = nil
        diarySyncStatusLabel = nil
        hintLabels = []
        trayClickHintLabel = nil
        askForTaskHintLabel = nil
        lastHintHeight = 18
        footerVersionLabel = nil
        footerActionButton = nil
        appearancePage = nil
        appearanceContentHeight = 0
        appearanceScrollY = 0
        appearanceControlPositions = []
        appearanceScrollRail = nil
        keysPage = nil

        // colorScheme may itself have just reset to "auto" — re-derive
        // before rebuilding rather than reusing whatever isDarkMode already
        // held, same order the constructor uses.
        isDarkMode = resolveDarkMode()
        setUpTabsAndPages()
        createFooter()
        applyTheme()
    }

    // Mirrors macOS's SoundTab: a chime toggle, a Chime picker (selecting
    // an option previews it immediately, no separate Play/Test button),
    // and a ring-length stepper — ringSeconds governs the visual ring
    // only, never audio (SPEC.md §4), so it stays enabled regardless of
    // the checkbox, matching macOS's own ungating.
    private func buildSoundTab(page: HWND, width: Int32) {
        let settings = settingsStore.get()
        let rowWidth = width - 2 * Self.rowMargin
        let checkboxY = Self.rowMargin
        let chimeY = checkboxY + Self.rowHeight
        let stepperY = chimeY + Self.rowHeight

        addStepper(
            "Keep ringing for (seconds)", in: page, value: Int32(settings.ringSeconds),
            min: 0, max: 60, step: 5, x: Self.rowMargin, y: stepperY, labelWidth: 220
        ) { [settingsStore] newValue in
            settingsStore.update { $0.ringSeconds = Double(newValue) }
        }

        addCheckbox(
            "Play a chime when a session ends", in: page, checked: settings.soundEnabled,
            x: Self.rowMargin, y: checkboxY, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.soundEnabled = checked }
        }

        let chimeLabelWidth: Int32 = 100
        let chimePickerWidth: Int32 = 250
        addLabel("Chime", in: page, x: Self.rowMargin, y: chimeY + 3, width: chimeLabelWidth)
        let chimePickerX = Self.rowMargin + chimeLabelWidth + 8
        addChimePicker(in: page, x: chimePickerX, y: chimeY, width: chimePickerWidth)

        addHint("Selecting a chime plays it.", in: page, x: Self.rowMargin, y: stepperY + Self.rowHeight, width: rowWidth)
    }

    // Mirrors macOS's KeysTab/ShortcutRow (SettingsView.swift): one row per
    // Shortcuts.action with a button showing its current binding (click to
    // record a new one), a Restore Default Shortcuts button, then a static,
    // read-only list of the widget's own fixed keys. A single line per
    // shortcut row (label only, no hint underneath) — not a pixel match for
    // macOS's two-line LabeledContent rows, just enough to fit comfortably
    // alongside the informational list below.
    private func buildKeysTab(page: HWND, width: Int32) {
        keysPage = page
        let bindings = settingsStore.get().shortcuts
        let rowWidth = width - 2 * Self.rowMargin
        let labelWidth: Int32 = 300
        let buttonWidth: Int32 = 140
        var y = Self.rowMargin

        addLabel("Global shortcuts", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20

        for action in Shortcuts.actions {
            addLabel(action.label, in: page, x: Self.rowMargin, y: y + 3, width: labelWidth)
            let button = addButton(
                Shortcuts.displayWindows(bindings[action.id] ?? ""),
                in: page, x: Self.rowMargin + labelWidth + 8, y: y, width: buttonWidth, height: 22
            ) { [weak self] in
                self?.toggleShortcutRecording(actionID: action.id)
            }
            shortcutRecorders.append(ShortcutRecorderControl(buttonHwnd: button, actionID: action.id))
            y += Self.rowHeight
        }
        addHint(
            "These fire even while Pomoppi isn’t the frontmost app. A shortcut needs a modifier; two actions can’t share the same combo.",
            in: page, x: Self.rowMargin, y: y, width: rowWidth
        )
        y += lastHintHeight + Self.groupGap

        // Wider than the shortcut recorder buttons above: "Restore Default
        // Shortcuts" doesn't fit their fixed 140px, so this one sizes to
        // its own text instead (same measureTextWidth addPickerGrid's label
        // column already uses, not a second guessed constant).
        let resetButtonWidth = measureTextWidth("Restore Default Shortcuts") + 24
        addButton("Restore Default Shortcuts", in: page, x: Self.rowMargin, y: y, width: resetButtonWidth, height: 24) { [weak self] in
            self?.resetShortcutsToDefaults()
        }
        y += 24 + Self.groupGap

        addLabel("While the widget is focused", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20

        for binding in Self.widgetKeyBindings {
            addLabel(binding.keys, in: page, x: Self.rowMargin, y: y, width: 140)
            addLabel(binding.action, in: page, x: Self.rowMargin + 148, y: y, width: rowWidth - 148)
            y += 20
        }
        addHint("Fixed keys. They only fire while the widget window itself has focus.", in: page, x: Self.rowMargin, y: y, width: rowWidth)
    }

    private struct WidgetKeyBinding {
        let keys: String
        let action: String
    }

    // Mirrors macOS's widgetKeyBindings (SettingsView.swift), minus the T
    // (name-what-you're-working-on) and P (SVG snapshot) rows — neither
    // feature exists on Windows yet, so listing their keys here would be
    // informational noise about nothing actually bound.
    private static let widgetKeyBindings: [WidgetKeyBinding] = [
        WidgetKeyBinding(keys: "Space / Return", action: "Start / pause"),
        WidgetKeyBinding(keys: "S", action: "Skip phase"),
        WidgetKeyBinding(keys: "R", action: "Reset phase"),
        WidgetKeyBinding(keys: "O", action: "Keep on top"),
        WidgetKeyBinding(keys: ",", action: "Open settings"),
        WidgetKeyBinding(keys: "Esc", action: "Dismiss the ring, or hide the widget"),
        WidgetKeyBinding(keys: "Up / Down", action: "Adjust focus length, while idle"),
    ]

    // -- Diary tab (logging + export + sync) -----------------------------------

    // Mirrors macOS's merged DiaryTab (SettingsView.swift, SPEC.md §8/§8b),
    // three sections top to bottom: Session history (moved verbatim from
    // the old Log tab — enable toggle, live history-size readout, "Erase
    // History" with a real confirmation), Export (now a `.zip` of
    // per-day files, DiaryExporter.exportZip), Sync to folder (idempotent,
    // no cursor, DiaryExporter.syncToFolder). All three read
    // `sessionLogger.allSessionsSync()` directly; none of this ever
    // writes to sessions.json itself.
    private func buildDiaryTab(page: HWND, width: Int32) {
        let settings = settingsStore.get()
        let rowWidth = width - 2 * Self.rowMargin
        var y = Self.rowMargin

        addLabel("Session history", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20

        addCheckbox(
            "Record every session", in: page, checked: settings.loggingEnabled,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [weak self, settingsStore] checked in
            settingsStore.update { $0.loggingEnabled = checked }
            self?.refreshAskForTaskHint(loggingEnabled: checked)
        }
        y += Self.rowHeight

        sessionHistorySizeLabel = addLabel(Self.formatHistorySize(sessionLogger.fileSizeBytes()), in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += Self.rowHeight

        addButton("Erase History…", in: page, x: Self.rowMargin, y: y, width: 180, height: 24) { [weak self] in
            self?.confirmEraseSessionLog()
        }
        y += 24
        addHint(
            "Pomoppi's own record of every session, kept on this computer. Erasing it can't be undone.",
            in: page, x: Self.rowMargin, y: y, width: rowWidth
        )
        y += lastHintHeight + Self.groupGap

        addLabel("Export", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20

        diarySessionCountLabel = addLabel(
            Self.sessionCountText(sessionLogger.allSessionsSync().count),
            in: page, x: Self.rowMargin, y: y, width: rowWidth
        )
        y += Self.rowHeight

        addButton("Export Diary…", in: page, x: Self.rowMargin, y: y, width: 140, height: 24) { [weak self] in
            self?.exportDiary()
        }
        y += 24 + 4

        diaryExportStatusLabel = addLabel("", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += Self.rowHeight + Self.groupGap

        addLabel("Sync to folder", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20

        diaryFolderLabel = addLabel(
            Self.folderDisplayText(settings.diaryFolderPath),
            in: page, x: Self.rowMargin, y: y, width: rowWidth
        )
        y += Self.rowHeight

        addButton("Choose…", in: page, x: Self.rowMargin, y: y, width: 100, height: 24) { [weak self] in
            self?.chooseDiaryFolder()
        }
        let syncButton = addButton("Sync Now", in: page, x: Self.rowMargin + 108, y: y, width: 100, height: 24) { [weak self] in
            self?.syncDiaryNow()
        }
        diarySyncButton = syncButton
        // Matches macOS's `.disabled(viewModel.settings.diaryFolderPath.isEmpty)`.
        EnableWindow(syncButton, !settings.diaryFolderPath.isEmpty)
        y += 24 + 4

        diarySyncStatusLabel = addLabel("", in: page, x: Self.rowMargin, y: y, width: rowWidth)
    }

    // MessageBoxW blocks the message loop until dismissed — same "modal,
    // no async ceremony needed" shape as ChooseColorW in the Appearance
    // tab. IDYES is the only outcome that erases anything; Cancel/No/the
    // window's own close box are all treated as "do nothing."
    private func confirmEraseSessionLog() {
        let text = Array("Erase all session history? This can't be undone.".utf16) + [0]
        let title = Array("Erase History".utf16) + [0]
        let result = text.withUnsafeBufferPointer { textPtr in
            title.withUnsafeBufferPointer { titlePtr in
                MessageBoxW(hwnd, textPtr.baseAddress, titlePtr.baseAddress, UINT(MB_YESNO) | UINT(MB_ICONWARNING))
            }
        }
        guard result == IDYES else { return }
        sessionLogger.eraseAllSync()
        if let label = sessionHistorySizeLabel {
            setWindowText(label, Self.formatHistorySize(sessionLogger.fileSizeBytes()))
        }
        if let diarySessionCountLabel {
            setWindowText(diarySessionCountLabel, Self.sessionCountText(sessionLogger.allSessionsSync().count))
        }
    }

    private static func formatHistorySize(_ bytes: Int64) -> String {
        // A handful of sessions is only a few hundred bytes — rounding
        // straight to KB read as "0 KB" for anything real yet non-empty,
        // which looks like the erase didn't work. Bytes below 1 KB, then
        // KB, then MB.
        if bytes < 1024 {
            return "History size: \(bytes) bytes"
        }
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return "History size: \(Int(kb.rounded())) KB"
        }
        return "History size: \(String(format: "%.1f", kb / 1024)) MB"
    }

    private static func sessionCountText(_ count: Int) -> String {
        "Sessions recorded: \(count)"
    }

    private static func folderDisplayText(_ path: String) -> String {
        path.isEmpty ? "Diary folder: Not set" : "Diary folder: \(path)"
    }

    private func exportDiary() {
        guard let path = promptDiaryExportPath() else { return }
        let url = URL(fileURLWithPath: path)
        let zipData = DiaryExporter.exportZip(sessions: sessionLogger.allSessionsSync())
        do {
            try zipData.write(to: url, options: .atomic)
            if let diaryExportStatusLabel {
                setWindowText(diaryExportStatusLabel, "Exported to \(url.lastPathComponent).")
            }
        } catch {
            if let diaryExportStatusLabel {
                setWindowText(diaryExportStatusLabel, "Export failed.")
            }
        }
    }

    private func chooseDiaryFolder() {
        guard let path = promptDiaryFolder() else { return }
        settingsStore.update { $0.diaryFolderPath = path }
        if let diaryFolderLabel {
            setWindowText(diaryFolderLabel, Self.folderDisplayText(path))
        }
        if let diarySyncButton {
            EnableWindow(diarySyncButton, true)
        }
        // Matches macOS's `syncStatus = nil` on a fresh folder choice — the
        // previous folder's last sync outcome no longer means anything.
        if let diarySyncStatusLabel {
            setWindowText(diarySyncStatusLabel, "")
        }
    }

    private func syncDiaryNow() {
        let settings = settingsStore.get()
        let allSessions = sessionLogger.allSessionsSync()
        let folderURL = URL(fileURLWithPath: settings.diaryFolderPath)
        do {
            let written = try DiaryExporter.syncToFolder(folderURL, sessions: allSessions)
            if let diarySyncStatusLabel {
                setWindowText(diarySyncStatusLabel, written == 0 ? "Up to date." : "Added \(written) session\(written == 1 ? "" : "s").")
            }
        } catch {
            if let diarySyncStatusLabel {
                setWindowText(diarySyncStatusLabel, "Sync failed.")
            }
        }
    }

    // GetSaveFileNameW is comdlg32's plain save-dialog counterpart to
    // ChooseColorW above — same "build a struct, call the Win32 API, check
    // the result" shape, also a real modal that blocks this WndProc until
    // OK/Cancel. lpstrFile must point at a real writable buffer that's
    // pre-seeded with the default filename (Explorer overwrites it in place
    // with whatever the user actually chose, extension appended per
    // lpstrDefExt if they typed none) — same "caller-owned buffer" shape as
    // ChooseColorW's lpCustColors, just stack-local here since nothing
    // needs it to outlive this one call.
    private func promptDiaryExportPath() -> String? {
        var pathBuffer = [UInt16](repeating: 0, count: 260)
        for (index, unit) in Array("Pomoppi Diary.zip".utf16).enumerated() {
            pathBuffer[index] = unit
        }
        // Double-NUL-terminated filter pairs, the OPENFILENAMEW convention:
        // display string, then pattern, repeated, ending in an extra NUL.
        let filter = Array("Zip archive (*.zip)\0*.zip\0\0".utf16)
        let defExt = Array("zip".utf16) + [0]

        var dialog = OPENFILENAMEW()
        dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        dialog.hwndOwner = hwnd
        dialog.Flags = DWORD(OFN_OVERWRITEPROMPT) | DWORD(OFN_HIDEREADONLY)

        let picked = filter.withUnsafeBufferPointer { filterPtr in
            defExt.withUnsafeBufferPointer { defExtPtr in
                pathBuffer.withUnsafeMutableBufferPointer { bufferPtr -> Bool in
                    dialog.lpstrFilter = filterPtr.baseAddress
                    dialog.lpstrDefExt = defExtPtr.baseAddress
                    dialog.lpstrFile = bufferPtr.baseAddress
                    dialog.nMaxFile = DWORD(bufferPtr.count)
                    return GetSaveFileNameW(&dialog)
                }
            }
        }
        guard picked else { return nil }
        return pathBuffer.withUnsafeBufferPointer { String(decodingCString: $0.baseAddress!, as: UTF16.self) }
    }

    // SHBrowseForFolderW (shell32) is the folder-only counterpart to
    // GetSaveFileNameW above — no file dialog here restricts to
    // directories, hence the older, separate API. It hands back a PIDL (an
    // opaque shell item-identifier list), not a path directly;
    // SHGetPathFromIDListW resolves that to a real path, and the PIDL
    // itself must be freed via CoTaskMemFree once done — same
    // caller-frees-it shell convention as AppStorage.storageDir()'s own
    // SHGetKnownFolderPath.
    private func promptDiaryFolder() -> String? {
        var displayName = [UInt16](repeating: 0, count: Int(MAX_PATH))
        let title = Array("Choose a folder for your diary".utf16) + [0]

        var info = BROWSEINFOW()
        info.hwndOwner = hwnd
        info.ulFlags = UINT(BIF_RETURNONLYFSDIRS)

        let pidl: UnsafeMutablePointer<ITEMIDLIST>? = displayName.withUnsafeMutableBufferPointer { namePtr in
            title.withUnsafeBufferPointer { titlePtr in
                info.pszDisplayName = namePtr.baseAddress
                info.lpszTitle = titlePtr.baseAddress
                return SHBrowseForFolderW(&info)
            }
        }
        guard let pidl else { return nil }
        defer { CoTaskMemFree(pidl) }

        var pathBuffer = [UInt16](repeating: 0, count: Int(MAX_PATH))
        let resolved = pathBuffer.withUnsafeMutableBufferPointer { SHGetPathFromIDListW(pidl, $0.baseAddress) }
        guard resolved else { return nil }
        return pathBuffer.withUnsafeBufferPointer { String(decodingCString: $0.baseAddress!, as: UTF16.self) }
    }

    // -- Keys tab: shortcut recording ------------------------------------------

    private func toggleShortcutRecording(actionID: String) {
        if recordingActionID == actionID {
            stopRecording()
            return
        }
        // Only one row records at a time — cancel whichever other row was
        // listening (no change committed for it) before starting this one.
        if recordingActionID != nil {
            stopRecording()
        }
        startRecording(actionID: actionID)
    }

    // Unregisters every live global hotkey up front: leaving the old combo
    // registered while capturing its replacement could either fire the
    // stale binding mid-capture, or block re-registering a combo the OS
    // already considers claimed (e.g. rebinding an action to its own
    // current key). handleShortcutRecorderKeyDown below watches for the
    // capture keystroke; stopRecording always re-applies the table
    // afterward, whether or not anything actually changed.
    private func startRecording(actionID: String) {
        recordingActionID = actionID
        globalShortcutManager.unregisterAll()
        if let recorder = shortcutRecorders.first(where: { $0.actionID == actionID }) {
            setWindowText(recorder.buttonHwnd, "Press a key…")
        }
        // Moves focus off the button that was just clicked (clicking a
        // BUTTON control focuses it as a side effect) onto the Keys page
        // itself, so the capture keystroke's WM_(SYS)KEYDOWN has somewhere
        // of ours to land — see pomoppiSettingsPageWndProc's forwarding and
        // handleMessage's WM_KEYDOWN/WM_SYSKEYDOWN case.
        if let keysPage {
            SetFocus(keysPage)
        }
    }

    // Ends whatever row is recording (a no-op on recordingActionID itself
    // if none was) and reapplies the shortcut table to the OS
    // unconditionally, since startRecording always unregistered everything
    // up front — reused by both an actual capture and Restore Default
    // Shortcuts.
    private func stopRecording() {
        let previousActionID = recordingActionID
        recordingActionID = nil
        refreshShortcutButtons()
        reregisterShortcuts()
        // Moves focus off the Keys page and back onto a real control now
        // that no keydown needs to land there — otherwise the page would
        // silently keep swallowing every future WM_KEYDOWN it's sent (see
        // handleMessage's WM_KEYDOWN/WM_SYSKEYDOWN case), for as long as it
        // keeps the focus startRecording gave it, even long after recording
        // itself has stopped.
        if let previousActionID, let recorder = shortcutRecorders.first(where: { $0.actionID == previousActionID }) {
            SetFocus(recorder.buttonHwnd)
        }
    }

    private func refreshShortcutButtons() {
        let bindings = settingsStore.get().shortcuts
        for recorder in shortcutRecorders {
            setWindowText(recorder.buttonHwnd, Shortcuts.displayWindows(bindings[recorder.actionID] ?? ""))
        }
    }

    private func resetShortcutsToDefaults() {
        settingsStore.update { $0.shortcuts = Shortcuts.defaults }
        stopRecording()
    }

    private func isKeyDown(_ vk: Int32) -> Bool {
        (GetKeyState(vk) & Int16(bitPattern: 0x8000)) != 0
    }

    private func liveModifiers() -> [String] {
        var mods: [String] = []
        if isKeyDown(VK_CONTROL) { mods.append("Control") }
        if isKeyDown(VK_MENU) { mods.append("Alt") }
        if isKeyDown(VK_SHIFT) { mods.append("Shift") }
        return mods
    }

    // Reverse of GlobalShortcutManager.keyCodes (private to that file, so
    // rebuilt here rather than exposed) — virtual-key code -> the key name
    // Shortcuts.normalize expects, for turning a captured keydown back into
    // a raw accelerator string.
    private static let virtualKeyNames: [Int32: String] = {
        var out: [Int32: String] = [:]
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            out[Int32(c.asciiValue!)] = String(c)
        }
        out[VK_OEM_3] = "`"
        out[VK_OEM_MINUS] = "-"
        out[VK_OEM_PLUS] = "="
        out[VK_OEM_4] = "["
        out[VK_OEM_6] = "]"
        out[VK_OEM_5] = "\\"
        out[VK_OEM_1] = ";"
        out[VK_OEM_7] = "'"
        out[VK_OEM_COMMA] = ","
        out[VK_OEM_PERIOD] = "."
        out[VK_OEM_2] = "/"
        out[VK_SPACE] = "Space"
        out[VK_RETURN] = "Return"
        out[VK_TAB] = "Tab"
        out[VK_BACK] = "Backspace"
        out[VK_DELETE] = "Delete"
        out[VK_INSERT] = "Insert"
        out[VK_ESCAPE] = "Escape"
        out[VK_UP] = "Up"
        out[VK_DOWN] = "Down"
        out[VK_LEFT] = "Left"
        out[VK_RIGHT] = "Right"
        out[VK_HOME] = "Home"
        out[VK_END] = "End"
        out[VK_PRIOR] = "PageUp"
        out[VK_NEXT] = "PageDown"
        out[VK_SNAPSHOT] = "PrintScreen"
        let fKeys: [Int32] = [
            VK_F1, VK_F2, VK_F3, VK_F4, VK_F5, VK_F6, VK_F7, VK_F8, VK_F9, VK_F10,
            VK_F11, VK_F12, VK_F13, VK_F14, VK_F15, VK_F16, VK_F17, VK_F18, VK_F19, VK_F20,
            VK_F21, VK_F22, VK_F23, VK_F24,
        ]
        for (i, vk) in fKeys.enumerated() { out[vk] = "F\(i + 1)" }
        return out
    }()

    // The next WM_KEYDOWN/WM_SYSKEYDOWN the Keys page receives while a row
    // is recording (forwarded here via pomoppiSettingsPageWndProc + this
    // window's own handleMessage — see both for why WM_SYSKEYDOWN has to be
    // included). Bare Escape cancels without changing the binding, same as
    // macOS's ShortcutRow.startRecording; any other key stops recording
    // whether or not it produced a usable combo (e.g. no modifier held),
    // mirroring that same method's unconditional `defer { stopRecording() }`.
    private func handleShortcutRecorderKeyDown(wParam: WPARAM) {
        guard let actionID = recordingActionID else { return }
        let vk = Int32(truncatingIfNeeded: wParam)

        // A modifier key press fires its own WM_(SYS)KEYDOWN on Windows
        // (unlike AppKit's separate flagsChanged) — wait for the actual key
        // instead of treating a bare modifier as the captured combo.
        if vk == VK_CONTROL || vk == VK_MENU || vk == VK_SHIFT || vk == VK_LWIN || vk == VK_RWIN {
            return
        }

        let mods = liveModifiers()
        if vk == VK_ESCAPE, mods.isEmpty {
            stopRecording()
            return
        }
        if !mods.isEmpty, let keyName = Self.virtualKeyNames[vk] {
            settingsStore.update { $0.shortcuts[actionID] = (mods + [keyName]).joined(separator: "+") }
        }
        stopRecording()
    }

    // -- raw control helpers ---------------------------------------------------

    // Every raw control created below needs this or it renders in the
    // ancient stock system font — SysTabControl32 (setUpTabsAndPages above)
    // is the only control in this window that manages its own font.
    private func applyDefaultFont(_ hwnd: HWND?) {
        guard let hwnd, let font = GetStockObject(DEFAULT_GUI_FONT) else { return }
        SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), LPARAM(1))
    }

    // `trackForScroll` opts this specific call into the Appearance page's
    // own manual-scroll bookkeeping (see AppearanceControlPosition) — every
    // other tab leaves it at the default `false` since only Appearance
    // ever moves its children after creation. SS_NOPREFIX is always on:
    // STATIC text otherwise treats a bare '&' as an Alt-mnemonic marker —
    // consumed rather than drawn, with an underline moved onto whatever
    // character follows it — confirmed live via "Size & transparency"
    // rendering as "Size_transparency". None of this app's labels are
    // meant to carry a keyboard mnemonic, so this is unconditional rather
    // than something each call site has to remember to ask for.
    @discardableResult
    private func addLabel(_ text: String, in page: HWND, x: Int32, y: Int32, width: Int32, height: Int32 = 18, centered: Bool = false, trackForScroll: Bool = false) -> HWND {
        let wide = Array(text.utf16) + [0]
        let alignmentStyle: Int32 = (centered ? SS_CENTER : 0) | SS_NOPREFIX
        guard let label = (Self.staticClassName.withUnsafeBufferPointer { classNamePtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, textPtr.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE) | DWORD(bitPattern: alignmentStyle),
                    x, y, width, height,
                    page, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (label) failed with error \(GetLastError())")
        }
        applyDefaultFont(label)
        if trackForScroll {
            trackAppearanceControl(label, x: x, y: y)
        }
        return label
    }

    // Windows' counterpart to macOS Form's `footer:` (SPEC.md §7's
    // hint-footer rule: every hint is a footer under its control, never a
    // disclosure, never a tooltip) — SETTINGS_PLAN.md's S4. Built on
    // addLabel above (SS_NOPREFIX and optional scroll-tracking both come
    // free), swaps in the smaller hintFont, and registers into hintLabels
    // so handleCtlColor knows to paint this one dimmer than an ordinary
    // label, in both themes. Height is measured, not guessed: some hints
    // in the target tab map (SETTINGS_PLAN.md) wrap to two lines at this
    // window's row width and some don't, and this window's non-Appearance
    // pages have no scroll to fall back on if a fixed guess undershoots —
    // confirmed live (the General tab's Reset hint clipped clean off the
    // bottom of the page under a first pass that used one flat height for
    // every hint regardless of its own text). `lastHintHeight` is what the
    // height came out to, for the call site's own y += bookkeeping right
    // after — the same "cache it on self, read it back" shape
    // opacityValueLabel/sessionHistorySizeLabel already use for a value a later
    // step needs, rather than turning every add* call site here into a
    // tuple destructure.
    @discardableResult
    private func addHint(_ text: String, in page: HWND, x: Int32, y: Int32, width: Int32, trackForScroll: Bool = false) -> HWND {
        let height = Self.measuredHintHeight(text, width: width)
        lastHintHeight = height
        let label = addLabel(text, in: page, x: x, y: y, width: width, height: height, trackForScroll: trackForScroll)
        if let hintFont = Self.hintFont {
            SendMessageW(label, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: hintFont)), LPARAM(1))
        }
        hintLabels.insert(label)
        return label
    }

    // hintFont's own single-line text extent tells us both how many lines
    // a STATIC's automatic word-wrap needs at `width` (ceil of total width
    // over available width — an underestimate in principle, since
    // wrapping only breaks at word boundaries and can't pack a line as
    // tightly as a raw width ratio assumes, so the divisor below is
    // `width` shrunk by a fixed margin rather than `width` itself, a
    // deliberate safety margin against that) and the line's own height
    // (size.cy from the same call, rather than a second GetTextMetrics
    // round trip). Capped at 3 lines — nothing in the target tab map
    // needs a fourth, and an unbounded guess is a worse failure mode
    // (pushing everything below it off the page) than a bounded one.
    private static func measuredHintHeight(_ text: String, width: Int32) -> Int32 {
        guard let hdc = GetDC(nil) else { return 18 }
        defer { ReleaseDC(nil, hdc) }
        let previousFont = hintFont.map { SelectObject(hdc, $0) }
        defer { if let previousFont { SelectObject(hdc, previousFont) } }
        var size = SIZE()
        let wide = Array(text.utf16)
        wide.withUnsafeBufferPointer { ptr in
            _ = GetTextExtentPoint32W(hdc, ptr.baseAddress, Int32(ptr.count), &size)
        }
        guard size.cy > 0 else { return 18 }
        let wrapWidth = max(width - 24, 1)
        let lineCount = min(3, max(1, Int32((Double(size.cx) / Double(wrapWidth)).rounded(.up))))
        return lineCount * size.cy + 4
    }

    // One point smaller than DEFAULT_GUI_FONT, same face/weight/charset —
    // GetObjectW reads the stock font's own LOGFONTW back out,
    // CreateFontIndirectW rebuilds it with lfHeight nudged toward zero (a
    // smaller magnitude — GDI's own convention is a negative lfHeight,
    // character height in device units, not a cell height) rather than
    // guessing a fresh point size from scratch. Built once and kept for
    // the process's lifetime, same "paint-local vs. process-lifetime"
    // split WindowsTheme.darkBackgroundBrush already uses for a
    // CTLCOLOR-adjacent GDI object — a font handed to WM_SETFONT has to
    // stay valid for as long as the control keeps using it, not just for
    // one call.
    private static let hintFont: HFONT? = {
        guard let stockFont = GetStockObject(DEFAULT_GUI_FONT), let hdc = GetDC(nil) else { return nil }
        defer { ReleaseDC(nil, hdc) }
        var logFont = LOGFONTW()
        guard GetObjectW(stockFont, Int32(MemoryLayout<LOGFONTW>.size), &logFont) != 0 else { return nil }
        let onePointInPixels = max(1, Int32((Double(GetDeviceCaps(hdc, LOGPIXELSY)) / 72.0).rounded()))
        logFont.lfHeight += logFont.lfHeight < 0 ? onePointInPixels : -onePointInPixels
        return CreateFontIndirectW(&logFont)
    }()

    // BS_AUTOCHECKBOX toggles its own visual check state on click and fires
    // BN_CLICKED via WM_COMMAND (handleCommand below) — the button's own
    // text is the control's label, no separate STATIC needed.
    private func addCheckbox(
        _ text: String, in page: HWND, checked: Bool,
        x: Int32, y: Int32, width: Int32, height: Int32 = 22,
        onToggle: @escaping (Bool) -> Void
    ) {
        let wide = Array(text.utf16) + [0]
        guard let checkbox = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, textPtr.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX),
                    x, y, width, height,
                    page, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (checkbox) failed with error \(GetLastError())")
        }
        applyDefaultFont(checkbox)
        SendMessageW(checkbox, UINT(BM_SETCHECK), WPARAM(checked ? BST_CHECKED : BST_UNCHECKED), 0)
        checkboxes.append(CheckboxControl(hwnd: checkbox, onToggle: onToggle))
    }

    // A plain BS_PUSHBUTTON (unlike addCheckbox's BS_AUTOCHECKBOX, no
    // persistent check state of its own) — used by the Keys tab for both
    // each row's own recorder button and Restore Default Shortcuts.
    @discardableResult
    private func addButton(
        _ text: String, in page: HWND, x: Int32, y: Int32, width: Int32, height: Int32 = 24,
        onClick: @escaping () -> Void
    ) -> HWND {
        let wide = Array(text.utf16) + [0]
        guard let button = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, textPtr.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON),
                    x, y, width, height,
                    page, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (button) failed with error \(GetLastError())")
        }
        applyDefaultFont(button)
        pushButtons.append(PushButtonControl(hwnd: button, onClick: onClick))
        plainPushButtons.append(button)
        return button
    }

    // Only setWindowTextW-based redraw a shortcut recorder button ever
    // needs (its own text is the whole displayed state, no separate check
    // mark or edit buddy) — SetWindowTextW repaints on its own.
    private func setWindowText(_ hwnd: HWND, _ text: String) {
        let wide = Array(text.utf16) + [0]
        _ = wide.withUnsafeBufferPointer { SetWindowTextW(hwnd, $0.baseAddress) }
    }

    // The standard Win32 numeric-stepper idiom: an EDIT paired with an
    // msctls_updown32 "buddy" via UDM_SETBUDDY. UDS_SETBUDDYINT keeps the
    // edit's displayed text in sync whenever the up-down's position changes
    // (arrows, or our own UDM_SETPOS32 calls) — but that sync is one-way,
    // reading the edit back after direct typing is on us (see
    // commitTypedStepperValue below).
    @discardableResult
    private func addStepper(
        _ label: String, in page: HWND, value: Int32, min: Int32, max: Int32, step: Int32,
        x: Int32, y: Int32, labelWidth: Int32, editWidth: Int32 = 55, height: Int32 = 22,
        onChange: @escaping (Int32) -> Void
    ) -> (edit: HWND, upDown: HWND) {
        addLabel(label, in: page, x: x, y: y + 3, width: labelWidth)

        let editX = x + labelWidth + 8
        guard let editHwnd = (Self.editClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                DWORD(WS_EX_CLIENTEDGE), classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | ES_NUMBER),
                editX, y, editWidth, height,
                page, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (stepper edit) failed with error \(GetLastError())")
        }
        applyDefaultFont(editHwnd)

        // Zero size/position: UDS_ALIGNRIGHT docks it against the buddy's
        // own right edge once UDM_SETBUDDY below runs.
        guard let upDownHwnd = (Self.upDownClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | UDS_SETBUDDYINT | UDS_ALIGNRIGHT | UDS_ARROWKEYS | UDS_NOTHOUSANDS),
                0, 0, 0, 0,
                page, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (stepper updown) failed with error \(GetLastError())")
        }
        applyDefaultFont(upDownHwnd)

        SendMessageW(upDownHwnd, UINT(UDM_SETBUDDY), WPARAM(UInt(bitPattern: editHwnd)), 0)
        SendMessageW(upDownHwnd, UINT(UDM_SETRANGE32), WPARAM(Int(min)), LPARAM(Int(max)))
        SendMessageW(upDownHwnd, UINT(UDM_SETPOS32), 0, LPARAM(Int(value)))

        steppers.append(StepperControl(editHwnd: editHwnd, upDownHwnd: upDownHwnd, min: min, max: max, step: step, onChange: onChange))
        // pomoppiStepperSubclassProc's own dark-mode-only gate decides
        // when either of these actually intercepts anything — installed
        // unconditionally here, same "every stepper gets one, light mode
        // just never triggers it" shape as the tab control's own subclass
        // in setUpTabsAndPages. Appended to steppers just above first,
        // since isStepperUpDown/isStepperEdit's membership checks are
        // what the gate reads.
        _ = SetWindowSubclass(editHwnd, pomoppiStepperSubclassProc, 1, 0)
        _ = SetWindowSubclass(upDownHwnd, pomoppiStepperSubclassProc, 1, 0)
        return (editHwnd, upDownHwnd)
    }

    private func selectTab(_ index: Int) {
        // Mirrors macOS's ShortcutRow.onDisappear(perform: stopRecording):
        // switching away from the Keys tab mid-recording must not leave
        // every global hotkey unregistered (startRecording's own
        // unregisterAll) with no way back short of returning to Keys and
        // finishing the capture.
        if recordingActionID != nil {
            stopRecording()
        }
        for (i, page) in pages.enumerated() {
            ShowWindow(page, i == index ? SW_SHOW : SW_HIDE)
        }
        Self.saveRememberedTabIndex(index)
    }

    // -- tab memory --------------------------------------------------------

    // Windows' counterpart to macOS's `@AppStorage("pomoppi.settingsTab")` —
    // the settings window here is destroyed on close (Self.shared = nil on
    // WM_DESTROY), so unlike macOS's single reused `Settings` scene, there's
    // no in-memory home for the selected tab to survive a reopen in. Its own
    // subkey rather than LoginItem.swift's `...\CurrentVersion\Run`: that
    // one's shape is fixed by what Windows itself reads to register a login
    // item, but this value means nothing to Windows, so it gets a key of
    // Pomoppi's own. Deliberately not a PomoppiSettings field — SPEC.md §7
    // says the selected tab is a per-viewer convenience, never part of the
    // schema.
    private static let tabMemorySubKey = "Software\\Pomoppi"
    private static let tabMemoryValueName = "SettingsTab"

    // Same RegGetValueW one-shot read TrayController.systemPrefersLightTaskbar()
    // uses for a DWORD value — falls back to General (0) if the key/value is
    // missing (first run) or holds something outside Tab's range (an older
    // build's tab count, or a corrupt value), same "clamp rather than fail"
    // stance PomoppiSettings.validate uses for its own out-of-range fields.
    private static func loadRememberedTabIndex() -> Int {
        var value: DWORD = 0
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = tabMemorySubKey.withCString(encodedAs: UTF16.self) { subKeyPtr in
            tabMemoryValueName.withCString(encodedAs: UTF16.self) { valueNamePtr in
                RegGetValueW(HKEY_CURRENT_USER, subKeyPtr, valueNamePtr, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
            }
        }
        guard status == ERROR_SUCCESS, Tab(rawValue: Int(value)) != nil else { return 0 }
        return Int(value)
    }

    // Same "open (creating if needed), set, close" dance as
    // LoginItem.apply(enabled:)'s RegOpenKeyExW call, but via
    // RegCreateKeyExW: unlike the Run key, which Windows itself guarantees
    // exists, `Software\Pomoppi` is this app's own key and may not exist yet
    // on a fresh install.
    private static func saveRememberedTabIndex(_ index: Int) {
        var key: HKEY?
        let status = tabMemorySubKey.withCString(encodedAs: UTF16.self) { subKeyPtr in
            RegCreateKeyExW(HKEY_CURRENT_USER, subKeyPtr, 0, nil, 0, DWORD(KEY_SET_VALUE), nil, &key, nil)
        }
        guard status == ERROR_SUCCESS, let key else { return }
        defer { RegCloseKey(key) }
        var value = DWORD(index)
        _ = tabMemoryValueName.withCString(encodedAs: UTF16.self) { valueNamePtr in
            withUnsafeBytes(of: &value) { bytes in
                RegSetValueExW(key, valueNamePtr, 0, DWORD(REG_DWORD), bytes.bindMemory(to: BYTE.self).baseAddress, DWORD(MemoryLayout<DWORD>.size))
            }
        }
    }

    // -- dark mode --------------------------------------------------------

    // Two colors cover everything below. COLOR_HIGHLIGHT (used throughout
    // this tab's selection accents) is left alone everywhere it's already
    // in use — confirmed live (pixel-identical screenshot comparison) that
    // it does NOT itself change value between the OS's light/dark setting,
    // but it's the user's own accent color, a fixed, strongly saturated
    // blue with enough contrast to read fine as a selection cue against
    // either a light or a dark page background regardless. Every other
    // classic 3D system color this file draws with (COLOR_BTNFACE,
    // COLOR_BTNSHADOW, COLOR_BTNHIGHLIGHT, COLOR_BTNTEXT, ...) is the same
    // story — does NOT shift with the OS setting for a plain,
    // non-manifested Win32 window — confirmed live, same finding design
    // review already
    // had for COLOR_BTNFACE specifically — so this pair of hardcoded
    // overrides (WindowsTheme.darkBackgroundHex/darkTextHex, extracted in
    // SETTINGS_PLAN.md's T2 so TaskPromptDialog.swift can share them) is
    // the one thing every dark-aware owner-drawn surface below actually
    // needs.
    // A little lighter than darkBackgroundHex — only used for the scroll
    // rail's thumb, which needs to read as "sitting above" its own track
    // rather than blending into it the way the flat background color would.
    private static let darkElevatedHex = "#5A5A5A"
    // The scroll rail's own track needs to read as distinct from the page
    // body behind it (see drawScrollRail) the same way COLOR_SCROLLBAR
    // reads as distinct from COLOR_BTNFACE in light mode — this sits
    // between darkBackgroundHex and darkElevatedHex so the thumb still
    // stands out on top of it.
    private static let darkScrollTrackHex = "#3A3A3A"
    // drawBevel's own dark-mode shadow edge — near-black rather than a
    // mid-gray so a raised/sunken bevel still reads as a real 3D edge
    // against darkBackgroundHex, the same contrast job COLOR_BTNSHADOW
    // does against COLOR_BTNFACE in light mode.
    private static let darkBevelShadowHex = "#0F0F0F"

    // A hint's own text color (addHint/handleCtlColor, SETTINGS_PLAN.md's
    // S4) — dimmer than the ordinary darkTextHex/COLOR_BTNTEXT pair in
    // both themes, the same "secondary" reading macOS's Form `footer:`
    // gets for free from the system. Picked against darkBackgroundHex/
    // COLOR_BTNFACE respectively for contrast that still passes as
    // legible-but-quieter, not a literal token from either platform's own
    // secondary-label color.
    private static let hintTextLightHex = "#6E6E6E"
    private static let hintTextDarkHex = "#A0A0A0"

    // The one place isDarkMode gets computed — both call sites below
    // (init and handleSettingChange) assign its result themselves rather
    // than being handed it, matching this file's existing "detect, then
    // applyTheme() separately" split. Delegates to WindowsTheme.resolveDarkMode
    // (extracted in SETTINGS_PLAN.md's T2), which TaskPromptDialog.swift now
    // calls the same way.
    private func resolveDarkMode() -> Bool {
        WindowsTheme.resolveDarkMode(colorScheme: settingsStore.get().colorScheme)
    }

    // SetWindowTheme (uxtheme.dll) isn't one of the dozen libraries a plain
    // MSVC-linked exe gets by default (kernel32/user32/gdi32/comdlg32/
    // shell32/... — confirmed live, that default set is exactly what
    // already lets this file's ChooseColorW/GetSaveFileNameW/
    // SHBrowseForFolderW calls link with no linked-library setup of their
    // own). Calling SetWindowTheme directly compiles fine (WinSDK declares
    // it) but fails at link time with an unresolved external, confirmed
    // live — DwmSetWindowAttribute below doesn't have that problem (it
    // resolves through the WinSDK Swift module's own bundled forwarding,
    // confirmed live too), so only this one function needs the manual
    // LoadLibraryW/GetProcAddress workaround, self-contained here since
    // this task can't add a linked library of its own.
    private typealias SetWindowThemeProc = @convention(c) (HWND?, LPCWSTR?, LPCWSTR?) -> HRESULT
    private static let setWindowThemeProc: SetWindowThemeProc? = {
        let moduleName: [UInt16] = Array("uxtheme.dll".utf16) + [0]
        guard let module = (moduleName.withUnsafeBufferPointer { LoadLibraryW($0.baseAddress) }) else { return nil }
        guard let proc = GetProcAddress(module, "SetWindowTheme") else { return nil }
        return unsafeBitCast(proc, to: SetWindowThemeProc.self)
    }()

    // The documented, widely-cited "DarkMode_Explorer" trick for tab
    // strips/edits/trackbars specifically (see applyTheme's callers
    // below). Reverting to light passes a nil sub-app name, the
    // documented revert. NOTE — a real, confirmed-live
    // undocumented-behavior trap: this call succeeds (verified via a
    // temporary diagnostic build that logged its HRESULT — S_OK, every
    // time, for the tab control and every stepper's edit/up-down and the
    // opacity trackbar alike) but only visibly restyles the stepper edits'
    // own background on this Windows build — the tab strip and trackbar
    // stayed in their light/default appearance in a live screenshot, dark
    // mode active, and the edits' own digits stayed unstyled too (black on
    // the new dark background) until handleCtlColor's WM_CTLCOLOREDIT case
    // started fixing that up separately. Left in (a successful, harmless
    // no-op call for the tab strip/trackbar rather than dead code) since
    // it's still the right, documented thing to call and may do more on a
    // different Windows version — see this task's report for the full
    // finding. The tab strip got its own fix since — see
    // pomoppiTabControlSubclassProc/drawTabControlDark, a WM_PAINT
    // takeover. The trackbar got its own fix too, but via NM_CUSTOMDRAW
    // rather than a WM_PAINT takeover — see handleOpacityTrackbarCustomDraw,
    // the notification Trackbar32 actually documents for this rather than
    // the tab-strip workaround's WM_PAINT subclass. The up-down controls
    // (msctls_updown32) got the tab strip's own WM_PAINT-subclass
    // treatment instead, since they have no custom-draw notification of
    // their own — see pomoppiStepperSubclassProc/drawUpDownDark. Their
    // buddy edits' own WS_EX_CLIENTEDGE border got the same subclass
    // treatment too, just over WM_NCPAINT instead — see
    // handleStepperEditNCPaint.
    private static func setControlDarkTheme(_ hwnd: HWND, dark: Bool) {
        guard let setWindowThemeProc else { return }
        guard dark else {
            _ = setWindowThemeProc(hwnd, nil, nil)
            return
        }
        let subAppName: [UInt16] = Array("DarkMode_Explorer".utf16) + [0]
        _ = subAppName.withUnsafeBufferPointer { setWindowThemeProc(hwnd, $0.baseAddress, nil) }
    }

    // A themed BS_AUTOCHECKBOX draws its own label text via the current
    // visual style, ignoring whatever color WM_CTLCOLORBTN's handler
    // (handleCtlColor, already darkTextHex-aware) hands back — confirmed
    // live: the checkbox square recolors fine under dark mode, but its
    // label stays flat black regardless. Passing empty strings (not nil)
    // is SetWindowTheme's documented way to turn visual styles off for
    // one control entirely, rather than pick a different, still-themed
    // style — with theming off, the control falls back to
    // DrawFrameControl's classic square-box chrome and paints its label
    // through the ordinary WM_CTLCOLORBTN path like any other unthemed
    // control, so darkTextHex actually takes. `nil, nil` (this function's
    // own `dark: false` branch) restores the default theme for light mode.
    private static func setControlClassicTheme(_ hwnd: HWND, classic: Bool) {
        guard let setWindowThemeProc else { return }
        guard classic else {
            _ = setWindowThemeProc(hwnd, nil, nil)
            return
        }
        let empty: [UInt16] = [0]
        _ = empty.withUnsafeBufferPointer { setWindowThemeProc(hwnd, $0.baseAddress, $0.baseAddress) }
    }

    // The one recolor path both dark-mode entry points below funnel
    // through: init calls this once, right after setUpTabsAndPages so
    // every control it touches already exists; handleSettingChange calls
    // it again, live, after re-detecting isDarkMode — neither site repeats
    // any of this logic on its own.
    private func applyTheme() {
        var useDarkMode: Int32 = isDarkMode ? 1 : 0
        _ = DwmSetWindowAttribute(hwnd, DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue), &useDarkMode, DWORD(MemoryLayout<Int32>.size))
        // DWMWA_USE_IMMERSIVE_DARK_MODE alone doesn't repaint the
        // already-drawn titlebar on its own — SWP_FRAMECHANGED forces
        // Windows to recompute and redraw the non-client area right away
        // rather than waiting for some other trigger (a resize/focus
        // change) to do it incidentally later. The titlebar does visibly
        // flip dark with this in place, confirmed live in both directions
        // (apply and the live WM_SETTINGCHANGE revert) — not separately
        // tested with this call removed.
        SetWindowPos(hwnd, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE) | UINT(SWP_NOSIZE) | UINT(SWP_NOZORDER) | UINT(SWP_NOACTIVATE) | UINT(SWP_FRAMECHANGED))

        // tabControl deliberately never goes through setControlDarkTheme,
        // unlike every stepper/trackbar below — confirmed live as the real
        // cause of a second bug: flipping the OS theme live while the
        // settings window is open blanked the visible page to a flat, empty
        // rectangle instead of repainting it. SetWindowTheme posts
        // WM_THEMECHANGED to its target, and the tab control's own themed
        // "body" fill (the strip under the tab labels, part of its
        // visual-styles repaint) lands on its own schedule rather than
        // synchronously inside this call — late enough, on this build, to
        // land *after* this function's own explicit, synchronous page
        // repaint below and paint straight over it (that body fill isn't
        // clipped against the overlapping page the way ordinary client-area
        // painting would be against a WS_CLIPSIBLINGS sibling). Since
        // setControlDarkTheme is already a confirmed no-op for the tab
        // strip's own colors on this Windows build anyway (see its own
        // comment above), skipping it here costs nothing visible and
        // removes the race outright.
        //
        // The tab strip's own dark/light colors instead come from
        // pomoppiTabControlSubclassProc's own WM_PAINT takeover — repainted
        // right here, *before* the page loop below and forced fully
        // synchronous with RDW_UPDATENOW rather than a lazy InvalidateRect.
        // Confirmed live as the exact same race as the paragraph above, just
        // via a different trigger: an InvalidateRect(tabControl) placed
        // *after* the page loop (the first thing tried) reliably blanked
        // the visible page too, even with pomoppiTabControlSubclassProc
        // doing nothing but forwarding every message to DefSubclassProc —
        // so it's the live *timing* of any tabControl repaint racing the
        // page's own one that matters here, not what it actually paints.
        // Doing tabControl's repaint first and waiting for it to fully
        // finish means the page loop's own synchronous repaint below is
        // always the last thing to touch the screen, so nothing can land on
        // top of it afterward.
        if let tabControl {
            RedrawWindow(tabControl, nil, nil, UINT(RDW_INVALIDATE) | UINT(RDW_ERASE) | UINT(RDW_UPDATENOW))
        }

        for stepper in steppers {
            Self.setControlDarkTheme(stepper.editHwnd, dark: isDarkMode)
            Self.setControlDarkTheme(stepper.upDownHwnd, dark: isDarkMode)
            // setControlDarkTheme above is a confirmed no-op for the
            // up-down itself (see pomoppiStepperSubclassProc's own
            // comment) — its actual dark/light repaint comes from
            // drawUpDownDark via that subclass, forced synchronous here
            // for the exact same reason the tab control's own repaint
            // just above is: it has to finish *before* the page loop's
            // own RDW_UPDATENOW pass or a live theme flip blanks the
            // page, per this function's own running finding.
            RedrawWindow(stepper.upDownHwnd, nil, nil, UINT(RDW_INVALIDATE) | UINT(RDW_ERASE) | UINT(RDW_UPDATENOW))
            // Same story for the edit's own non-client border — RDW_FRAME
            // is what actually forces a WM_NCPAINT (RDW_INVALIDATE alone
            // only covers the client area), which is all
            // handleStepperEditNCPaint repaints, so RDW_ERASE isn't
            // needed here.
            RedrawWindow(stepper.editHwnd, nil, nil, UINT(RDW_FRAME) | UINT(RDW_INVALIDATE) | UINT(RDW_UPDATENOW))
        }
        if let opacityTrackbar { Self.setControlDarkTheme(opacityTrackbar, dark: isDarkMode) }

        // Checkbox labels: see setControlClassicTheme's own comment for
        // why turning theming off is what actually gets darkTextHex onto
        // the label instead of the visual style's own hardcoded black.
        for checkbox in checkboxes {
            Self.setControlClassicTheme(checkbox.hwnd, classic: isDarkMode)
        }
        // Plain push buttons (Keys tab's recorder rows + Reset to
        // Defaults, Diary's Erase History/Export/Choose/Sync Now) —
        // "DarkMode_Explorer" is documented to also restyle
        // BS_PUSHBUTTON with a dark face and light text (this is what
        // Notepad++ uses), unlike the tab strip/trackbar's own confirmed
        // no-op with the same sub-app name (see setControlDarkTheme's own
        // comment) — verified live by screenshot rather than assumed.
        for button in plainPushButtons {
            Self.setControlDarkTheme(button, dark: isDarkMode)
        }

        // RDW_ALLCHILDREN because a
        // plain InvalidateRect on a page doesn't cascade to its own
        // children, so every STATIC/BUTTON/owner-drawn control on it would
        // otherwise keep showing its old-theme paint until something else
        // happened to touch it individually.
        for page in pages {
            RedrawWindow(page, nil, nil, UINT(RDW_INVALIDATE) | UINT(RDW_ERASE) | UINT(RDW_ALLCHILDREN) | UINT(RDW_UPDATENOW))
        }

        // Not under any page (see createFooter's own comment), so the loop
        // above's RDW_ALLCHILDREN cascade never reaches these two — same
        // reason they need their own explicit redraw here.
        if let footerVersionLabel {
            RedrawWindow(footerVersionLabel, nil, nil, UINT(RDW_INVALIDATE) | UINT(RDW_ERASE) | UINT(RDW_UPDATENOW))
        }
        if let footerActionButton {
            RedrawWindow(footerActionButton, nil, nil, UINT(RDW_INVALIDATE) | UINT(RDW_ERASE) | UINT(RDW_UPDATENOW))
        }
    }

    // WM_SETTINGCHANGE is broadcast to every top-level window for any of a
    // long list of system setting changes sharing this one message; lParam
    // names which one as a plain string, "ImmersiveColorSet" specifically
    // for a light/dark or accent-color change. Decoded into a real Swift
    // String for the comparison rather than lstrcmpW's raw pointer
    // compare, matching this file's own String(decodingCString:) idiom
    // elsewhere (see promptDiaryExportPath/promptDiaryFolder).
    private func handleSettingChange(lParam: LPARAM) {
        guard let stringPointer = UnsafePointer<UInt16>(bitPattern: UInt(bitPattern: Int(lParam))) else { return }
        guard String(decodingCString: stringPointer, as: UTF16.self) == "ImmersiveColorSet" else { return }
        isDarkMode = resolveDarkMode()
        applyTheme()
    }

    // hbrBackground (registerClassesIfNeeded) is fixed at class-
    // registration time and can't be swapped live for a dark/light flip —
    // this is what actually paints the page (and, in principle, this
    // window's own client area, though the tab control always covers all
    // of it in practice) dark instead, forwarded here from every page via
    // pomoppiSettingsPageWndProc. WindowFromDC recovers whichever window
    // actually owns the HDC wParam carries, since the forwarded message
    // loses that identity along the way. Light mode falls through to
    // DefWindowProcW unchanged — the class's own COLOR_BTNFACE brush,
    // exactly what painted this before dark mode existed.
    private func handleEraseBackground(wParam: WPARAM) -> LRESULT {
        // Int(wParam) traps live — confirmed via a real crash dump ("Not
        // enough bits to represent the passed value"): this HDC's raw
        // WPARAM value doesn't fit a range-checked Int(_:) conversion.
        // Int(bitPattern:) is the non-trapping reinterpretation this file
        // already uses elsewhere for pointer reconstruction (see WM_NOTIFY's
        // own NMHDR pointer above) — used here instead.
        guard isDarkMode, let hdc = HDC(bitPattern: Int(bitPattern: UInt(wParam))) else {
            return DefWindowProcW(hwnd, UINT(WM_ERASEBKGND), wParam, 0)
        }
        let target = WindowFromDC(hdc) ?? hwnd
        var rect = RECT()
        GetClientRect(target, &rect)
        if let brush = WindowsTheme.darkBackgroundBrush {
            FillRect(hdc, &rect, brush)
        }
        return 1
    }

    // SetWindowTheme (setControlDarkTheme above) doesn't restyle plain
    // STATIC labels or BS_AUTOCHECKBOX buttons, nor a stepper edit's own
    // text color (it does darken the edit's background — see
    // setControlDarkTheme's own comment) — this is what does, forwarded
    // here from every page's own children the same way as
    // handleEraseBackground above. Runs in both themes now (SETTINGS_PLAN.md's
    // S4) — a hint label (addHint, tracked in hintLabels) needs its own
    // dimmed text color in light mode too, not just dark; every other
    // control still falls through to DefWindowProcW unchanged in light
    // mode, exactly as before.
    private func handleCtlColor(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        // Int(bitPattern:) rather than a bare Int(wParam)/Int(lParam) — see
        // handleEraseBackground's own comment for why the range-checked
        // conversion traps live for a real HDC/HWND value here.
        guard let hdc = HDC(bitPattern: Int(bitPattern: UInt(wParam))) else {
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        let controlHwnd = HWND(bitPattern: Int(bitPattern: UInt(lParam)))
        if let controlHwnd, hintLabels.contains(controlHwnd) {
            // Both themes, always: a hint is always dimmer than an
            // ordinary control's text. Background still matches whatever
            // the page is already painted with in that theme —
            // WindowsTheme's dark brush, or the same (HBRUSH)(COLOR_BTNFACE+1)
            // cast the page class's own hbrBackground paints with
            // (registerClassesIfNeeded) — so a hint reads as sitting on
            // the page, not as its own separate patch.
            SetTextColor(hdc, Self.colorref(hex: isDarkMode ? Self.hintTextDarkHex : Self.hintTextLightHex))
            if isDarkMode, let brush = WindowsTheme.darkBackgroundBrush {
                SetBkColor(hdc, WindowsTheme.colorref(hex: WindowsTheme.darkBackgroundHex))
                return LRESULT(Int(bitPattern: brush))
            }
            guard let brush = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1)) else {
                return DefWindowProcW(hwnd, message, wParam, lParam)
            }
            SetBkColor(hdc, GetSysColor(COLOR_BTNFACE))
            return LRESULT(Int(bitPattern: brush))
        }
        guard isDarkMode, let brush = WindowsTheme.darkBackgroundBrush else {
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        SetTextColor(hdc, WindowsTheme.colorref(hex: WindowsTheme.darkTextHex))
        SetBkColor(hdc, WindowsTheme.colorref(hex: WindowsTheme.darkBackgroundHex))
        return LRESULT(Int(bitPattern: brush))
    }

    // -- WndProc dispatch -----------------------------------------------------

    func handleMessage(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        switch Int32(message) {
        case WM_NOTIFY:
            let header = UnsafeMutablePointer<NMHDR>(bitPattern: UInt(bitPattern: Int(lParam)))
            guard let header else { return 0 }
            if let tabControl, header.pointee.hwndFrom == tabControl, header.pointee.code == TCN_SELCHANGE {
                selectTab(Int(SendMessageW(tabControl, UINT(TCM_GETCURSEL), 0, 0)))
                return 0
            }
            if header.pointee.code == UDN_DELTAPOS,
               let stepper = steppers.first(where: { $0.upDownHwnd == header.pointee.hwndFrom }) {
                return handleUpDownDeltaPos(lParam: lParam, stepper: stepper)
            }
            if header.pointee.code == NM_CUSTOMDRAW, let opacityTrackbar, header.pointee.hwndFrom == opacityTrackbar {
                return handleOpacityTrackbarCustomDraw(lParam: lParam)
            }
            return 0
        case WM_COMMAND:
            handleCommand(wParam: wParam, lParam: lParam)
            return 0
        case WM_DRAWITEM:
            return handleDrawItem(lParam: lParam)
        case WM_HSCROLL:
            handleOpacityScroll(lParam: lParam)
            return 0
        case WM_ERASEBKGND:
            return handleEraseBackground(wParam: wParam)
        case WM_CTLCOLORSTATIC, WM_CTLCOLORBTN, WM_CTLCOLOREDIT:
            return handleCtlColor(message: message, wParam: wParam, lParam: lParam)
        case WM_SETTINGCHANGE:
            handleSettingChange(lParam: lParam)
            // Passed through rather than swallowed — WM_SETTINGCHANGE is a
            // broadcast other parts of the system may also care about, not
            // something only this window owns the way e.g. WM_HSCROLL's
            // trackbar is.
            return DefWindowProcW(hwnd, message, wParam, lParam)
        case WM_MOUSEWHEEL:
            return handleMouseWheel(wParam: wParam, lParam: lParam)
        case WM_GETMINMAXINFO:
            // Floors a drag-resize at exactly clientWidth/clientHeight (the
            // size every tab's content is proven to fit at, Appearance's
            // own scroll excepted) — never a maximum, letting the window
            // grow as large as Windows' own default track-size logic
            // allows. Sent once during CreateWindowExW itself too, before
            // `shared` is assigned (pomoppiSettingsWndProc's guard falls
            // through to DefWindowProcW for that one), which is harmless:
            // the window is already created at exactly windowWidth/
            // windowHeight above regardless of what this handler would
            // have said.
            guard let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: UInt(bitPattern: Int(lParam))) else {
                return DefWindowProcW(hwnd, message, wParam, lParam)
            }
            var minRect = RECT(left: 0, top: 0, right: Self.clientWidth, bottom: Self.clientHeight)
            AdjustWindowRectEx(&minRect, Self.windowStyle, false, 0)
            info.pointee.ptMinTrackSize = POINT(x: minRect.right - minRect.left, y: minRect.bottom - minRect.top)
            return 0
        case WM_SIZE:
            handleResize()
            return 0
        case WM_TIMER:
            // The footer's own "Up to date" -> idle auto-revert, 5s after a
            // manual check resolves to no update — see checkForUpdatesNow.
            if wParam == Self.manualCheckRevertTimerID {
                KillTimer(hwnd, Self.manualCheckRevertTimerID)
                manualCheckRevertPending = false
                manualCheckState = .idle
                refreshUpdateFooter()
            }
            return 0
        case WM_KEYDOWN, WM_SYSKEYDOWN:
            // Always swallowed (return 0) rather than falling through to
            // DefWindowProcW: this only ever arrives forwarded from the
            // Keys page (see pomoppiSettingsPageWndProc — DefWindowProcW
            // would need the *page's* own HWND to mean anything here, not
            // this window's), and the Keys page never has keyboard focus
            // except while startRecording explicitly gave it that focus, so
            // there's no other default behavior worth preserving.
            handleShortcutRecorderKeyDown(wParam: wParam)
            return 0
        case WM_CLOSE:
            // Same reasoning as selectTab's own stopRecording call: closing
            // the window mid-recording must not leave every global hotkey
            // unregistered with no window left to finish the capture in.
            if recordingActionID != nil {
                stopRecording()
            }
            // Closing the settings window must never quit the app — only
            // WidgetWindow's own WM_DESTROY calls PostQuitMessage.
            DestroyWindow(hwnd)
            return 0
        case WM_DESTROY:
            if manualCheckRevertPending { KillTimer(hwnd, Self.manualCheckRevertTimerID) }
            updateChecker.onUpdate = nil
            Self.shared = nil
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }

    // -- checkbox / stepper notification dispatch -----------------------------

    // BN_CLICKED (checkboxes) and EN_KILLFOCUS (stepper edits, after direct
    // typing) both arrive here — wParam's high word is the notification
    // code, lParam is always the sending control's own HWND.
    private func handleCommand(wParam: WPARAM, lParam: LPARAM) {
        let notificationCode = Int32(truncatingIfNeeded: UInt32(truncatingIfNeeded: wParam) >> 16)
        guard let controlHwnd = HWND(bitPattern: Int(lParam)) else { return }

        if notificationCode == BN_CLICKED, let checkbox = checkboxes.first(where: { $0.hwnd == controlHwnd }) {
            let checked = SendMessageW(controlHwnd, UINT(BM_GETCHECK), 0, 0) == BST_CHECKED
            checkbox.onToggle(checked)
            return
        }
        if notificationCode == BN_CLICKED, let button = pushButtons.first(where: { $0.hwnd == controlHwnd }) {
            button.onClick()
            return
        }
        if notificationCode == EN_KILLFOCUS, let stepper = steppers.first(where: { $0.editHwnd == controlHwnd }) {
            commitTypedStepperValue(stepper)
        }
    }

    // Reads whatever the user actually typed into a stepper's buddy edit,
    // clamps it the same way PomoppiSettings.clampInPlace would, and pushes
    // it back through both UDM_SETPOS32 (so the displayed text normalizes,
    // e.g. an out-of-range or empty value snaps back) and the stored
    // setting. UDS_SETBUDDYINT only syncs up-down position -> edit text,
    // never the other way, so this is the only path that notices typing.
    private func commitTypedStepperValue(_ stepper: StepperControl) {
        let length = GetWindowTextLengthW(stepper.editHwnd)
        var buffer = [UInt16](repeating: 0, count: Int(length) + 1)
        GetWindowTextW(stepper.editHwnd, &buffer, Int32(buffer.count))
        let text = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)

        let newValue: Int32
        if let typed = Int32(text) {
            newValue = min(stepper.max, max(stepper.min, typed))
        } else {
            // Not parseable (e.g. left empty) — snap back to whatever the
            // up-down control still thinks its position is.
            newValue = Int32(SendMessageW(stepper.upDownHwnd, UINT(UDM_GETPOS32), 0, 0))
        }
        SendMessageW(stepper.upDownHwnd, UINT(UDM_SETPOS32), 0, LPARAM(Int(newValue)))
        stepper.onChange(newValue)
    }

    // UDS_SETBUDDYINT's own default arrow-click behavior steps by 1 — this
    // intercepts the notification (sent before the position actually
    // changes, per NMUPDOWN.iPos/iDelta) to scale the delta by the
    // stepper's own step size instead, applies the clamped result ourselves
    // via UDM_SETPOS32, and returns nonzero to suppress the control's
    // default single-step application.
    private func handleUpDownDeltaPos(lParam: LPARAM, stepper: StepperControl) -> LRESULT {
        guard let details = UnsafeMutablePointer<NMUPDOWN>(bitPattern: UInt(bitPattern: Int(lParam))) else { return 0 }
        let newValue = min(stepper.max, max(stepper.min, details.pointee.iPos + details.pointee.iDelta * stepper.step))
        SendMessageW(stepper.upDownHwnd, UINT(UDM_SETPOS32), 0, LPARAM(Int(newValue)))
        stepper.onChange(newValue)
        return 1
    }
}
