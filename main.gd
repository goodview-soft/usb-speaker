extends Control
## USB Speaker : le téléphone devient enceinte + micro du PC, par le câble USB.
## PC : pilote adb (installe/lance l'app, `adb forward`), capture la sortie son et l'envoie en TCP.
## Téléphone : écoute sur le port 5005, joue le son, renvoie son micro.

const PORT := 5005
const RATE := 48000
const PKG := "fr.goodview.usbspeaker"
const VERSION := 19  # versionCode de l'APK
const APP_VERSION := "2.3.0"
const REPO := "goodview-soft/usb-speaker"
const T_AUDIO := 1  # PC -> téléphone : PCM s16 stéréo 48 kHz
const T_MIC := 2  # téléphone -> PC : PCM s16 mono
const T_HELLO := 3  # téléphone -> PC : u32 fréquence du micro (= connexion acceptée)
const T_CTRL := 5  # téléphone -> PC : [son du PC voulu, micro envoyé]
const T_DRIVE := 6  # téléphone -> PC : 4×s16 sticks (LX LY RX RY), u8 LT, u8 RT, u16 boutons
const BEACON_PORT := PORT + 4  # annonce des PC hôtes (UDP)
const HOST_PORT := PORT + 5  # connexion téléphone -> PC hôte (TCP)
const T_SHOT := 9  # PC -> téléphone : capture JPEG [flags: 1=début 2=fin] + données
const T_SHOTREQ := 10  # téléphone -> PC : [x%, y%, largeur%, hauteur%]
const T_CHAT := 11  # téléphone -> PC : [flags: 1 = Entrée avant] + texte utf8
const T_CHATRES := 12  # PC -> téléphone : [1 = ok, 0 = refusé]
const T_CHATLIST := 13  # PC -> téléphone : JSON {"e": [{"n": nom, "m": message, "t": traduction}]}
const T_AI := 14  # téléphone -> PC : JSON {"op": reply|translate|fix, ...}
const T_AIRES := 15  # PC -> téléphone : JSON {"ok", "op", "text"}
const T_VOICE := 16  # téléphone -> PC : voix 16 kHz mono s16 (début : langues)
const T_VOICERES := 17  # PC -> téléphone : JSON {"ok", "text"}
const LANGS := [["Sans traduction", "", ""], ["Anglais", "English", "en"], ["Espagnol", "Spanish", "es"],
	["Allemand", "German", "de"], ["Italien", "Italian", "it"], ["Portugais", "Portuguese", "pt"],
	["Russe", "Russian", "ru"], ["Polonais", "Polish", "pl"], ["Ukrainien", "Ukrainian", "uk"],
	["Néerlandais", "Dutch", "nl"], ["Français", "French", "fr"]]
const T_PING := 7  # aller-retour (latence) : u32 ms
const T_PONG := 8
const T_NAME := 4  # PC -> téléphone : nom du PC (utf8)
const SINK := "usbspk_out"
const MIC_SINK := "usbspk_mic_sink"
const MIC_SRC := "usbspk_mic_sink.monitor"
const CHUNK := RATE / 50  # 20 ms

var is_phone := OS.has_feature("android") or OS.get_environment("USBSPK_PHONE") == "1"
var peer: StreamPeerTCP
var rxbuf := PackedByteArray()
var linked := false

var status: Label
var sub: Label
var mic_check: CheckButton
var out_check: CheckButton
var vol_slider: HSlider
var bar: ProgressBar

# --- téléphone
var server: TCPServer
var player: AudioStreamPlayer
var pb: AudioStreamGeneratorPlayback
var mic_player: AudioStreamPlayer
var cap: AudioEffectCapture
var peak := 0.0

# --- PC
var th_adb: Thread
var th_cap: Thread
var mtx := Mutex.new()
var quit := false
var adb_state := "none"  # none | noadb | ready
var adb_msg := ""
var adb_bin := "adb"
var cap_queue: Array = []
var cap_pid := -1
var cap_io: FileAccess
var mic_pid := -1
var mic_io: FileAccess
var mic_rate := RATE
var prev_sink := ""
var modules: PackedStringArray = []
var try_t := 0.0
var wait_t := 0.0
var cand_i := 0
var pending: Array = []
var pend_box: VBoxContainer
var pend_sig := ""
var last_pc := ""
var name_sent := false
var tabs: TabContainer
var wheel: Wheel
var drive_info: Label
var pad_ui: Control
var pad_open := false
var pad_zones: Array = []
var lstick: Stick
var rstick: Stick
var gyro_btn: Button
var inv_btn: Button
var pad_hint: Label
var gyro_on := false
var gyro_range := 45.0
var owned := {}
var ang_off := 0.0
var cal_t := 0.0
var steer_s := 0.0
var touches := {}
var drive_was := false
var pad_pid := -1
var pad_io: FileAccess
var pad_err: FileAccess
var pad_last := ""
var drive_t := 0
var drive_v := [0, 0, 0, 0, 0, 0, 0]
var link_lbl: Label
var link_opt: OptionButton
var link_mode := 0  # 0 auto, 1 réseau Wi-Fi, 2 câble USB
var cur_host := ""
var rtt_ms := -1
var ping_sent := 0
var net_t := 0.0
var udp_pad := PacketPeerUDP.new()
var pad_rx := PacketPeerUDP.new()
var seq_tx := 0
var seq_rx := -1
var last_pad_key := ""
var last_pad_t := 0
var host_on := true
var host_srv: TCPServer
var host_udp := PacketPeerUDP.new()
var host_t := 0
var host_check: CheckButton
var host_rx := PacketPeerUDP.new()
var hosts := {}
var host_box: VBoxContainer
var host_sig := ""
var out_peer: StreamPeerTCP
var out_t := 0
var shot_frame: Panel
var shot_view: TextureRect
var shot_prev: TextureRect
var shot_buf := PackedByteArray()
var shot_until := 0
var shot_req_t := 0
var shot_last_t := 0
var shot_sl: Array = []
var shot_info: Label
var sel_prev := false
var chat_edit: LineEdit
var chat_enter: CheckButton
var chat_allow: CheckButton
var chat_status: Label
var chat_panel: Panel
var chat_line: LineEdit
var kb_pid := -1
var kb_io: FileAccess
var chat_scroll: ScrollContainer
var chat_zoom := 1.0
var zoom_lbl: Label
var sel_box: SelBox
var selecting := false
var sel_a := Vector2.ZERO
var sel_tg: Button
var lang_out_opt: OptionButton
var lang_in_opt: OptionButton
var tone_opt: OptionButton
var tr_in_check: CheckButton
var mic_btn: Button
var viewer_panel: PanelContainer
var list_panel: PanelContainer
var chat_list: VBoxContainer
var zoom_box: HBoxContainer
var view_btns: Array = []
var chat_entries: Array = []
var dict_on := false
var dict_buf := PackedFloat32Array()
var dict_t := 0
var ocr_th: Thread
var ocr_busy := false
var ai_model := ""
var ai_opt: OptionButton
var stt_pid := -1
var stt_io: FileAccess
var stt_th: Thread
var voice_buf := PackedByteArray()
var voice_lang := "fr"
var voice_out := ""
var margin: MarginContainer
var status_panel: PanelContainer
var pad_safe: Control
var vib_on := true
var prev_pr := {}
var upd_status: Label
var auto_upd: CheckButton
var manual_check := false
var upd_timer := 1800.0
var auto_tried := false
var drive_check: CheckButton
var sound_check: CheckButton
var phone_sound := true
var phone_mic := true
var prev_src := ""
var http: HTTPRequest
var dl: HTTPRequest
var upd_btn: Button
var url_apk := ""
var url_zip := ""
var new_tag := ""
var lan := PacketPeerUDP.new()
var lan_ip := ""
var lan_t := 0
var beacon := PacketPeerUDP.new()
var beacon_t := 0


func _ready() -> void:
	var win := get_window()
	win.content_scale_size = Vector2i(440, 880) if is_phone else Vector2i(460, 720)
	if not is_phone:
		win.size = Vector2i(460, 720)
		win.min_size = Vector2i(380, 560)
	theme = _make_theme()
	_build_ui()
	get_viewport().size_changed.connect(_fit)
	_fit()
	_check_update()
	if is_phone:
		_phone_init()
	else:
		_pc_init()
	if is_phone and OS.get_environment("USBSPK_PADTEST") == "1":
		_open_pad(true)
		gyro_btn.button_pressed = true
		chat_panel.visible = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not is_phone:
		_pc_shutdown()
	elif is_phone and pad_ui != null and (what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT):
		touches.clear()
		owned.clear()
		lstick.release()
		rstick.release()


func _exit_tree() -> void:
	if not is_phone:
		_pc_shutdown()


# ------------------------------------------------------------------ UI

const C_BG := Color("0f1218")
const C_BG2 := Color("1a2030")
const C_BG3 := Color("283147")
const C_ACC := Color("4f8cff")
const C_TXT := Color("e8edf5")


func _sbox(col: Color, radius := 12, ph := 12, pv := 8, border := Color(0, 0, 0, 0), bw := 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = ph
	sb.content_margin_right = ph
	sb.content_margin_top = pv
	sb.content_margin_bottom = pv
	if bw > 0:
		sb.border_color = border
		sb.set_border_width_all(bw)
	return sb


func _switch_tex(on: bool) -> ImageTexture:
	var im := Image.create(48, 28, false, Image.FORMAT_RGBA8)
	var track := C_ACC if on else Color("3b4252")
	var kx := 34.0 if on else 14.0
	for y in 28:
		for x in 48:
			var px := Vector2(x + 0.5, y + 0.5)
			var d := px.distance_to(Vector2(clampf(px.x, 14.0, 34.0), 14.0)) - 14.0
			var kd := px.distance_to(Vector2(kx, 14.0)) - 10.0
			var c := track.lerp(Color.WHITE, clampf(0.5 - kd, 0.0, 1.0))
			c.a = clampf(0.5 - d, 0.0, 1.0)
			im.set_pixel(x, y, c)
	return ImageTexture.create_from_image(im)


func _cam_tex() -> ImageTexture:
	var im := Image.create(40, 40, false, Image.FORMAT_RGBA8)
	for y in 40:
		for x in 40:
			var p := Vector2(x + 0.5, y + 0.5)
			# corps arrondi (4,13)-(36,34), bosse (14,8)-(26,13), objectif percé
			var q := (p - Vector2(20, 23.5)).abs() - Vector2(16, 10.5) + Vector2(5, 5)
			var body := (Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0)) - 5.0
			var bump := maxf(absf(p.x - 20.0) - 6.0, absf(p.y - 10.5) - 2.5)
			var d := minf(body, bump)
			var a := clampf(0.5 - d, 0.0, 1.0)
			var lens := p.distance_to(Vector2(20, 24))
			a *= 1.0 - clampf(0.5 - (absf(lens - 6.0) - 2.0), 0.0, 1.0) * 0.0
			if lens < 8.0 and lens > 5.0:
				a = 0.0
			im.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(im)


func _mic_tex() -> ImageTexture:
	var im := Image.create(40, 40, false, Image.FORMAT_RGBA8)
	for y in 40:
		for x in 40:
			var p := Vector2(x + 0.5, y + 0.5)
			var cap_d := p.distance_to(Vector2(20.0, clampf(p.y, 12.0, 18.0))) - 6.0
			var arc := 1e9
			if p.y >= 18.0:
				arc = absf(p.distance_to(Vector2(20.0, 18.0)) - 11.0) - 1.4
			var stem := maxf(absf(p.x - 20.0) - 1.4, absf(p.y - 32.5) - 3.5)
			var base := maxf(absf(p.x - 20.0) - 6.0, absf(p.y - 36.0) - 1.4)
			var dd := minf(minf(cap_d, arc), minf(stem, base))
			im.set_pixel(x, y, Color(1, 1, 1, clampf(0.5 - dd, 0.0, 1.0)))
	return ImageTexture.create_from_image(im)


func _knob_tex(d: int, col: Color) -> ImageTexture:
	var im := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var r := d / 2.0
	for y in d:
		for x in d:
			var dist := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(r, r))
			var c := col.lerp(Color.WHITE, clampf(dist - (r - 4.0), 0.0, 1.0))
			c.a = clampf(r - dist, 0.0, 1.0)
			im.set_pixel(x, y, c)
	return ImageTexture.create_from_image(im)


## Thème commun : gros éléments tactiles, coins arrondis, sombre.
func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 16
	t.set_color("font_color", "Label", C_TXT)
	for st in ["normal", "hover", "pressed", "disabled"]:
		var col := C_BG3
		if st == "hover":
			col = C_BG3.lightened(0.12)
		elif st == "pressed":
			col = C_ACC
		elif st == "disabled":
			col = C_BG2
		t.set_stylebox(st, "Button", _sbox(col))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", C_TXT)
	t.set_color("font_pressed_color", "Button", Color.WHITE)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.4))
	# onglets
	t.set_font_size("font_size", "TabContainer", 14)
	t.set_stylebox("tab_selected", "TabContainer", _sbox(C_ACC, 10, 10, 8))
	t.set_stylebox("tab_unselected", "TabContainer", _sbox(C_BG2, 10, 10, 8))
	t.set_stylebox("tab_hovered", "TabContainer", _sbox(C_BG3, 10, 10, 8))
	t.set_stylebox("tab_disabled", "TabContainer", _sbox(C_BG2, 10, 10, 8))
	t.set_stylebox("panel", "TabContainer", StyleBoxEmpty.new())
	t.set_stylebox("tabbar_background", "TabContainer", StyleBoxEmpty.new())
	t.set_color("font_selected_color", "TabContainer", Color.WHITE)
	t.set_color("font_unselected_color", "TabContainer", Color(1, 1, 1, 0.65))
	t.set_color("font_hovered_color", "TabContainer", Color.WHITE)
	t.set_constant("side_margin", "TabContainer", 0)
	# interrupteurs
	var on_t := _switch_tex(true)
	var off_t := _switch_tex(false)
	for n in ["checked", "checked_disabled", "checked_mirrored", "checked_disabled_mirrored"]:
		t.set_icon(n, "CheckButton", on_t)
	for n in ["unchecked", "unchecked_disabled", "unchecked_mirrored", "unchecked_disabled_mirrored"]:
		t.set_icon(n, "CheckButton", off_t)
	t.set_constant("h_separation", "CheckButton", 10)
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		t.set_stylebox(st, "CheckButton", _sbox(Color(0, 0, 0, 0), 8, 4, 6))
	t.set_color("font_color", "CheckButton", C_TXT)
	t.set_color("font_pressed_color", "CheckButton", C_TXT)
	t.set_color("font_hover_color", "CheckButton", C_TXT)
	t.set_color("font_hover_pressed_color", "CheckButton", C_TXT)
	# curseurs
	var knob := _knob_tex(30, C_ACC)
	t.set_icon("grabber", "HSlider", knob)
	t.set_icon("grabber_highlight", "HSlider", knob)
	t.set_icon("grabber_disabled", "HSlider", knob)
	t.set_stylebox("slider", "HSlider", _sbox(C_BG3, 4, 0, 3))
	t.set_stylebox("grabber_area", "HSlider", _sbox(C_ACC, 4, 0, 3))
	t.set_stylebox("grabber_area_highlight", "HSlider", _sbox(C_ACC, 4, 0, 3))
	# champ de texte
	t.set_stylebox("normal", "LineEdit", _sbox(C_BG2, 10, 12, 8, C_BG3, 2))
	t.set_stylebox("focus", "LineEdit", _sbox(C_BG2, 10, 12, 8, C_ACC, 2))
	t.set_color("font_color", "LineEdit", C_TXT)
	t.set_color("font_placeholder_color", "LineEdit", Color(1, 1, 1, 0.4))
	# barre de niveau
	t.set_stylebox("background", "ProgressBar", _sbox(C_BG3, 7, 0, 0))
	t.set_stylebox("fill", "ProgressBar", _sbox(Color("2ecc71"), 7, 0, 0))
	# menus déroulants
	t.set_stylebox("panel", "PopupMenu", _sbox(C_BG2, 12, 10, 10, C_BG3, 2))
	t.set_font_size("font_size", "PopupMenu", 16)
	t.set_constant("v_separation", "PopupMenu", 10)
	return t


## Marges : zones de sécurité (encoche, coins arrondis) + largeur max sur grand écran.
func _fit() -> void:
	if margin == null:
		return
	var vp := get_viewport_rect().size
	var l := 10.0
	var r := 10.0
	var tp := 10.0
	var b := 10.0
	if is_phone:
		var win := Vector2(DisplayServer.window_get_size())
		var sa := DisplayServer.get_display_safe_area()
		if win.x > 0.0 and sa.size.x > 0 and sa.size.y > 0:
			var k := vp.x / win.x
			l += maxf(0.0, sa.position.x * k)
			tp += maxf(0.0, sa.position.y * k)
			r += maxf(0.0, (win.x - sa.end.x) * k)
			b += maxf(0.0, (win.y - sa.end.y) * k)
	var avail := vp.x - l - r
	if avail > 560.0:
		var extra := (avail - 560.0) / 2.0
		l += extra
		r += extra
	margin.add_theme_constant_override("margin_left", int(l))
	margin.add_theme_constant_override("margin_right", int(r))
	margin.add_theme_constant_override("margin_top", int(tp))
	margin.add_theme_constant_override("margin_bottom", int(b))
	if pad_safe != null:
		_fit_pad()


func _fit_pad() -> void:
	var l := 0.0
	var r := 0.0
	var tp := 0.0
	var b := 0.0
	var win := Vector2(DisplayServer.window_get_size())
	var sa := DisplayServer.get_display_safe_area()
	if win.x > 0.0 and sa.size.x > 0 and sa.size.y > 0:
		var k := get_viewport_rect().size.x / win.x
		l = maxf(0.0, sa.position.x * k)
		tp = maxf(0.0, sa.position.y * k)
		r = maxf(0.0, (win.x - sa.end.x) * k)
		b = maxf(0.0, (win.y - sa.end.y) * k)
	pad_safe.offset_left = l
	pad_safe.offset_top = tp
	pad_safe.offset_right = -r
	pad_safe.offset_bottom = -b


class SelBox extends Control:
	var r := Rect2()
	var active := false

	func _draw() -> void:
		if not active:
			return
		var rr := Rect2(r.position * size, r.size * size)
		draw_rect(rr, Color(1, 0.3, 0.3, 0.25), true)
		draw_rect(rr, Color("ff5555"), false, 2.0)


class Stick extends Control:
	var idx := -1
	var v := Vector2.ZERO

	func _draw() -> void:
		var c := size / 2.0
		var r := minf(size.x, size.y) * 0.5
		draw_circle(c, r, Color(1, 1, 1, 0.10))
		draw_arc(c, r, 0.0, TAU, 48, Color(1, 1, 1, 0.35), 3.0)
		draw_circle(c + v * r * 0.6, r * 0.36, Color(1, 1, 1, 0.55))

	func set_touch(pos: Vector2) -> void:
		var c := get_global_rect().get_center()
		v = ((pos - c) / (minf(size.x, size.y) * 0.4)).limit_length(1.0)
		queue_redraw()

	func release() -> void:
		idx = -1
		v = Vector2.ZERO
		queue_redraw()


class Wheel extends Control:
	var steer := 0.0:
		set(v):
			steer = v
			queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var r := minf(size.x, size.y) * 0.42
		var a := steer * deg_to_rad(90.0)
		draw_arc(c, r, 0.0, TAU, 64, Color("e8edf5"), 10.0)
		draw_line(c, c + Vector2(cos(a), sin(a)) * r, Color("e8edf5"), 9.0)
		draw_line(c, c + Vector2(cos(a + PI), sin(a + PI)) * r, Color("e8edf5"), 9.0)
		draw_line(c, c + Vector2(cos(a + PI / 2.0), sin(a + PI / 2.0)) * r, Color("e8edf5"), 9.0)
		draw_circle(c, 14.0, Color("e8edf5"))
		draw_circle(c + Vector2(cos(a - PI / 2.0), sin(a - PI / 2.0)) * r, 9.0, Color("e5484d"))


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = C_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	margin.add_child(v)
	status_panel = PanelContainer.new()
	v.add_child(status_panel)
	var sv := VBoxContainer.new()
	sv.add_theme_constant_override("separation", 2)
	status_panel.add_child(sv)
	status = Label.new()
	status.add_theme_font_size_override("font_size", 20)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sv.add_child(status)
	sub = Label.new()
	sub.add_theme_font_size_override("font_size", 13)
	sub.modulate = Color(1, 1, 1, 0.8)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sv.add_child(sub)
	upd_btn = Button.new()
	upd_btn.visible = false
	upd_btn.custom_minimum_size = Vector2(0, 44)
	upd_btn.pressed.connect(_do_update)
	v.add_child(upd_btn)
	if is_phone:
		pend_box = VBoxContainer.new()
		pend_box.add_theme_constant_override("separation", 10)
		v.add_child(pend_box)
	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.tabs_position = TabContainer.POSITION_BOTTOM
	v.add_child(tabs)
	var p1 := VBoxContainer.new()
	p1.name = "Partage de son"
	p1.add_theme_constant_override("separation", 10)
	tabs.add_child(p1)
	bar = ProgressBar.new()
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 14)
	p1.add_child(bar)
	if is_phone:
		var vr := HBoxContainer.new()
		vr.add_theme_constant_override("separation", 12)
		p1.add_child(vr)
		var l := Label.new()
		l.text = "Volume"
		vr.add_child(l)
		vol_slider = HSlider.new()
		vol_slider.min_value = 0.0
		vol_slider.max_value = 1.5
		vol_slider.step = 0.01
		vol_slider.value = 1.0
		vol_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vol_slider.custom_minimum_size = Vector2(0, 32)
		vr.add_child(vol_slider)
		sound_check = CheckButton.new()
		sound_check.text = "Son du PC"
		sound_check.button_pressed = true
		sound_check.toggled.connect(func(_on): _send_ctrl())
		p1.add_child(sound_check)
		mic_check = CheckButton.new()
		mic_check.text = "Micro vers le PC"
		mic_check.button_pressed = false
		mic_check.toggled.connect(func(_on): _send_ctrl())
		p1.add_child(mic_check)
	else:
		out_check = CheckButton.new()
		out_check.text = "Son du PC → téléphone"
		out_check.button_pressed = true
		out_check.toggled.connect(func(_on): _pc_route())
		p1.add_child(out_check)
		mic_check = CheckButton.new()
		mic_check.text = "Micro du téléphone"
		mic_check.button_pressed = true
		p1.add_child(mic_check)
	_build_game_tab()
	_build_net_tab()


## Zone tactile de la manette, placée par fractions de l'écran (centre cx, cy ; taille w, h).
func _pz(id: String, txt: String, col: Color, cx: float, cy: float, w: float, h: float, fs := 24) -> Panel:
	var p := Panel.new()
	p.name = id
	p.anchor_left = cx
	p.anchor_right = cx
	p.anchor_top = cy
	p.anchor_bottom = cy
	p.offset_left = -w / 2.0
	p.offset_right = w / 2.0
	p.offset_top = -h / 2.0
	p.offset_bottom = h / 2.0
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(int(minf(w, h) * 0.3))
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = txt
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", fs)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(l)
	pad_safe.add_child(p)
	pad_zones.append(p)
	return p


func _pbtn(txt: String, cx: float, w: float) -> Button:
	var b := Button.new()
	b.text = txt
	b.anchor_left = cx
	b.anchor_right = cx
	b.offset_left = -w / 2.0
	b.offset_right = w / 2.0
	b.offset_top = 6.0
	b.offset_bottom = 40.0
	b.add_theme_font_size_override("font_size", 14)
	pad_safe.add_child(b)
	return b


func _build_game_tab() -> void:
	var jeu := VBoxContainer.new()
	jeu.name = "Jeu"
	jeu.add_theme_constant_override("separation", 8)
	tabs.add_child(jeu)
	var gl := Label.new()
	gl.text = "Arma Reforger"
	gl.add_theme_font_size_override("font_size", 22)
	gl.add_theme_color_override("font_color", C_ACC)
	jeu.add_child(gl)
	var arma := TabContainer.new()
	arma.size_flags_vertical = Control.SIZE_EXPAND_FILL
	jeu.add_child(arma)
	_build_drive_tab(arma)
	_build_screen_tab(arma)
	if is_phone:
		arma.tab_changed.connect(func(i): if i == 0: _open_pad(true))


func _build_screen_tab(parent: Node) -> void:
	var p := VBoxContainer.new()
	p.name = "Chat"
	p.add_theme_constant_override("separation", 8)
	parent.add_child(p)
	shot_prev = TextureRect.new()
	shot_prev.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shot_prev.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if is_phone:
		# 1) saisie en haut (reste visible quand le clavier s'ouvre)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		p.add_child(row)
		mic_btn = Button.new()
		mic_btn.icon = _mic_tex()
		mic_btn.custom_minimum_size = Vector2(48, 44)
		mic_btn.pressed.connect(_dict_toggle)
		row.add_child(mic_btn)
		chat_edit = LineEdit.new()
		chat_edit.placeholder_text = "Message du chat"
		chat_edit.max_length = 200
		chat_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chat_edit.custom_minimum_size = Vector2(0, 44)
		chat_edit.text_submitted.connect(func(_t): _chat_submit(chat_edit))
		row.add_child(chat_edit)
		var cb := Button.new()
		cb.text = "Envoyer"
		cb.custom_minimum_size = Vector2(0, 44)
		cb.pressed.connect(func(): _chat_submit(chat_edit))
		row.add_child(cb)
		var row2 := HBoxContainer.new()
		row2.add_theme_constant_override("separation", 6)
		p.add_child(row2)
		lang_out_opt = OptionButton.new()
		for l in LANGS:
			lang_out_opt.add_item(("→ " + l[0]) if l[0] != "Sans traduction" else l[0])
		lang_out_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(lang_out_opt)
		var fixb := Button.new()
		fixb.text = "Corriger"
		fixb.pressed.connect(func(): _ai_text("fix"))
		row2.add_child(fixb)
		var trb := Button.new()
		trb.text = "Traduire"
		trb.pressed.connect(func(): _ai_text("translate"))
		row2.add_child(trb)
		# 2) barre : capture, vues, zoom
		var tb := HBoxContainer.new()
		tb.add_theme_constant_override("separation", 6)
		p.add_child(tb)
		var cam := Button.new()
		cam.icon = _cam_tex()
		cam.custom_minimum_size = Vector2(48, 40)
		cam.pressed.connect(func(): _request_shot(true))
		tb.add_child(cam)
		for i in 2:
			var vb := Button.new()
			vb.text = ["Liste", "Image"][i]
			vb.toggle_mode = true
			vb.custom_minimum_size = Vector2(0, 40)
			vb.pressed.connect(_set_view.bind(i))
			tb.add_child(vb)
			view_btns.append(vb)
		zoom_box = HBoxContainer.new()
		zoom_box.add_theme_constant_override("separation", 4)
		tb.add_child(zoom_box)
		var zo := Button.new()
		zo.text = "−"
		zo.custom_minimum_size = Vector2(40, 40)
		zo.pressed.connect(func(): _chat_zoom(-1))
		zoom_box.add_child(zo)
		zoom_lbl = Label.new()
		zoom_lbl.text = "×1"
		zoom_box.add_child(zoom_lbl)
		var zi := Button.new()
		zi.text = "+"
		zi.custom_minimum_size = Vector2(40, 40)
		zi.pressed.connect(func(): _chat_zoom(1))
		zoom_box.add_child(zi)
		var sp := Control.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.add_child(sp)
		chat_status = Label.new()
		chat_status.add_theme_font_size_override("font_size", 13)
		chat_status.modulate = Color(1, 1, 1, 0.7)
		chat_status.clip_text = true
		tb.add_child(chat_status)
		var gear := Button.new()
		gear.text = "⚙"
		gear.custom_minimum_size = Vector2(40, 40)
		tb.add_child(gear)
		# 3) liste des messages / image
		list_panel = PanelContainer.new()
		list_panel.add_theme_stylebox_override("panel", _sbox(Color("07090d"), 10, 4, 4, C_BG3, 2))
		list_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		p.add_child(list_panel)
		var ls := ScrollContainer.new()
		ls.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		list_panel.add_child(ls)
		chat_list = VBoxContainer.new()
		chat_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chat_list.add_theme_constant_override("separation", 6)
		ls.add_child(chat_list)
		viewer_panel = PanelContainer.new()
		viewer_panel.add_theme_stylebox_override("panel", _sbox(Color("07090d"), 10, 4, 4, C_BG3, 2))
		viewer_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		viewer_panel.visible = false
		p.add_child(viewer_panel)
		chat_scroll = ScrollContainer.new()
		chat_scroll.resized.connect(_chat_zoom_apply)
		viewer_panel.add_child(chat_scroll)
		chat_scroll.add_child(shot_prev)
		sel_box = SelBox.new()
		sel_box.set_anchors_preset(Control.PRESET_FULL_RECT)
		sel_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		shot_prev.add_child(sel_box)
		shot_prev.mouse_filter = Control.MOUSE_FILTER_STOP
		shot_prev.gui_input.connect(_sel_input)
		# 4) réglages repliés
		var box := VBoxContainer.new()
		box.visible = false
		box.add_theme_constant_override("separation", 4)
		p.add_child(box)
		gear.pressed.connect(func(): box.visible = not box.visible)
		for d in [["X", 0, 90, 0], ["Y", 0, 90, 0], ["Larg.", 10, 100, 35], ["Haut.", 5, 100, 30], ["Durée", 2, 20, 6]]:
			var hr := HBoxContainer.new()
			box.add_child(hr)
			var l := Label.new()
			l.text = d[0]
			l.custom_minimum_size = Vector2(56, 0)
			hr.add_child(l)
			var sl := HSlider.new()
			sl.min_value = d[1]
			sl.max_value = d[2]
			sl.value = d[3]
			sl.step = 1
			sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sl.custom_minimum_size = Vector2(0, 28)
			hr.add_child(sl)
			shot_sl.append(sl)
		sel_tg = Button.new()
		sel_tg.text = "Choisir la zone sur l'écran du PC"
		sel_tg.pressed.connect(_sel_start)
		box.add_child(sel_tg)
		chat_enter = CheckButton.new()
		chat_enter.text = "« ! » puis Entrée autour de la capture"
		chat_enter.button_pressed = true
		box.add_child(chat_enter)
		tr_in_check = CheckButton.new()
		tr_in_check.text = "Traduire les messages reçus en français"
		tr_in_check.button_pressed = true
		box.add_child(tr_in_check)
		var tr2 := HBoxContainer.new()
		box.add_child(tr2)
		var tl2 := Label.new()
		tl2.text = "Dictée"
		tl2.custom_minimum_size = Vector2(70, 0)
		tr2.add_child(tl2)
		lang_in_opt = OptionButton.new()
		for l in [LANGS[10]] + LANGS.slice(1, 10):
			lang_in_opt.add_item(l[0])
		lang_in_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tr2.add_child(lang_in_opt)
		var tr3 := HBoxContainer.new()
		box.add_child(tr3)
		var tl3 := Label.new()
		tl3.text = "Ton IA"
		tl3.custom_minimum_size = Vector2(70, 0)
		tr3.add_child(tl3)
		tone_opt = OptionButton.new()
		for t in ["Amical", "Sérieux", "Humoristique", "Militaire"]:
			tone_opt.add_item(t)
		tone_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tr3.add_child(tone_opt)
		_set_view(0)
	else:
		shot_info = Label.new()
		p.add_child(shot_info)
		chat_allow = CheckButton.new()
		chat_allow.text = "Saisie de texte depuis le téléphone"
		var cfc := ConfigFile.new()
		chat_allow.button_pressed = cfc.load("user://pref.cfg") == OK and bool(cfc.get_value("pc", "chat", false))
		chat_allow.toggled.connect(func(on):
			var c := ConfigFile.new()
			c.load("user://pref.cfg")
			c.set_value("pc", "chat", on)
			c.save("user://pref.cfg"))
		p.add_child(chat_allow)
		ai_opt = OptionButton.new()
		ai_opt.item_selected.connect(func(i):
			ai_model = ai_opt.get_item_text(i)
			var c := ConfigFile.new()
			c.load("user://pref.cfg")
			c.set_value("pc", "ai_model", ai_model)
			c.save("user://pref.cfg"))
		p.add_child(ai_opt)
		shot_prev.custom_minimum_size = Vector2(0, 150)
		p.add_child(shot_prev)


func _set_view(v: int) -> void:
	list_panel.visible = v == 0
	viewer_panel.visible = v == 1
	zoom_box.visible = v == 1
	for i in view_btns.size():
		view_btns[i].button_pressed = i == v


func _chat_show_list(entries: Array) -> void:
	chat_entries = entries
	for c in chat_list.get_children():
		c.queue_free()
	for i in entries.size():
		var e: Dictionary = entries[i]
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _sbox(C_BG2, 10, 10, 8))
		chat_list.add_child(card)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 2)
		card.add_child(v)
		var top := HBoxContainer.new()
		v.add_child(top)
		var nl := Label.new()
		nl.text = str(e.get("n", ""))
		nl.add_theme_color_override("font_color", C_ACC)
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nl.clip_text = true
		top.add_child(nl)
		var ib := Button.new()
		ib.text = "IA"
		ib.custom_minimum_size = Vector2(52, 32)
		ib.pressed.connect(_ai_reply.bind(i))
		top.add_child(ib)
		var ml := Label.new()
		ml.text = str(e.get("m", ""))
		ml.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(ml)
		if e.has("t"):
			var tl := Label.new()
			tl.text = "→ " + str(e["t"])
			tl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			tl.add_theme_color_override("font_color", Color("7fd48b"))
			tl.add_theme_font_size_override("font_size", 14)
			v.add_child(tl)


func _ai_send(d: Dictionary) -> void:
	chat_status.text = "IA…"
	_send(T_AI, JSON.stringify(d).to_utf8_buffer())


func _ai_reply(i: int) -> void:
	var ctx: Array = []
	for k in range(maxi(0, i - 6), i + 1):
		ctx.append("%s: %s" % [chat_entries[k].get("n", ""), chat_entries[k].get("m", "")])
	_ai_send({"op": "reply", "text": str(chat_entries[i].get("m", "")), "n": str(chat_entries[i].get("n", "")),
			"ctx": ctx, "tone": tone_opt.selected})


func _ai_text(op: String) -> void:
	var t := chat_edit.text.strip_edges()
	if t == "":
		chat_status.text = "Écris ou dicte d'abord"
		return
	if op == "translate" and lang_out_opt.selected == 0:
		chat_status.text = "Choisis une langue"
		return
	_ai_send({"op": op, "text": t, "lang": LANGS[lang_out_opt.selected][1]})


## Dictée : un appui démarre l'écoute, un second l'arrête et envoie la voix au PC.
func _dict_toggle() -> void:
	if not dict_on:
		if peer == null or not linked:
			chat_status.text = "Pas de PC connecté"
			return
		dict_on = true
		dict_buf = PackedFloat32Array()
		dict_t = Time.get_ticks_msec()
		cap.clear_buffer()
		mic_btn.modulate = Color("ff5555")
		chat_status.text = "Je t'écoute…"
	else:
		_dict_stop()


func _dict_feed(fr: PackedVector2Array) -> void:
	for v in fr:
		dict_buf.append((v.x + v.y) * 0.5)
	if dict_buf.size() > int(AudioServer.get_mix_rate()) * 25:
		_dict_stop()


func _dict_stop() -> void:
	dict_on = false
	mic_btn.modulate = Color.WHITE
	var rate := AudioServer.get_mix_rate()
	var ratio := rate / 16000.0
	var n := int(dict_buf.size() / ratio)
	if n < 6400:
		chat_status.text = "Trop court"
		return
	var pcm := PackedByteArray()
	pcm.resize(n * 2)
	var last := dict_buf.size() - 1
	for i in n:
		var pos := i * ratio
		var i0 := int(pos)
		var v := lerpf(dict_buf[i0], dict_buf[mini(i0 + 1, last)], pos - i0)
		pcm.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	dict_buf = PackedFloat32Array()
	var lin: String = ([LANGS[10]] + LANGS.slice(1, 10))[lang_in_opt.selected][2]
	var lout: String = LANGS[lang_out_opt.selected][1]
	var pos2 := 0
	while pos2 < pcm.size():
		var m := mini(32000, pcm.size() - pos2)
		var fl := (1 if pos2 == 0 else 0) | (2 if pos2 + m >= pcm.size() else 0)
		var c := PackedByteArray([fl])
		if pos2 == 0:
			var a := lin.to_utf8_buffer()
			var b := lout.to_utf8_buffer()
			c.append(a.size())
			c.append_array(a)
			c.append(b.size())
			c.append_array(b)
		c.append_array(pcm.slice(pos2, pos2 + m))
		_send(T_VOICE, c)
		pos2 += m
	chat_status.text = "Transcription…"


const ZOOMS := [1.0, 1.5, 2.0, 3.0, 4.0]


func _chat_zoom(dir: int) -> void:
	var i := ZOOMS.find(chat_zoom)
	chat_zoom = ZOOMS[clampi(i + dir, 0, ZOOMS.size() - 1)]
	zoom_lbl.text = "×%s" % str(chat_zoom)
	_chat_zoom_apply()


## Adapte l'image à la largeur de la visionneuse (× zoom) : texte net, défilement au doigt.
func _chat_zoom_apply() -> void:
	if chat_scroll == null or shot_prev.texture == null:
		return
	var tex := shot_prev.texture
	var w := maxf(chat_scroll.size.x - 8.0, 50.0) * chat_zoom
	shot_prev.custom_minimum_size = Vector2(w, w * tex.get_height() / maxf(tex.get_width(), 1))


## Choix de la zone : le PC envoie tout l'écran, on dessine un rectangle dessus.
func _sel_start() -> void:
	_set_view(1)
	chat_zoom = 1.0
	zoom_lbl.text = "×1"
	selecting = true
	sel_box.active = false
	sel_box.queue_redraw()
	chat_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	chat_status.text = "Dessine la zone"
	_request_shot(true, false, true)


func _sel_input(ev: InputEvent) -> void:
	if not selecting:
		return
	var sz := shot_prev.size
	if sz.x < 1.0 or sz.y < 1.0:
		return
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed:
			sel_a = (ev.position / sz).clamp(Vector2.ZERO, Vector2.ONE)
			sel_box.r = Rect2(sel_a, Vector2.ZERO)
			sel_box.active = true
		elif sel_box.active:
			var r := sel_box.r
			sel_box.active = false
			sel_box.queue_redraw()
			if r.size.x > 0.03 and r.size.y > 0.03:
				shot_sl[0].value = r.position.x * 100.0
				shot_sl[1].value = r.position.y * 100.0
				shot_sl[2].value = r.size.x * 100.0
				shot_sl[3].value = r.size.y * 100.0
				selecting = false
				chat_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
				chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
				chat_status.text = "Zone enregistrée"
				_request_shot(true, false)
	elif ev is InputEventMouseMotion and sel_box.active:
		var b: Vector2 = (ev.position / sz).clamp(Vector2.ZERO, Vector2.ONE)
		sel_box.r = Rect2(sel_a, b - sel_a).abs()
		sel_box.queue_redraw()


func _build_drive_tab(parent: Node) -> void:
	var p := VBoxContainer.new()
	p.name = "Manette"
	p.add_theme_constant_override("separation", 8)
	parent.add_child(p)
	drive_info = Label.new()
	drive_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	drive_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p.add_child(drive_info)
	if is_phone:
		drive_info.visible = false
		var ob := Button.new()
		ob.text = "Ouvrir la manette"
		ob.custom_minimum_size = Vector2(0, 48)
		ob.pressed.connect(func(): _open_pad(true))
		p.add_child(ob)
		var vc := CheckButton.new()
		vc.text = "Vibrations"
		vc.button_pressed = true
		vc.toggled.connect(func(on): vib_on = on)
		p.add_child(vc)
		_build_pad_ui()
	else:
		wheel = Wheel.new()
		wheel.custom_minimum_size = Vector2(0, 110)
		p.add_child(wheel)
		drive_info.text = "Manette « USB Speaker Volant »"
		drive_check = CheckButton.new()
		drive_check.text = "Manette virtuelle"
		drive_check.button_pressed = true
		p.add_child(drive_check)


func _build_net_tab() -> void:
	var p := VBoxContainer.new()
	p.name = "Connexion"
	p.add_theme_constant_override("separation", 8)
	tabs.add_child(p)
	link_lbl = Label.new()
	link_lbl.add_theme_font_size_override("font_size", 18)
	p.add_child(link_lbl)
	if is_phone:
		host_box = VBoxContainer.new()
		host_box.add_theme_constant_override("separation", 6)
		p.add_child(host_box)
	else:
		host_check = CheckButton.new()
		host_check.text = "Mode hôte"
		var cf := ConfigFile.new()
		host_check.button_pressed = not (cf.load("user://pref.cfg") == OK and not bool(cf.get_value("pc", "host", true)))
		host_check.toggled.connect(_set_host)
		p.add_child(host_check)
		link_opt = OptionButton.new()
		for t in ["Liaison : Auto", "Liaison : Wi-Fi", "Liaison : câble USB"]:
			link_opt.add_item(t)
		link_opt.item_selected.connect(func(i):
			link_mode = i
			_reconnect())
		p.add_child(link_opt)
		auto_upd = CheckButton.new()
		auto_upd.text = "Mises à jour automatiques"
		var cf2 := ConfigFile.new()
		auto_upd.button_pressed = not (cf2.load("user://pref.cfg") == OK and not bool(cf2.get_value("pc", "auto_update", true)))
		auto_upd.toggled.connect(func(on):
			var c := ConfigFile.new()
			c.load("user://pref.cfg")
			c.set_value("pc", "auto_update", on)
			c.save("user://pref.cfg"))
		p.add_child(auto_upd)
	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.add_child(sp)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	p.add_child(row)
	upd_status = Label.new()
	upd_status.text = "v%s" % APP_VERSION
	upd_status.modulate = Color(1, 1, 1, 0.7)
	upd_status.add_theme_font_size_override("font_size", 14)
	upd_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	upd_status.clip_text = true
	row.add_child(upd_status)
	var ub := Button.new()
	ub.text = "Mises à jour"
	ub.pressed.connect(func(): _check_update(true))
	row.add_child(ub)
	var rb := Button.new()
	rb.text = "↻"
	rb.pressed.connect(_reconnect)
	row.add_child(rb)


func _bcast_addrs() -> PackedStringArray:
	var out: PackedStringArray = ["255.255.255.255"]
	for a in IP.get_local_addresses():
		if a.contains(".") and not a.begins_with("127.") and not a.begins_with("169.254"):
			out.append(a.substr(0, a.rfind(".")) + ".255")
	return out


## PC : active/désactive le mode hôte (le PC s'annonce, le téléphone se connecte).
func _set_host(on: bool) -> void:
	host_on = on
	if on and host_srv == null:
		host_srv = TCPServer.new()
		host_srv.listen(HOST_PORT)
		host_udp.set_broadcast_enabled(true)
	elif not on and host_srv != null:
		host_srv.stop()
		host_srv = null
	var cf := ConfigFile.new()
	cf.load("user://pref.cfg")
	cf.set_value("pc", "host", on)
	cf.save("user://pref.cfg")
	_reconnect()


func _host_tick() -> void:
	if host_srv == null:
		return
	if host_srv.is_connection_available():
		var np := host_srv.take_connection()
		if peer != null:
			_pc_unlink()
		peer = np
		peer.set_no_delay(true)
		rxbuf.clear()
		wait_t = 0.0
		name_sent = false
		cur_host = peer.get_connected_host()
	var now := Time.get_ticks_msec()
	if now - host_t > 1000:
		host_t = now
		var msg := ("USBSPKHOST|%s" % _pc_name()).to_utf8_buffer()
		for d in _bcast_addrs():
			host_udp.set_dest_address(d, BEACON_PORT)
			host_udp.put_packet(msg)


func _reconnect() -> void:
	if peer != null:
		peer.disconnect_from_host()
		if is_phone:
			peer = null
			linked = false
			_set_status("En attente du PC", "Reconnexion…\n" + _my_ips())


func _kind(host: String) -> String:
	if host == "127.0.0.1":
		return "USB (adb)"
	if host.begins_with("192.168.42."):
		return "USB"
	return "Wi-Fi"


func _net_tick(delta: float) -> void:
	net_t -= delta
	if net_t > 0.0:
		return
	net_t = 0.5
	var connected := peer != null and linked
	var now := Time.get_ticks_msec()
	if connected and now - ping_sent > 1000:
		ping_sent = now
		var b := PackedByteArray()
		b.resize(4)
		b.encode_u32(0, now & 0x7fffffff)
		_send(T_PING, b)
	if not connected:
		rtt_ms = -1
		link_lbl.text = "Non connecté"
		return
	var host := peer.get_connected_host() if is_phone else cur_host
	link_lbl.text = "%s · %s" % [_kind(host), ("%d ms" % rtt_ms) if rtt_ms >= 0 else "…"]


func _build_pad_ui() -> void:
	pad_ui = Control.new()
	pad_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad_ui.mouse_filter = Control.MOUSE_FILTER_STOP
	pad_ui.visible = false
	var bg := ColorRect.new()
	bg.color = Color("0f1218")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad_ui.add_child(bg)
	pad_safe = Control.new()
	pad_safe.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad_safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad_ui.add_child(pad_safe)
	add_child(pad_ui)
	shot_frame = Panel.new()
	shot_frame.anchor_left = 0.2
	shot_frame.anchor_right = 0.8
	shot_frame.anchor_top = 0.1
	shot_frame.anchor_bottom = 0.52
	shot_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shot_frame.visible = false
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0, 0, 0, 0.85)
	fsb.border_color = Color("e8edf5")
	fsb.set_border_width_all(3)
	fsb.set_corner_radius_all(10)
	shot_frame.add_theme_stylebox_override("panel", fsb)
	shot_view = TextureRect.new()
	shot_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	shot_view.offset_left = 6
	shot_view.offset_top = 6
	shot_view.offset_right = -6
	shot_view.offset_bottom = -6
	shot_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shot_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	shot_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shot_frame.add_child(shot_view)
	var g := Color(0.23, 0.26, 0.32, 0.75)
	_pz("LT", "LT", g, 0.12, 0.26, 120, 46, 18)
	_pz("LB", "LB", g, 0.12, 0.40, 120, 40, 18)
	_pz("RT", "RT", g, 0.88, 0.26, 120, 46, 18)
	_pz("RB", "RB", g, 0.88, 0.40, 120, 40, 18)
	_pz("Select", "Regarder", g, 0.43, 0.42, 96, 34, 13)
	_pz("Start", "Menu", g, 0.57, 0.42, 64, 34, 13)
	_pz("DUp", "▲", g, 0.385, 0.60, 52, 52, 18)
	_pz("DDown", "▼", g, 0.385, 0.88, 52, 52, 18)
	_pz("DLeft", "◀", g, 0.315, 0.74, 52, 52, 18)
	_pz("DRight", "▶", g, 0.455, 0.74, 52, 52, 18)
	_pz("Y", "Y", Color("d4a017cc"), 0.87, 0.52, 60, 60, 22)
	_pz("A", "A", Color("27ae60cc"), 0.87, 0.86, 60, 60, 22)
	_pz("X", "X", Color("2e86decc"), 0.80, 0.69, 60, 60, 22)
	_pz("B", "B", Color("c0392bcc"), 0.94, 0.69, 60, 60, 22)
	lstick = Stick.new()
	rstick = Stick.new()
	for pair in [[lstick, 0.16], [rstick, 0.62]]:
		var st: Stick = pair[0]
		st.anchor_left = pair[1]
		st.anchor_right = pair[1]
		st.anchor_top = 0.72
		st.anchor_bottom = 0.72
		st.offset_left = -85.0
		st.offset_right = 85.0
		st.offset_top = -85.0
		st.offset_bottom = 85.0
		st.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pad_safe.add_child(st)
	var back := _pbtn("←", 0.05, 54)
	back.pressed.connect(func(): _open_pad(false))
	gyro_btn = _pbtn("Gyro", 0.13, 76)
	gyro_btn.toggle_mode = true
	gyro_btn.toggled.connect(func(on):
		gyro_on = on
		gyro_btn.text = "Gyro ●" if on else "Gyro"
		if on:
			cal_t = 2.0)
	var rc := _pbtn("◎", 0.21, 48)
	rc.pressed.connect(func(): cal_t = 2.0)
	inv_btn = _pbtn("⇄", 0.28, 48)
	inv_btn.toggle_mode = true
	pad_safe.add_child(shot_frame)
	chat_panel = Panel.new()
	chat_panel.anchor_left = 0.2
	chat_panel.anchor_right = 0.8
	chat_panel.anchor_top = 0.17
	chat_panel.anchor_bottom = 0.33
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(0.08, 0.1, 0.15, 0.95)
	csb.border_color = Color("e8edf5")
	csb.set_border_width_all(3)
	csb.set_corner_radius_all(10)
	chat_panel.add_theme_stylebox_override("panel", csb)
	chat_panel.visible = false
	var hb := HBoxContainer.new()
	hb.set_anchors_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 8
	hb.offset_right = -8
	hb.offset_top = 8
	hb.offset_bottom = -8
	hb.add_theme_constant_override("separation", 8)
	chat_line = LineEdit.new()
	chat_line.placeholder_text = "Message du chat…"
	chat_line.max_length = 200
	chat_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_line.text_submitted.connect(func(_t): _chat_submit(chat_line))
	hb.add_child(chat_line)
	var csend := Button.new()
	csend.text = "Envoyer"
	csend.pressed.connect(func(): _chat_submit(chat_line))
	hb.add_child(csend)
	var cx := Button.new()
	cx.text = "✕"
	cx.pressed.connect(func(): _chat_panel(false))
	hb.add_child(cx)
	chat_panel.add_child(hb)
	pad_safe.add_child(chat_panel)
	var cam_btn := _pbtn("", 0.86, 48)
	cam_btn.icon = _cam_tex()
	cam_btn.pressed.connect(func(): _request_shot(false))
	var chat_btn := _pbtn("Chat", 0.95, 70)
	chat_btn.pressed.connect(func(): _chat_panel(not chat_panel.visible))
	pad_hint = Label.new()
	pad_hint.anchor_left = 0.3
	pad_hint.anchor_right = 0.7
	pad_hint.anchor_top = 0.15
	pad_hint.anchor_bottom = 0.15
	pad_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pad_hint.modulate = Color(1, 1, 1, 0.7)
	pad_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad_safe.add_child(pad_hint)


func _open_pad(on: bool) -> void:
	pad_ui.visible = on
	pad_open = on
	get_window().content_scale_size = Vector2i(800, 400) if on else Vector2i(440, 880)
	prev_pr = {}
	call_deferred("_fit")
	touches.clear()
	owned.clear()
	lstick.release()
	rstick.release()
	DisplayServer.screen_set_orientation(
		DisplayServer.SCREEN_SENSOR_LANDSCAPE if on else DisplayServer.SCREEN_PORTRAIT)


func _set_status(t: String, s := "") -> void:
	status.text = t
	var col := Color("b7791f")  # attente
	if "✔" in t:
		col = Color("1f9d55")
	else:
		for k in ["impossible", "perdue", "Échec", "Refusé", "introuvable"]:
			if k in t or k in s:
				col = Color("c0392b")
	sub.text = s if col == Color("c0392b") else ""
	sub.visible = sub.text != ""
	status_panel.add_theme_stylebox_override("panel", _sbox(col, 16, 16, 12))


# ------------------------------------------------------------------ Protocole

func _send(t: int, data: PackedByteArray) -> void:
	if peer == null or peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var h := PackedByteArray([t, data.size() & 255, data.size() >> 8])
	peer.put_data(h + data)


## Lit les trames reçues ; retourne false si la connexion est perdue.
func _read() -> bool:
	peer.poll()
	var st := peer.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTING:
		wait_t += get_process_delta_time()
		return wait_t < 1.5
	if st != StreamPeerTCP.STATUS_CONNECTED:
		return false
	var n := peer.get_available_bytes()
	if n > 0:
		var r := peer.get_data(n)
		if r[0] == OK:
			rxbuf.append_array(r[1])
	while rxbuf.size() >= 3:
		var ln: int = rxbuf[1] | (rxbuf[2] << 8)
		if rxbuf.size() < 3 + ln:
			break
		var t: int = rxbuf[0]
		var pl := rxbuf.slice(3, 3 + ln)
		rxbuf = rxbuf.slice(3 + ln)
		_on_frame(t, pl)
	return true


func _on_frame(t: int, pl: PackedByteArray) -> void:
	if t == T_SHOT and is_phone and pl.size() >= 2:
		if pl[0] & 1:
			shot_buf = PackedByteArray()
		shot_buf.append_array(pl.slice(1))
		if pl[0] & 2:
			var im := Image.new()
			if im.load_jpg_from_buffer(shot_buf) == OK:
				var tx := ImageTexture.create_from_image(im)
				chat_status.text = "Lecture du texte…"
				shot_view.texture = tx
				shot_prev.texture = tx
				_chat_zoom_apply()
				shot_until = Time.get_ticks_msec() + int(shot_sl[4].value) * 1000
		return
	if t == T_CHATLIST and is_phone:
		var d = JSON.parse_string(pl.get_string_from_utf8())
		if typeof(d) == TYPE_DICTIONARY and typeof(d.get("e")) == TYPE_ARRAY:
			var es: Array = d["e"]
			chat_status.text = ""
			if es.is_empty():
				chat_status.text = "Aucun texte lu"
				_set_view(1)
			else:
				_chat_show_list(es)
				_set_view(0)
		return
	if t == T_AIRES and is_phone:
		var d2 = JSON.parse_string(pl.get_string_from_utf8())
		if typeof(d2) == TYPE_DICTIONARY:
			if d2.get("ok", false):
				chat_edit.text = str(d2.get("text", ""))
				chat_status.text = "Prêt à envoyer"
			else:
				chat_status.text = str(d2.get("text", "Erreur IA"))
		return
	if t == T_VOICERES and is_phone:
		var d3 = JSON.parse_string(pl.get_string_from_utf8())
		if typeof(d3) == TYPE_DICTIONARY:
			if d3.get("ok", false):
				chat_edit.text = str(d3.get("text", ""))
				chat_status.text = "Prêt à envoyer"
			else:
				chat_status.text = str(d3.get("text", "Erreur"))
		return
	if t == T_AI and not is_phone:
		_pc_ai(pl)
		return
	if t == T_VOICE and not is_phone and pl.size() >= 2:
		_voice_chunk(pl)
		return
	if t == T_SHOTREQ and not is_phone and pl.size() >= 4:
		_pc_shot(pl)
		return
	if t == T_CHAT and not is_phone and pl.size() >= 2:
		_pc_chat(pl)
		return
	if t == T_CHATRES and is_phone and pl.size() >= 1:
		var msg := "Envoyé ✔" if pl[0] == 1 else "Refusé : à autoriser sur le PC"
		if chat_status != null:
			chat_status.text = msg
		if pad_hint != null:
			pad_hint.text = msg
		return
	if t == T_PING:
		_send(T_PONG, pl)
		return
	if t == T_PONG and pl.size() >= 4:
		rtt_ms = clampi((Time.get_ticks_msec() & 0x7fffffff) - pl.decode_u32(0), 0, 9999)
		return
	if is_phone and t == T_AUDIO:
		_phone_audio(pl)
	elif not is_phone and t == T_MIC:
		if mic_io != null and mic_check.button_pressed:
			mic_io.store_buffer(pl)
		var p := 0
		for i in range(0, pl.size() - 1, 16):
			p = maxi(p, absi(pl.decode_s16(i)))
		peak = maxf(peak, p / 32768.0)
	elif not is_phone and t == T_DRIVE and pl.size() >= 12:
		_apply_drive(pl)
	elif not is_phone and t == T_CTRL and pl.size() >= 2:
		phone_sound = pl[0] == 1
		phone_mic = pl[1] == 1
		_pc_route()
	elif not is_phone and t == T_HELLO and pl.size() >= 4:
		mic_rate = pl.decode_u32(0)
		_pc_link()


func _process(delta: float) -> void:
	upd_timer -= delta
	if upd_timer <= 0.0:
		upd_timer = 1800.0
		_check_update()
	peak = move_toward(peak, 0.0, delta * 1.5)
	bar.value = peak
	if is_phone:
		_drive_tick(delta)
		_phone_process()
	else:
		_pc_process(delta)
		_pad_rx()
		_pad_tick()
	_net_tick(delta)


# ------------------------------------------------------------------ Téléphone

func _phone_init() -> void:
	DisplayServer.screen_set_keep_on(true)
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.25
	player = AudioStreamPlayer.new()
	player.stream = gen
	add_child(player)
	player.play()
	pb = player.get_stream_playback()
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, "Mic")
	cap = AudioEffectCapture.new()
	cap.buffer_length = 0.5
	AudioServer.add_bus_effect(idx, cap)
	AudioServer.set_bus_mute(idx, true)
	mic_player = AudioStreamPlayer.new()
	mic_player.stream = AudioStreamMicrophone.new()
	mic_player.bus = "Mic"
	add_child(mic_player)
	get_tree().on_request_permissions_result.connect(func(_p, ok): if ok: mic_player.play())
	if "android.permission.RECORD_AUDIO" in OS.get_granted_permissions():
		mic_player.play()
	else:
		OS.request_permissions()
	var cf := ConfigFile.new()
	if cf.load("user://pref.cfg") == OK:
		last_pc = str(cf.get_value("pc", "last", ""))
	server = TCPServer.new()
	server.listen(PORT)
	host_rx.bind(BEACON_PORT)
	beacon.set_broadcast_enabled(true)
	beacon.set_dest_address("255.255.255.255", PORT + 1)
	_set_status("En attente du PC", "Lance USB Speaker sur le PC (même réseau Wi-Fi, ou câble USB).\n" + _my_ips())


func _phone_process() -> void:
	_hosts_tick()
	_out_tick()
	while server.is_connection_available():
		var sp := server.take_connection()
		sp.set_no_delay(true)
		pending.append({"peer": sp, "buf": PackedByteArray(), "name": "", "t": Time.get_ticks_msec()})
	_pending_poll()
	var now0 := Time.get_ticks_msec()
	if now0 - beacon_t > 1000:
		beacon_t = now0
		beacon.put_packet("USBSPK".to_utf8_buffer())
	if peer == null:
		return
	if not _read():
		peer = null
		linked = false
		_set_status("En attente du PC", "Connexion perdue.\n" + _my_ips())
		return
	player.volume_db = linear_to_db(maxf(vol_slider.value, 0.0001)) if sound_check.button_pressed else -80.0
	var n := cap.get_frames_available()
	while n >= CHUNK:
		var fr := cap.get_buffer(CHUNK)
		n -= CHUNK
		if dict_on:
			_dict_feed(fr)
		if not mic_check.button_pressed:
			continue
		var b := PackedByteArray()
		b.resize(CHUNK * 2)
		for i in CHUNK:
			var s := (fr[i].x + fr[i].y) * 0.5
			b.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
		_send(T_MIC, b)


## Connexions entrantes pas encore acceptées : on lit le nom du PC, puis l'utilisateur choisit.
func _hosts_tick() -> void:
	var now := Time.get_ticks_msec()
	while host_rx.get_available_packet_count() > 0:
		var t := host_rx.get_packet().get_string_from_utf8().split("|")
		if t.size() >= 2 and t[0] == "USBSPKHOST":
			hosts[host_rx.get_packet_ip()] = {"name": t[1], "t": now}
	for ip in hosts.keys():
		if now - int(hosts[ip]["t"]) > 4000:
			hosts.erase(ip)
	var cur := peer.get_connected_host() if peer != null else ""
	var sig := cur + "|"
	for ip in hosts:
		sig += ip + hosts[ip]["name"] + "|"
	if sig == host_sig:
		return
	host_sig = sig
	for c in host_box.get_children():
		c.queue_free()
	if hosts.is_empty():
		var l := Label.new()
		l.text = "Aucun PC trouvé"
		l.modulate = Color(1, 1, 1, 0.6)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		host_box.add_child(l)
	for ip in hosts:
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, 44)
		b.text = ("✔ " if ip == cur else "") + "%s  (%s)" % [hosts[ip]["name"], ip]
		b.pressed.connect(_connect_host.bind(ip))
		host_box.add_child(b)


func _connect_host(ip: String) -> void:
	out_peer = StreamPeerTCP.new()
	out_peer.connect_to_host(ip, HOST_PORT)
	out_t = Time.get_ticks_msec()
	_set_status("Connexion…", ip)


func _out_tick() -> void:
	if out_peer == null:
		return
	out_peer.poll()
	var st := out_peer.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTED:
		out_peer.set_no_delay(true)
		pending.append({"peer": out_peer, "buf": PackedByteArray(), "name": "", "t": Time.get_ticks_msec(), "auto": true})
		out_peer = null
	elif st != StreamPeerTCP.STATUS_CONNECTING or Time.get_ticks_msec() - out_t > 3000:
		out_peer = null
		_set_status("Connexion impossible", "Mode hôte actif sur le PC ?")


func _pending_poll() -> void:
	var sig := ""
	for p in pending.duplicate():
		var sp: StreamPeerTCP = p["peer"]
		sp.poll()
		if sp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			pending.erase(p)
			continue
		var n := sp.get_available_bytes()
		if n > 0:
			var r := sp.get_data(n)
			if r[0] == OK:
				p["buf"].append_array(r[1])
		var b: PackedByteArray = p["buf"]
		if p["name"] == "" and b.size() >= 3:
			var ln: int = b[1] | (b[2] << 8)
			if b[0] == T_NAME and b.size() >= 3 + ln:
				p["name"] = b.slice(3, 3 + ln).get_string_from_utf8()
				p["buf"] = b.slice(3 + ln)
		if p["name"] == "" and Time.get_ticks_msec() - int(p["t"]) > 2000:
			p["name"] = "PC"
		if p["name"] != "":
			if p.get("auto", false) or (peer == null and p["name"] == last_pc):
				_accept(p)
				continue
			sig += "%s|" % p["name"]
	if sig != pend_sig:
		pend_sig = sig
		for c in pend_box.get_children():
			c.queue_free()
		for p in pending:
			if p["name"] == "":
				continue
			var bt := Button.new()
			bt.custom_minimum_size = Vector2(0, 46)
			bt.text = ("Basculer vers « %s »" if peer != null else "Connecter « %s »") % p["name"]
			bt.pressed.connect(_accept.bind(p))
			pend_box.add_child(bt)


func _accept(p: Dictionary) -> void:
	if not pending.has(p):
		return
	pending.erase(p)
	pend_sig = "x"
	if peer != null:
		peer.disconnect_from_host()
	peer = p["peer"]
	rxbuf = p["buf"]
	last_pc = p["name"]
	seq_tx = 0
	var cf := ConfigFile.new()
	cf.set_value("pc", "last", last_pc)
	cf.save("user://pref.cfg")
	var h := PackedByteArray()
	h.resize(4)
	h.encode_u32(0, int(AudioServer.get_mix_rate()))
	_send(T_HELLO, h)
	_send_ctrl()
	cap.clear_buffer()
	linked = true
	_set_status("Enceinte active ✔", "Connecté à « %s »." % last_pc)


func _send_ctrl() -> void:
	_send(T_CTRL, PackedByteArray([1 if sound_check.button_pressed else 0, 1 if mic_check.button_pressed else 0]))


func _my_ips() -> String:
	var o := PackedStringArray()
	for a in IP.get_local_addresses():
		if a.contains(".") and not a.begins_with("127.") and not a.begins_with("169.254"):
			o.append(a)
	return "Adresse : " + ", ".join(o)


func _phone_audio(pl: PackedByteArray) -> void:
	if not sound_check.button_pressed:
		return
	var frames := pl.size() / 4
	# on garde ≤ 120 ms de retard : le surplus est jeté
	var queued := int(RATE * 0.25) - pb.get_frames_available()
	if queued > int(RATE * 0.12):
		return
	var a := PackedVector2Array()
	a.resize(frames)
	var pk := 0
	for i in frames:
		var l := pl.decode_s16(i * 4)
		var r := pl.decode_s16(i * 4 + 2)
		a[i] = Vector2(l, r) / 32768.0
		pk = maxi(pk, absi(l))
	peak = maxf(peak, pk / 32768.0)
	pb.push_buffer(a)


# ------------------------------------------------------------------ PC

func _pc_init() -> void:
	DisplayServer.window_set_title("USB Speaker")
	_pc_cleanup_leftovers()
	_set_host(host_check.button_pressed)
	_ai_models_load()
	for c in [OS.get_environment("USBSPK_ADB"), OS.get_executable_path().get_base_dir() + "/adb",
			OS.get_environment("HOME") + "/.local/opt/android-sdk/platform-tools/adb"]:
		if c != "" and FileAccess.file_exists(c):
			adb_bin = c
			break
	lan.bind(PORT + 1)
	pad_rx.bind(PORT + 3)
	_set_status("Branche ton téléphone", "Câble USB + débogage USB activé.")
	th_adb = Thread.new()
	th_adb.start(_adb_loop)


func _adb(args: PackedStringArray) -> String:
	var out: Array = []
	OS.execute(adb_bin, args, out, true)
	return "".join(out)


func _apk_path() -> String:
	for p in [OS.get_executable_path().get_base_dir() + "/usb-speaker.apk",
			ProjectSettings.globalize_path("res://build/usb-speaker.apk")]:
		if FileAccess.file_exists(p):
			return p
	return ""


## Thread : détecte le téléphone, installe/lance l'app, ouvre le tunnel USB.
func _adb_loop() -> void:
	var seen := ""
	while not quit:
		var out := _adb(["devices"])
		var serial := ""
		var unauth := false
		for line in out.split("\n"):
			var p := line.strip_edges().split("\t")
			if p.size() == 2:
				if p[1] == "device":
					serial = p[0]
				elif p[1] == "unauthorized":
					unauth = true
		mtx.lock()
		if serial == "":
			adb_state = "none"
			adb_msg = "Autorise ce PC sur le téléphone (fenêtre « Autoriser le débogage USB »)." \
				if unauth else "Câble USB + débogage USB (Options développeur)."
			seen = ""
		mtx.unlock()
		if serial != "":
			if serial != seen:
				seen = serial
				_adb_prepare()
			_adb(["forward", "tcp:%d" % PORT, "tcp:%d" % PORT])
			mtx.lock()
			adb_state = "ready"
			mtx.unlock()
		for i in 20:
			if quit:
				return
			OS.delay_msec(100)


func _adb_prepare() -> void:
	var pk := _adb(["shell", "dumpsys", "package", PKG])
	var have := -1
	var rx := RegEx.create_from_string("versionCode=(\\d+)")
	var mt := rx.search(pk)
	if mt:
		have = mt.get_string(1).to_int()
	var apk := _apk_path()
	if have < VERSION and apk != "":
		mtx.lock()
		adb_msg = "Installation de l'app sur le téléphone…"
		mtx.unlock()
		_adb(["install", "-r", apk])
	_adb(["shell", "monkey", "-p", PKG, "-c", "android.intent.category.LAUNCHER", "1"])


func _pc_process(delta: float) -> void:
	_host_tick()
	if peer != null:
		if not _read():
			_pc_unlink()
			return
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED and not name_sent:
			name_sent = true
			_send(T_NAME, _pc_name().to_utf8_buffer())
		if linked:
			_pc_pump_capture()
		elif name_sent:
			_set_status("Téléphone trouvé", "Accepte la connexion sur le téléphone (« Connecter %s »)." % _pc_name())
		return
	if host_srv != null:
		_set_status("Mode hôte actif", "")
		return
	mtx.lock()
	var st := adb_state
	var msg := adb_msg
	mtx.unlock()
	while lan.get_available_packet_count() > 0:
		if lan.get_packet().get_string_from_utf8() == "USBSPK":
			lan_ip = lan.get_packet_ip()
			lan_t = Time.get_ticks_msec()
	if lan_ip != "" and Time.get_ticks_msec() - lan_t > 4000:
		lan_ip = ""
	var host := ""
	if lan_ip != "" and link_mode != 2:
		host = lan_ip
		_set_status("Téléphone trouvé…", "Connexion à " + lan_ip)
	elif link_mode == 1:
		_set_status("Cherche le téléphone sur le réseau…", "Ouvre USB Speaker sur le téléphone (même Wi-Fi).")
		return
	elif st != "ready":
		_set_status("Branche ton téléphone", msg + "\nOu active le partage de connexion USB sur le téléphone.")
		var c := _candidates()
		host = c[cand_i % c.size()]
		cand_i += 1
	else:
		host = "127.0.0.1"
		_set_status("Téléphone détecté…", "Démarrage de l'app sur le téléphone.")
	try_t -= delta
	if try_t <= 0.0:
		try_t = 0.8
		peer = StreamPeerTCP.new()
		rxbuf.clear()
		wait_t = 0.0
		name_sent = false
		cur_host = host
		peer.connect_to_host(host, PORT)


## Adresses possibles du téléphone en partage de connexion USB (il est la passerelle du lien).
func _candidates() -> PackedStringArray:
	var out := PackedStringArray(["192.168.42.129", "192.168.42.1"])
	var o: Array = []
	OS.execute("ip", ["-4", "route", "show"], o, true)
	for line in "".join(o).split("\n"):
		var p := line.split(" ", false)
		var i := p.find("via")
		if i >= 0 and i + 1 < p.size() and not p[i + 1] in out:
			out.append(p[i + 1])
	return out


func _pc_name() -> String:
	var f := FileAccess.open("/etc/hostname", FileAccess.READ)
	var n := f.get_line().strip_edges() if f != null else ""
	return n if n != "" else "PC"


func _pc_unlink() -> void:
	peer = null
	if linked:
		linked = false
		_pc_teardown()
	_set_status("Branche ton téléphone", "Connexion perdue, nouvelle tentative…")


func _pa(args: PackedStringArray) -> String:
	var out: Array = []
	OS.execute("pactl", args, out, true)
	return "".join(out).strip_edges()


## Le téléphone a répondu : crée l'enceinte + le micro virtuels et lance la capture.
func _pc_link() -> void:
	if linked:
		return
	linked = true
	seq_rx = -1
	phone_sound = true
	phone_mic = false
	prev_src = _pa(["get-default-source"])
	prev_sink = _pa(["get-default-sink"])
	var m1 := _pa(["load-module", "module-null-sink", "sink_name=" + SINK,
			"sink_properties=device.description=Telephone-USB"])
	var m2 := _pa(["load-module", "module-null-sink", "sink_name=" + MIC_SINK,
			"sink_properties=device.description=Micro-Telephone"])
	modules = PackedStringArray([m2, m1])
	_pc_route()
	var io := OS.execute_with_pipe("parec", ["-d", SINK + ".monitor", "--format=s16le",
			"--rate=%d" % RATE, "--channels=2", "--latency-msec=20"], false)
	if io.has("pid"):
		cap_pid = io["pid"]
		cap_io = io["stdio"]
		th_cap = Thread.new()
		th_cap.start(_cap_loop)
	var mi := OS.execute_with_pipe("pacat", ["--playback", "--device=" + MIC_SINK,
			"--format=s16le", "--rate=%d" % mic_rate, "--channels=1", "--latency-msec=30"], false)
	if mi.has("pid"):
		mic_pid = mi["pid"]
		mic_io = mi["stdio"]
	_set_status("Téléphone connecté ✔", "Sortie « Telephone-USB » et micro « Micro-Telephone » prêts.")


## Envoie la sortie son du PC vers l'enceinte virtuelle (ou la rend au PC si décoché).
func _pc_route() -> void:
	if not linked:
		return
	var target := SINK if (out_check.button_pressed and phone_sound) else prev_sink
	# un seul micro : celui du téléphone quand il envoie, sinon on rend le micro d'origine
	var want_src := MIC_SRC if phone_mic else prev_src
	if want_src != "":
		_pa(["set-default-source", want_src])
	if target == "":
		return
	_pa(["set-default-sink", target])
	for line in _pa(["list", "short", "sink-inputs"]).split("\n"):
		var id := line.split("\t")[0]
		if id.is_valid_int():
			_pa(["move-sink-input", id, target])


func _cap_loop() -> void:
	while not quit and cap_pid > 0:
		var b := PackedByteArray()
		while b.size() < CHUNK * 4:
			var part := cap_io.get_buffer(CHUNK * 4 - b.size())
			if part.size() == 0:
				if cap_pid <= 0 or not OS.is_process_running(cap_pid):
					return
				OS.delay_msec(4)
				continue
			b.append_array(part)
		mtx.lock()
		cap_queue.append(b)
		if cap_queue.size() > 8:
			cap_queue.pop_front()
		mtx.unlock()


func _pc_pump_capture() -> void:
	mtx.lock()
	var q := cap_queue
	cap_queue = []
	mtx.unlock()
	for b in q:
		_send(T_AUDIO, b)
		var p := 0
		for i in range(0, b.size() - 1, 32):
			p = maxi(p, absi(b.decode_s16(i)))
		peak = maxf(peak, p / 32768.0)


func _pc_teardown() -> void:
	_pad_stop()
	if prev_src != "":
		_pa(["set-default-source", prev_src])
	if prev_sink != "":
		_pa(["set-default-sink", prev_sink])
		for line in _pa(["list", "short", "sink-inputs"]).split("\n"):
			var id := line.split("\t")[0]
			if id.is_valid_int():
				_pa(["move-sink-input", id, prev_sink])
	if cap_pid > 0:
		OS.kill(cap_pid)
		cap_pid = -1
	if th_cap != null:
		th_cap.wait_to_finish()
		th_cap = null
	cap_io = null
	if mic_pid > 0:
		OS.kill(mic_pid)
		mic_pid = -1
	mic_io = null
	for m in modules:
		if m.is_valid_int():
			_pa(["unload-module", m])
	modules = PackedStringArray()
	cap_queue.clear()


## Au démarrage : retire d'éventuels restes d'un lancement précédent interrompu.
func _pc_cleanup_leftovers() -> void:
	for line in _pa(["list", "short", "modules"]).split("\n"):
		if "usbspk" in line or "soundlink" in line:
			_pa(["unload-module", line.split("\t")[0]])
	if _pa(["get-default-sink"]) == SINK:
		for line in _pa(["list", "short", "sinks"]).split("\n"):
			var nm := line.split("\t")
			if nm.size() > 1 and nm[1] != SINK and not nm[1].begins_with("usbspk"):
				_pa(["set-default-sink", nm[1]])
				break


func _pc_shutdown() -> void:
	if quit:
		return
	quit = true
	if stt_pid > 0:
		OS.kill(stt_pid)
		stt_pid = -1
	if stt_th != null:
		stt_th.wait_to_finish()
		stt_th = null
	if ocr_th != null:
		ocr_th.wait_to_finish()
		ocr_th = null
	if host_srv != null:
		host_srv.stop()
		host_srv = null
	if linked:
		linked = false
		_pc_teardown()
	if th_adb != null:
		th_adb.wait_to_finish()
		th_adb = null


# ------------------------------------------------------------------ Mise à jour (GitHub releases)

func _check_update(manual := false) -> void:
	if http == null:
		http = HTTPRequest.new()
		add_child(http)
		http.request_completed.connect(_on_release)
	if http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	manual_check = manual
	if manual and upd_status != null:
		upd_status.text = "Vérification…"
	http.request("https://api.github.com/repos/%s/releases/latest" % REPO, ["User-Agent: usb-speaker"])


func _newer(a: String, b: String) -> bool:
	var x := a.split(".")
	var y := b.split(".")
	for i in 3:
		var p := x[i].to_int() if i < x.size() else 0
		var q := y[i].to_int() if i < y.size() else 0
		if p != q:
			return p > q
	return false


func _on_release(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	var d = JSON.parse_string(body.get_string_from_utf8()) if result == HTTPRequest.RESULT_SUCCESS and code == 200 else null
	if typeof(d) != TYPE_DICTIONARY:
		if upd_status != null and manual_check:
			upd_status.text = "Vérification impossible"
		return
	new_tag = str(d.get("tag_name", "")).trim_prefix("v")
	if new_tag == "" or not _newer(new_tag, APP_VERSION):
		if upd_status != null:
			upd_status.text = "v%s · à jour" % APP_VERSION
		return
	for a in d.get("assets", []):
		if a["name"] == "usb-speaker.apk":
			url_apk = a["browser_download_url"]
		elif a["name"] == "UsbSpeaker-linux.zip":
			url_zip = a["browser_download_url"]
	if is_phone and url_apk != "":
		upd_btn.text = "Mise à jour v%s : télécharger" % new_tag
		upd_btn.visible = true
		upd_status.text = "v%s → v%s" % [APP_VERSION, new_tag]
	elif not is_phone and url_zip != "" and OS.get_executable_path().ends_with(".x86_64"):
		upd_btn.text = "Mettre à jour vers v%s" % new_tag
		upd_btn.visible = true
		upd_status.text = "v%s → v%s" % [APP_VERSION, new_tag]
		if auto_upd.button_pressed and not linked and not auto_tried:
			auto_tried = true
			upd_status.text = "Installation de v%s…" % new_tag
			_do_update()


func _do_update() -> void:
	if is_phone:
		OS.shell_open(url_apk)  # le navigateur télécharge l'APK, puis « Installer »
		return
	upd_btn.disabled = true
	upd_btn.text = "Téléchargement…"
	dl = HTTPRequest.new()
	dl.download_file = OS.get_user_data_dir() + "/upd.zip"
	dl.request_completed.connect(_on_zip)
	add_child(dl)
	dl.request(url_zip)


func _on_zip(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	var zp := OS.get_user_data_dir() + "/upd.zip"
	var rd := ZIPReader.new()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or rd.open(zp) != OK:
		upd_btn.text = "Échec du téléchargement"
		upd_btn.disabled = false
		return
	var dir := OS.get_executable_path().get_base_dir()
	var exe := OS.get_executable_path()
	var ok := true
	for pair in [["UsbSpeaker/UsbSpeaker.x86_64", exe], ["UsbSpeaker/usb-speaker.apk", dir + "/usb-speaker.apk"]]:
		if not rd.file_exists(pair[0]):
			continue
		var tmp: String = pair[1] + ".new"
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		if f == null:
			ok = false
			break
		f.store_buffer(rd.read_file(pair[0]))
		f.close()
		FileAccess.set_unix_permissions(tmp, 493 if pair[1] == exe else 420)
		ok = ok and DirAccess.rename_absolute(tmp, pair[1]) == OK
	rd.close()
	DirAccess.remove_absolute(zp)
	if not ok:
		upd_btn.text = "Échec (dossier non modifiable ?)"
		upd_btn.disabled = false
		return
	_pc_shutdown()
	OS.create_process(exe, ["--audio-driver", "PulseAudio"])
	get_tree().quit()


# ------------------------------------------------------------------ Manette

func _input(ev: InputEvent) -> void:
	if not is_phone or not pad_open:
		return
	if ev is InputEventScreenTouch:
		if ev.pressed:
			touches[ev.index] = ev.position
			for st in [lstick, rstick]:
				if st.idx == -1 and st.get_global_rect().grow(40.0).has_point(ev.position):
					st.idx = ev.index
					owned[ev.index] = true
					st.set_touch(ev.position)
					break
		else:
			touches.erase(ev.index)
			owned.erase(ev.index)
			for st in [lstick, rstick]:
				if st.idx == ev.index:
					st.release()
	elif ev is InputEventScreenDrag:
		touches[ev.index] = ev.position
		for st in [lstick, rstick]:
			if st.idx == ev.index:
				st.set_touch(ev.position)


## Téléphone : sticks, gâchettes, boutons (+ volant gyroscope optionnel) -> trame T_DRIVE.
func _drive_tick(delta: float) -> void:
	if not pad_open:
		if drive_was:
			drive_was = false
			for i in 3:
				_send_pad(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), true)
		return
	for st in [lstick, rstick]:
		if st.idx != -1 and not touches.has(st.idx):
			st.release()
	drive_was = true
	var pr := {}
	for k in touches:
		if owned.has(k):
			continue
		for z in pad_zones:
			if z.get_global_rect().has_point(touches[k]):
				pr[z.name] = true
	if vib_on:
		for k in pr:
			if not prev_pr.has(k):
				Input.vibrate_handheld(14)
				break
	prev_pr = pr
	for z in pad_zones:
		z.modulate = Color(1.6, 1.6, 1.6) if pr.has(z.name) else Color.WHITE
	var sel := pr.has("Select")
	if sel and not sel_prev:
		_request_shot(false)
	sel_prev = sel
	shot_frame.visible = Time.get_ticks_msec() < shot_until
	var lx := lstick.v.x
	if gyro_on or cal_t > 0.0:
		var g := Input.get_gravity()
		if g.length() < 0.1:
			g = Input.get_accelerometer()
		var ang := rad_to_deg(atan2(g.x, g.y))
		if cal_t > 0.0:
			cal_t -= delta
			pad_hint.text = "Tiens le volant droit… %d" % ceili(maxf(cal_t, 0.0))
			if cal_t <= 0.0:
				ang_off = ang
				pad_hint.text = ""
		elif gyro_on:
			var d := wrapf(ang - ang_off, -180.0, 180.0)
			pad_hint.text = "Volant : %d°" % int(d) if g.length() >= 0.1 else "Capteur d'inclinaison indisponible"
			var tgt := clampf(d / gyro_range, -1.0, 1.0) * (-1.0 if inv_btn.button_pressed else 1.0)
			steer_s = lerpf(steer_s, tgt, clampf(delta * 25.0, 0.0, 1.0))
			lx = clampf(lstick.v.x + steer_s, -1.0, 1.0)  # le joystick reste utilisable
	var mask := 0
	var bits := {"A": 0, "B": 1, "X": 2, "Y": 3, "LB": 4, "RB": 5, "Select": 6, "Start": 7,
			"DUp": 10, "DDown": 11, "DLeft": 12, "DRight": 13}
	for k in bits:
		if pr.has(k):
			mask |= 1 << bits[k]
	var b := PackedByteArray()
	b.resize(12)
	b.encode_s16(0, int(lx * 32767.0))
	b.encode_s16(2, int(lstick.v.y * 32767.0))
	b.encode_s16(4, int(rstick.v.x * 32767.0))
	b.encode_s16(6, int(rstick.v.y * 32767.0))
	b[8] = 255 if pr.has("LT") else 0
	b[9] = 255 if pr.has("RT") else 0
	b.encode_u16(10, mask)
	_send_pad(b)


func _chat_panel(on: bool) -> void:
	chat_panel.visible = on
	# le cadre de capture descend pour laisser la place à la saisie
	shot_frame.anchor_top = 0.36 if on else 0.1
	shot_frame.anchor_bottom = 0.70 if on else 0.52
	if on:
		chat_line.grab_focus()
	else:
		chat_line.release_focus()


func _chat_submit(le: LineEdit) -> void:
	var text := le.text.strip_edges()
	if text == "":
		return
	var b := PackedByteArray([1 if (chat_enter == null or chat_enter.button_pressed) else 0])
	b.append_array(text.to_utf8_buffer())
	_send(T_CHAT, b)
	le.clear()
	if le == chat_line:
		_chat_panel(false)


func _request_shot(_show_prev: bool, keys := true, full := false) -> void:
	shot_req_t = Time.get_ticks_msec()
	var b := PackedByteArray()
	if full:
		b.append_array(PackedByteArray([0, 0, 100, 100, 0]))
	else:
		for i in 4:
			b.append(int(shot_sl[i].value))
		b.append((1 if (keys and chat_enter.button_pressed) else 0) | (2 if tr_in_check.button_pressed else 0))
	chat_status.text = "Capture…"
	_send(T_SHOTREQ, b)


## Manette : UDP (seul le dernier état compte, pas de retard cumulé) ; TCP si tunnel adb.
func _send_pad(b: PackedByteArray, force := false) -> void:
	var now := Time.get_ticks_msec()
	var key := b.hex_encode()
	if not force and key == last_pad_key and now - last_pad_t < 100:
		return
	last_pad_key = key
	last_pad_t = now
	if peer == null or not linked:
		return
	var host := peer.get_connected_host()
	if host == "127.0.0.1" or host == "":
		_send(T_DRIVE, b)
		return
	seq_tx = (seq_tx + 1) & 0x7fffffff
	var p := PackedByteArray()
	p.resize(4)
	p.encode_u32(0, seq_tx)
	p.append_array(b)
	udp_pad.set_dest_address(host, PORT + 3)
	udp_pad.put_packet(p)


const PAD_PY := """import os, struct, fcntl, sys, time
fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
def io(req, arg=0):
    fcntl.ioctl(fd, req, arg)
SET_EV, SET_KEY, SET_ABS = 0x40045564, 0x40045565, 0x40045567
DEV_SETUP, ABS_SETUP, CREATE, DESTROY = 0x405c5503, 0x401c5504, 0x5501, 0x5502
io(SET_EV, 1); io(SET_EV, 3)
BTN = {0: 0x130, 1: 0x131, 2: 0x133, 3: 0x134, 4: 0x136, 5: 0x137, 6: 0x13a, 7: 0x13b}
for c in list(BTN.values()) + [0x13c, 0x13d, 0x13e]:
    io(SET_KEY, c)
AX = [(0, -32768, 32767), (1, -32768, 32767), (3, -32768, 32767), (4, -32768, 32767), (2, 0, 255), (5, 0, 255), (16, -1, 1), (17, -1, 1)]
for c, mn, mx in AX:
    io(SET_ABS, c)
io(DEV_SETUP, struct.pack('<HHHH80sI', 3, 0x045e, 0x028e, 0x0110, b'USB Speaker Volant', 0))
for c, mn, mx in AX:
    io(ABS_SETUP, struct.pack('<H2x6i', c, 0, mn, mx, 0, 0, 0))
io(CREATE)
def ev(t, c, v):
    s = time.time()
    os.write(fd, struct.pack('llHHi', int(s), int((s % 1) * 1e6), t, c, v))
def cl(v, lo, hi):
    return max(lo, min(hi, v))
state = {}
try:
    for line in sys.stdin:
        try:
            lx, ly, rx, ry, lt, rt, k = [int(x) for x in line.split()]
        except Exception:
            continue
        hx = ((k >> 13) & 1) - ((k >> 12) & 1)
        hy = ((k >> 11) & 1) - ((k >> 10) & 1)
        for code, v in ((0, cl(lx, -32767, 32767)), (1, cl(ly, -32767, 32767)), (3, cl(rx, -32767, 32767)),
                        (4, cl(ry, -32767, 32767)), (2, cl(lt, 0, 255)), (5, cl(rt, 0, 255)), (16, hx), (17, hy)):
            if state.get(code) != v:
                state[code] = v
                ev(3, code, v)
        for bit, code in BTN.items():
            on = (k >> bit) & 1
            if state.get(1000 + code) != on:
                state[1000 + code] = on
                ev(1, code, on)
        ev(0, 0, 0)
finally:
    try:
        io(DESTROY)
    except Exception:
        pass
"""


## PC : capture une zone de l'écran principal (fractions en %) et l'envoie en JPEG.
const KB_PY := """import ctypes, ctypes.util, json, sys, time
x11 = ctypes.CDLL(ctypes.util.find_library('X11') or 'libX11.so.6')
xt = ctypes.CDLL(ctypes.util.find_library('Xtst') or 'libXtst.so.6')
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
d = x11.XOpenDisplay(None)
if not d:
    sys.exit('pas de display X11')
x11.XKeysymToKeycode.restype = ctypes.c_ubyte
x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x11.XkbKeycodeToKeysym.restype = ctypes.c_ulong
x11.XkbKeycodeToKeysym.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_uint]
x11.XFlush.argtypes = [ctypes.c_void_p]
xt.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
def kc_of(ks):
    return x11.XKeysymToKeycode(d, ks)
SHIFT = kc_of(0xffe1)
ALTGR = kc_of(0xfe03) or kc_of(0xff7e)
RET = kc_of(0xff0d)
def key(kc, down):
    xt.XTestFakeKeyEvent(d, kc, 1 if down else 0, 0)
def tap(kc, mods):
    for m in mods:
        key(m, True)
    key(kc, True)
    key(kc, False)
    for m in reversed(mods):
        key(m, False)
    x11.XFlush(d)
    time.sleep(0.012)
def type_char(ch):
    cp = ord(ch)
    ks = cp if 0x20 <= cp <= 0xff else 0x1000000 + cp
    kc = kc_of(ks)
    if not kc:
        return
    for level, mods in ((0, []), (1, [SHIFT]), (2, [ALTGR]), (3, [SHIFT, ALTGR])):
        if x11.XkbKeycodeToKeysym(d, kc, 0, level) == ks:
            tap(kc, [m for m in mods if m])
            return
for line in sys.stdin:
    try:
        m = json.loads(line)
    except Exception:
        continue
    for ch in m.get('open', ''):
        type_char(ch)
        time.sleep(0.25)
    for ch in m.get('text', ''):
        type_char(ch)
    if m.get('enter', True):
        time.sleep(0.05)
        tap(RET, [])
"""


func _kb_start() -> bool:
	if kb_pid > 0 and OS.is_process_running(kb_pid):
		return true
	var path := OS.get_user_data_dir() + "/usbspk_kb.py"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(KB_PY)
	f.close()
	var io := OS.execute_with_pipe("python3", ["-I", path], false)
	if not io.has("pid"):
		return false
	kb_pid = io["pid"]
	kb_io = io["stdio"]
	OS.delay_msec(200)
	return OS.is_process_running(kb_pid)


## PC : le téléphone envoie un message de chat -> on tape le texte dans la fenêtre active, puis Entrée.
func _pc_chat(pl: PackedByteArray) -> void:
	if not chat_allow.button_pressed:
		_send(T_CHATRES, PackedByteArray([0]))
		return
	var raw := pl.slice(1).get_string_from_utf8()
	var text := ""
	for ch in raw:
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127:
			text += ch
	text = text.substr(0, 200).strip_edges()
	if text == "" or not _kb_start():
		_send(T_CHATRES, PackedByteArray([0]))
		return
	kb_io.store_line(JSON.stringify({"open": "!" if (pl[0] & 1) != 0 else "", "text": text}))
	kb_io.flush()
	_send(T_CHATRES, PackedByteArray([1]))


func _grab(fx: float, fy: float, fw: float, fh: float) -> Image:
	var scr := DisplayServer.get_primary_screen()
	var img := DisplayServer.screen_get_image(scr)
	var sz := DisplayServer.screen_get_size(scr)
	if img != null and not img.is_empty():
		sz = img.get_size()
	var r := Rect2i(int(fx * sz.x), int(fy * sz.y), maxi(16, int(fw * sz.x)), maxi(16, int(fh * sz.y)))
	r = r.intersection(Rect2i(Vector2i.ZERO, sz))
	if r.size.x < 1 or r.size.y < 1:
		return null
	if img != null and not img.is_empty():
		return img.get_region(r)
	# repli : ffmpeg (X11)
	var path := OS.get_user_data_dir() + "/usbspk_shot.png"
	var disp := OS.get_environment("DISPLAY")
	OS.execute("ffmpeg", ["-v", "quiet", "-y", "-f", "x11grab", "-video_size", "%dx%d" % [r.size.x, r.size.y],
			"-i", "%s+%d,%d" % [disp if disp != "" else ":0.0", r.position.x, r.position.y], "-frames:v", "1", path])
	var im := Image.new()
	return im if im.load(path) == OK else null


func _pc_shot(pl: PackedByteArray) -> void:
	var now := Time.get_ticks_msec()
	if now - shot_last_t < 700:
		return
	shot_last_t = now
	var keys := pl.size() >= 5 and (pl[4] & 1) != 0 and chat_allow.button_pressed and _kb_start()
	if keys:  # ouvre le chat du jeu avec « ! », laisse le temps de s'afficher
		kb_io.store_line(JSON.stringify({"open": "!", "text": "", "enter": false}))
		kb_io.flush()
		await get_tree().create_timer(0.5).timeout
	var im := _grab(pl[0] / 100.0, pl[1] / 100.0, pl[2] / 100.0, pl[3] / 100.0)
	if keys and kb_io != null:  # referme le chat avec Entrée
		kb_io.store_line(JSON.stringify({"open": "", "text": "", "enter": true}))
		kb_io.flush()
	if im == null:
		if shot_info != null:
			shot_info.text = "Capture impossible."
		return
	if im.get_width() > 1400:
		im.resize(1400, int(im.get_height() * 1400.0 / im.get_width()), Image.INTERPOLATE_LANCZOS)
	im.convert(Image.FORMAT_RGB8)
	var jpg := im.save_jpg_to_buffer(0.9)
	shot_prev.texture = ImageTexture.create_from_image(im)
	if shot_info != null:
		shot_info.text = "Dernière capture : %dx%d, %d Ko" % [im.get_width(), im.get_height(), jpg.size() / 1024]
	var pos := 0
	while pos < jpg.size():
		var n := mini(40000, jpg.size() - pos)
		var flags := (1 if pos == 0 else 0) | (2 if pos + n >= jpg.size() else 0)
		var c := PackedByteArray([flags])
		c.append_array(jpg.slice(pos, pos + n))
		_send(T_SHOT, c)
		pos += n
	# lecture du texte (sauf capture de tout l'écran pour choisir la zone)
	if not ocr_busy and not (pl[2] >= 100 and pl[3] >= 100):
		ocr_busy = true
		ocr_th = Thread.new()
		ocr_th.start(_ocr_run.bind(im.duplicate(), pl.size() >= 5 and (pl[4] & 2) != 0))


# ------------------------------------------------------------------ Chat intelligent (PC)

## Thread : OCR Tesseract de la capture, puis découpage en « nom : message ».
func _ocr_run(img: Image, tr: bool) -> void:
	var path := OS.get_user_data_dir() + "/usbspk_ocr.png"
	var w := img.get_width()
	var k := 3 if w < 500 else (2 if w < 1000 else 1)
	if k > 1:
		img.resize(w * k, img.get_height() * k, Image.INTERPOLATE_LANCZOS)
	img.convert(Image.FORMAT_L8)
	img.save_png(path)
	var out: Array = []
	OS.execute("tesseract", [path, "stdout", "-l", "fra+eng", "--psm", "6"], out, false)
	call_deferred("_ocr_done", _parse_chat("".join(out)), tr)


func _parse_chat(text: String) -> Array:
	var rx := RegEx.create_from_string("^\\s*(?:[\\[\\(<][^\\]\\)>]{1,24}[\\]\\)>]\\s*)?([^:\\n]{1,32}?)\\s*[:：]\\s*(.+)$")
	var out: Array = []
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.length() < 2:
			continue
		var m := rx.search(line)
		if m:
			out.append({"n": m.get_string(1).strip_edges(), "m": m.get_string(2).strip_edges()})
		elif out.size() > 0:
			out[out.size() - 1]["m"] = str(out[out.size() - 1]["m"]) + " " + line
		else:
			out.append({"n": "", "m": line})
	return out.slice(maxi(0, out.size() - 20))


func _ocr_done(entries: Array, tr: bool) -> void:
	if ocr_th != null:
		ocr_th.wait_to_finish()
		ocr_th = null
	ocr_busy = false
	_send(T_CHATLIST, JSON.stringify({"e": entries}).to_utf8_buffer())
	if tr and not entries.is_empty():
		_ai_translate_list(entries)


func _send_json(t: int, d: Dictionary) -> void:
	_send(t, JSON.stringify(d).to_utf8_buffer())


## Appel Ollama local (aucune donnée ne quitte le PC). cb(ok: bool, texte: String)
func _ollama(messages: Array, json_mode: bool, num_predict: int, cb: Callable) -> void:
	if ai_model == "":
		cb.call(false, "Aucun modèle Ollama")
		return
	var h := HTTPRequest.new()
	h.timeout = 90.0
	add_child(h)
	h.request_completed.connect(func(res: int, code: int, _hd: PackedStringArray, body: PackedByteArray):
		h.queue_free()
		var d = JSON.parse_string(body.get_string_from_utf8()) if res == HTTPRequest.RESULT_SUCCESS and code == 200 else null
		if typeof(d) != TYPE_DICTIONARY or not d.has("message"):
			cb.call(false, "Ollama indisponible")
			return
		var txt := str(d["message"].get("content", ""))
		txt = RegEx.create_from_string("(?s)<think>.*?</think>").sub(txt, "", true).strip_edges()
		cb.call(true, txt))
	var req := {"model": ai_model, "stream": false, "keep_alive": "5m",
			"options": {"num_predict": num_predict, "temperature": 0.6}, "messages": messages}
	if json_mode:
		req["format"] = "json"
	h.request("http://127.0.0.1:11434/api/chat", ["Content-Type: application/json"],
			HTTPClient.METHOD_POST, JSON.stringify(req))


func _clean_reply(t: String) -> String:
	t = t.replace("\n", " ").strip_edges()
	for q in ["\"", "«", "»", "“", "”"]:
		t = t.trim_prefix(q).trim_suffix(q)
	return t.strip_edges().substr(0, 200)


func _ai_translate_list(entries: Array) -> void:
	var lines := PackedStringArray()
	for i in entries.size():
		lines.append("%d. %s" % [i + 1, entries[i]["m"]])
	var sys := "Tu traduis des messages de chat de jeu vidéo en français. Pour chaque message numéroté, donne la traduction française (si le message est déjà en français, recopie-le tel quel). Réponds uniquement en JSON : {\"t\": [\"...\", ...]} avec exactement %d éléments, dans l'ordre." % entries.size()
	_ollama([{"role": "system", "content": sys}, {"role": "user", "content": "\n".join(lines)}], true, 700,
		func(ok: bool, out: String):
			if not ok:
				return
			var d = JSON.parse_string(out)
			if typeof(d) != TYPE_DICTIONARY or typeof(d.get("t")) != TYPE_ARRAY or d["t"].size() != entries.size():
				return
			for i in entries.size():
				var t := str(d["t"][i]).strip_edges()
				if t != "" and t.to_lower() != str(entries[i]["m"]).to_lower():
					entries[i]["t"] = t
			_send_json(T_CHATLIST, {"e": entries}))


## Le téléphone demande : répondre à un joueur, traduire ou corriger un texte.
func _pc_ai(pl: PackedByteArray) -> void:
	var d = JSON.parse_string(pl.get_string_from_utf8())
	if typeof(d) != TYPE_DICTIONARY:
		return
	var op := str(d.get("op", ""))
	var text := str(d.get("text", "")).strip_edges()
	var sys := ""
	var user := text
	if op == "reply":
		if text == "":
			_send_json(T_AIRES, {"ok": false, "op": op, "text": "Texte vide"})
			return
		# 1) langue du message (appel court), 2) réponse imposée dans cette langue
		_ollama([{"role": "system", "content": "Name the language of the user's message. Answer with ONE English word only (English, French, Spanish, German, Italian, Portuguese, Russian, Polish, Ukrainian, Dutch...)."},
				{"role": "user", "content": text}], false, 6,
			func(ok: bool, lang: String):
				lang = lang.strip_edges().get_slice(" ", 0).trim_suffix(".") if ok and lang != "" else "the same language as the message"
				var tones := ["friendly", "serious and concise", "humorous", "military radio style"]
				var tone: String = tones[clampi(int(d.get("tone", 0)), 0, tones.size() - 1)]
				var sysr := "You are a player of Arma Reforger (military simulation game) answering in the game chat. Write ONE short sentence (120 characters max), tone: %s, no quotation marks, no name prefix, no emoji. You MUST write your answer in %s." % [tone, lang]
				var userr := "Last chat messages:\n%s\n\nReply to %s who wrote: %s" % ["\n".join(PackedStringArray(d.get("ctx", []))), str(d.get("n", "")), text]
				_ollama([{"role": "system", "content": sysr}, {"role": "user", "content": userr}], false, 120,
					func(ok2: bool, out: String):
						_send_json(T_AIRES, {"ok": ok2, "op": op, "text": _clean_reply(out) if ok2 else out})))
		return
	elif op == "translate":
		sys = "Tu traduis des messages de chat de jeu vidéo en %s. Garde le sens, le ton et l'argot de jeu. Réponds uniquement par la traduction, sans guillemets." % str(d.get("lang", "English"))
	elif op == "fix":
		sys = "Corrige l'orthographe, la grammaire et la ponctuation du message sans changer le sens ni la langue. Réponds uniquement par le texte corrigé, sans guillemets."
	else:
		return
	if text == "":
		_send_json(T_AIRES, {"ok": false, "op": op, "text": "Texte vide"})
		return
	_ollama([{"role": "system", "content": sys}, {"role": "user", "content": user}], false, 120,
		func(ok: bool, out: String):
			_send_json(T_AIRES, {"ok": ok, "op": op, "text": _clean_reply(out) if ok else out}))


## Liste des modèles Ollama du PC ; choix mémorisé, sinon un petit modèle (la carte sert au jeu).
func _ai_models_load() -> void:
	var h := HTTPRequest.new()
	h.timeout = 5.0
	add_child(h)
	h.request_completed.connect(func(res: int, code: int, _hd: PackedStringArray, body: PackedByteArray):
		h.queue_free()
		var d = JSON.parse_string(body.get_string_from_utf8()) if res == HTTPRequest.RESULT_SUCCESS and code == 200 else null
		ai_opt.clear()
		if typeof(d) != TYPE_DICTIONARY:
			ai_opt.add_item("IA : Ollama indisponible")
			return
		var names: Array = []
		for m in d.get("models", []):
			names.append(str(m["name"]))
			ai_opt.add_item(str(m["name"]))
		var cf := ConfigFile.new()
		cf.load("user://pref.cfg")
		var want := str(cf.get_value("pc", "ai_model", ""))
		if want == "" or not names.has(want):
			for pref in ["gemma3:4b", "llama3.2:3b", "qwen3:8b", "llama3.1:8b"]:
				if names.has(pref):
					want = pref
					break
		if want == "" and not names.is_empty():
			want = names[0]
		ai_model = want
		if names.has(want):
			ai_opt.select(names.find(want)))
	h.request("http://127.0.0.1:11434/api/tags")


# ------------------------------------------------------------------ Dictée (PC) : Whisper local

const STT_PY := """import sys, json, whisper
m = whisper.load_model('small', device='cpu')
print(json.dumps({'ready': True}), flush=True)
for line in sys.stdin:
    try:
        q = json.loads(line)
        r = m.transcribe(q['wav'], language=q.get('lang') or None, fp16=False,
                         condition_on_previous_text=False, initial_prompt=q.get('prompt'))
        print(json.dumps({'text': r['text'].strip()}), flush=True)
    except Exception as e:
        print(json.dumps({'error': str(e)}), flush=True)
"""


func _stt_start() -> bool:
	if stt_pid > 0 and OS.is_process_running(stt_pid):
		return true
	var path := OS.get_user_data_dir() + "/usbspk_stt.py"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(STT_PY)
	f.close()
	var io := OS.execute_with_pipe("python3", ["-u", path], false)
	if not io.has("pid"):
		return false
	stt_pid = io["pid"]
	stt_io = io["stdio"]
	if stt_th != null:
		stt_th.wait_to_finish()
	stt_th = Thread.new()
	stt_th.start(_stt_loop)
	return true


func _stt_loop() -> void:
	while stt_pid > 0 and not quit:
		var l := stt_io.get_line()
		if l == "":
			if not OS.is_process_running(stt_pid):
				break
			OS.delay_msec(20)
			continue
		call_deferred("_stt_line", l)


func _voice_chunk(pl: PackedByteArray) -> void:
	var off := 1
	if pl[0] & 1:
		voice_buf = PackedByteArray()
		if pl.size() < 3:
			return
		var l1: int = pl[1]
		voice_lang = pl.slice(2, 2 + l1).get_string_from_utf8()
		off = 2 + l1
		if pl.size() <= off:
			return
		var l2: int = pl[off]
		voice_out = pl.slice(off + 1, off + 1 + l2).get_string_from_utf8()
		off += 1 + l2
	voice_buf.append_array(pl.slice(off))
	if pl[0] & 2:
		_voice_done()


func _voice_done() -> void:
	var n := voice_buf.size()
	if n < 6400:
		_send_json(T_VOICERES, {"ok": false, "text": "Trop court"})
		return
	var h := PackedByteArray()
	h.resize(44)
	h.encode_u32(0, 0x46464952)
	h.encode_u32(4, 36 + n)
	h.encode_u32(8, 0x45564157)
	h.encode_u32(12, 0x20746d66)
	h.encode_u32(16, 16)
	h.encode_u16(20, 1)
	h.encode_u16(22, 1)
	h.encode_u32(24, 16000)
	h.encode_u32(28, 32000)
	h.encode_u16(32, 2)
	h.encode_u16(34, 16)
	h.encode_u32(36, 0x61746164)
	h.encode_u32(40, n)
	h.append_array(voice_buf)
	var path := OS.get_user_data_dir() + "/usbspk_voice.wav"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null or not _stt_start():
		_send_json(T_VOICERES, {"ok": false, "text": "Dictée indisponible"})
		return
	f.store_buffer(h)
	f.close()
	stt_io.store_line(JSON.stringify({"wav": path, "lang": voice_lang,
			"prompt": "Chat d'un jeu vidéo de simulation militaire, Arma Reforger."}))
	stt_io.flush()


func _stt_line(l: String) -> void:
	var d = JSON.parse_string(l)
	if typeof(d) != TYPE_DICTIONARY or d.has("ready"):
		return
	if d.has("error"):
		_send_json(T_VOICERES, {"ok": false, "text": "Erreur de transcription"})
		return
	var text := str(d.get("text", "")).strip_edges()
	if text == "":
		_send_json(T_VOICERES, {"ok": false, "text": "Rien entendu"})
	elif voice_out != "":
		var sys := "Tu traduis des messages de chat de jeu vidéo en %s. Garde le sens et le ton. Réponds uniquement par la traduction, sans guillemets." % voice_out
		_ollama([{"role": "system", "content": sys}, {"role": "user", "content": text}], false, 120,
			func(ok: bool, out: String):
				_send_json(T_VOICERES, {"ok": ok, "text": _clean_reply(out) if ok else out, "raw": text}))
	else:
		_send_json(T_VOICERES, {"ok": true, "text": text})


func _apply_drive(pl: PackedByteArray) -> void:
	drive_v = [pl.decode_s16(0), pl.decode_s16(2), pl.decode_s16(4), pl.decode_s16(6), pl[8], pl[9], pl.decode_u16(10)]
	drive_t = Time.get_ticks_msec()
	wheel.steer = drive_v[0] / 32767.0
	if drive_check.button_pressed:
		_pad_start()


func _pad_rx() -> void:
	while pad_rx.get_available_packet_count() > 0:
		var pk := pad_rx.get_packet()
		if not linked or peer == null or pad_rx.get_packet_ip() != peer.get_connected_host() or pk.size() < 16:
			continue
		var sq := pk.decode_u32(0)
		if sq == seq_rx or (seq_rx >= 0 and ((sq - seq_rx) & 0x7fffffff) >= 0x3fffffff):
			continue  # doublon ou paquet périmé
		seq_rx = sq
		_apply_drive(pk.slice(4))


func _pad_start() -> void:
	if pad_pid > 0 and OS.is_process_running(pad_pid):
		return
	var path := OS.get_user_data_dir() + "/usbspk_pad.py"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(PAD_PY)
	f.close()
	var io := OS.execute_with_pipe("python3", ["-I", path], false)
	if not io.has("pid"):
		drive_info.text = "python3 introuvable : manette virtuelle impossible."
		return
	pad_pid = io["pid"]
	pad_io = io["stdio"]
	pad_err = io["stderr"]
	pad_last = ""
	drive_info.text = "Manette virtuelle active"


func _pad_tick() -> void:
	if pad_pid <= 0:
		return
	if not OS.is_process_running(pad_pid):
		var msg := pad_err.get_as_text().strip_edges() if pad_err != null else ""
		drive_info.text = "Manette virtuelle impossible (/dev/uinput)"
		pad_pid = -1
		pad_io = null
		return
	var v: Array = drive_v
	if Time.get_ticks_msec() - drive_t > 500:
		v = [0, 0, 0, 0, 0, 0, 0]
		wheel.steer = 0.0
	var line := "%d %d %d %d %d %d %d" % v
	if line != pad_last:
		pad_last = line
		pad_io.store_line(line)
		pad_io.flush()


func _kb_stop() -> void:
	if kb_pid > 0:
		OS.kill(kb_pid)
	kb_pid = -1
	kb_io = null


func _pad_stop() -> void:
	_kb_stop()
	if pad_pid > 0:
		OS.kill(pad_pid)
	pad_pid = -1
	pad_io = null
