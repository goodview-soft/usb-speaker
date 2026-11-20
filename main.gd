extends Control
## USB Speaker : le téléphone devient enceinte + micro du PC, par le câble USB.
## PC : pilote adb (installe/lance l'app, `adb forward`), capture la sortie son et l'envoie en TCP.
## Téléphone : écoute sur le port 5005, joue le son, renvoie son micro.

const PORT := 5005
const RATE := 48000
const PKG := "fr.goodview.usbspeaker"
const VERSION := 13  # versionCode de l'APK
const APP_VERSION := "1.9.1"
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
const T_PING := 7  # aller-retour (latence) : u32 ms
const T_PONG := 8
const T_NAME := 4  # PC -> téléphone : nom du PC (utf8)
const SINK := "usbspk_out"
const MIC_SINK := "usbspk_mic_sink"
const MIC_SRC := "usbspk_mic_sink.monitor"
const CHUNK := RATE / 50  # 20 ms

var is_phone := OS.has_feature("android")
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
var ip_lbl: Label
var rtt_lbl: Label
var net_hint: Label
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
	_build_ui()
	_check_update()
	if is_phone:
		_phone_init()
	else:
		_pc_init()


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
	bg.color = Color("0f1218")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 28)
	add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 18)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	m.add_child(v)
	status = Label.new()
	status.add_theme_font_size_override("font_size", 30)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(status)
	sub = Label.new()
	sub.modulate = Color(1, 1, 1, 0.6)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(sub)
	upd_btn = Button.new()
	upd_btn.visible = false
	upd_btn.custom_minimum_size = Vector2(0, 52)
	upd_btn.pressed.connect(_do_update)
	v.add_child(upd_btn)
	if is_phone:
		pend_box = VBoxContainer.new()
		pend_box.add_theme_constant_override("separation", 10)
		v.add_child(pend_box)
	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(tabs)
	var p1 := VBoxContainer.new()
	p1.name = "Partage de son"
	p1.add_theme_constant_override("separation", 16)
	tabs.add_child(p1)
	bar = ProgressBar.new()
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 14)
	p1.add_child(bar)
	if is_phone:
		var l := Label.new()
		l.text = "Volume"
		p1.add_child(l)
		vol_slider = HSlider.new()
		vol_slider.min_value = 0.0
		vol_slider.max_value = 1.5
		vol_slider.step = 0.01
		vol_slider.value = 1.0
		vol_slider.custom_minimum_size = Vector2(0, 48)
		p1.add_child(vol_slider)
		sound_check = CheckButton.new()
		sound_check.text = "Jouer le son du PC ici"
		sound_check.button_pressed = true
		sound_check.toggled.connect(func(_on): _send_ctrl())
		p1.add_child(sound_check)
		mic_check = CheckButton.new()
		mic_check.text = "Envoyer mon micro au PC"
		mic_check.button_pressed = false
		mic_check.toggled.connect(func(_on): _send_ctrl())
		p1.add_child(mic_check)
	else:
		out_check = CheckButton.new()
		out_check.text = "Sortie son du PC → téléphone"
		out_check.button_pressed = true
		out_check.toggled.connect(func(_on): _pc_route())
		p1.add_child(out_check)
		mic_check = CheckButton.new()
		mic_check.text = "Micro du téléphone → PC"
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
	pad_ui.add_child(p)
	pad_zones.append(p)
	return p


func _pbtn(txt: String, cx: float, w: float) -> Button:
	var b := Button.new()
	b.text = txt
	b.anchor_left = cx
	b.anchor_right = cx
	b.offset_left = -w / 2.0
	b.offset_right = w / 2.0
	b.offset_top = 8.0
	b.offset_bottom = 56.0
	pad_ui.add_child(b)
	return b


func _build_game_tab() -> void:
	var jeu := TabContainer.new()
	jeu.name = "Jeu"
	tabs.add_child(jeu)
	var arma := TabContainer.new()
	arma.name = "Arma Reforger"
	jeu.add_child(arma)
	_build_drive_tab(arma)
	_build_screen_tab(arma)
	if is_phone:
		arma.tab_changed.connect(func(i): if i == 0: _open_pad(true))


func _build_screen_tab(parent: Node) -> void:
	var p := VBoxContainer.new()
	p.name = "Écran"
	p.add_theme_constant_override("separation", 10)
	parent.add_child(p)
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.modulate = Color(1, 1, 1, 0.7)
	p.add_child(info)
	shot_prev = TextureRect.new()
	shot_prev.custom_minimum_size = Vector2(0, 150)
	shot_prev.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shot_prev.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if is_phone:
		info.text = "Quand tu appuies sur « Regarder » (bouton Sel de la manette), le PC capture cette zone de son écran (par défaut en haut à gauche, le chat) et elle s'affiche dans un cadre."
		for d in [["Position X (%)", 0, 90, 0], ["Position Y (%)", 0, 90, 0], ["Largeur (%)", 10, 100, 45],
				["Hauteur (%)", 5, 100, 30], ["Affichage (secondes)", 2, 20, 6]]:
			var l := Label.new()
			l.text = d[0]
			p.add_child(l)
			var sl := HSlider.new()
			sl.min_value = d[1]
			sl.max_value = d[2]
			sl.value = d[3]
			sl.step = 1
			sl.custom_minimum_size = Vector2(0, 34)
			p.add_child(sl)
			shot_sl.append(sl)
		var tb := Button.new()
		tb.text = "Tester la capture"
		tb.custom_minimum_size = Vector2(0, 52)
		tb.pressed.connect(func(): _request_shot(true))
		p.add_child(tb)
	else:
		info.text = "Le téléphone demande des captures de l'écran de ce PC (zone choisie sur le téléphone)."
		shot_info = Label.new()
		p.add_child(shot_info)
	p.add_child(shot_prev)


func _build_drive_tab(parent: Node) -> void:
	var p := VBoxContainer.new()
	p.name = "Manette"
	p.add_theme_constant_override("separation", 14)
	parent.add_child(p)
	drive_info = Label.new()
	drive_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	drive_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p.add_child(drive_info)
	if is_phone:
		drive_info.text = "Le téléphone devient une manette (2 joysticks, gâchettes, boutons, croix), avec un volant par inclinaison en option."
		var ob := Button.new()
		ob.text = "Ouvrir la manette"
		ob.custom_minimum_size = Vector2(0, 64)
		ob.pressed.connect(func(): _open_pad(true))
		p.add_child(ob)
		_build_pad_ui()
	else:
		wheel = Wheel.new()
		wheel.custom_minimum_size = Vector2(0, 150)
		p.add_child(wheel)
		drive_info.text = "Sur le téléphone, ouvre l'onglet Manette. Dans le jeu, choisis la manette « USB Speaker Volant »."
		drive_check = CheckButton.new()
		drive_check.text = "Manette virtuelle active"
		drive_check.button_pressed = true
		p.add_child(drive_check)


func _build_net_tab() -> void:
	var p := VBoxContainer.new()
	p.name = "Connexion"
	p.add_theme_constant_override("separation", 12)
	tabs.add_child(p)
	link_lbl = Label.new()
	link_lbl.add_theme_font_size_override("font_size", 22)
	link_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p.add_child(link_lbl)
	ip_lbl = Label.new()
	ip_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p.add_child(ip_lbl)
	rtt_lbl = Label.new()
	p.add_child(rtt_lbl)
	net_hint = Label.new()
	net_hint.modulate = Color(1, 1, 1, 0.6)
	net_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p.add_child(net_hint)
	if is_phone:
		var hl := Label.new()
		hl.text = "Ordinateurs disponibles"
		p.add_child(hl)
		host_box = VBoxContainer.new()
		host_box.add_theme_constant_override("separation", 8)
		p.add_child(host_box)
	else:
		host_check = CheckButton.new()
		host_check.text = "Mode hôte : le téléphone choisit ce PC"
		var cf := ConfigFile.new()
		host_check.button_pressed = not (cf.load("user://pref.cfg") == OK and not bool(cf.get_value("pc", "host", true)))
		host_check.toggled.connect(_set_host)
		p.add_child(host_check)
	if not is_phone:
		var l := Label.new()
		l.text = "Mode de liaison"
		p.add_child(l)
		link_opt = OptionButton.new()
		for t in ["Auto", "Réseau Wi-Fi", "Câble USB"]:
			link_opt.add_item(t)
		link_opt.item_selected.connect(func(i):
			link_mode = i
			_reconnect())
		p.add_child(link_opt)
	var vl := Label.new()
	vl.text = "Version %s" % APP_VERSION
	vl.modulate = Color(1, 1, 1, 0.6)
	p.add_child(vl)
	upd_status = Label.new()
	upd_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p.add_child(upd_status)
	var ub := Button.new()
	ub.text = "Vérifier les mises à jour"
	ub.custom_minimum_size = Vector2(0, 52)
	ub.pressed.connect(func(): _check_update(true))
	p.add_child(ub)
	if not is_phone:
		auto_upd = CheckButton.new()
		auto_upd.text = "Mettre à jour automatiquement"
		var cf2 := ConfigFile.new()
		auto_upd.button_pressed = not (cf2.load("user://pref.cfg") == OK and not bool(cf2.get_value("pc", "auto_update", true)))
		auto_upd.toggled.connect(func(on):
			var c := ConfigFile.new()
			c.load("user://pref.cfg")
			c.set_value("pc", "auto_update", on)
			c.save("user://pref.cfg"))
		p.add_child(auto_upd)
	var rb := Button.new()
	rb.text = "Reconnecter"
	rb.custom_minimum_size = Vector2(0, 52)
	rb.pressed.connect(_reconnect)
	p.add_child(rb)


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
		return "Câble USB (adb)"
	if host.begins_with("192.168.42."):
		return "Câble USB (partage de connexion)"
	return "Réseau Wi-Fi / local"


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
		ip_lbl.text = _my_ips() if is_phone else ""
		rtt_lbl.text = ""
		net_hint.text = "Ouvre USB Speaker sur le PC et le téléphone (même Wi-Fi, ou câble USB)."
		return
	var host := peer.get_connected_host() if is_phone else cur_host
	link_lbl.text = "Liaison : " + _kind(host)
	ip_lbl.text = ("PC : " if is_phone else "Téléphone : ") + host
	rtt_lbl.text = "Latence : %d ms" % rtt_ms if rtt_ms >= 0 else "Latence : …"
	if rtt_ms > 60:
		net_hint.text = "Liaison lente : rapproche-toi de la box, passe en Wi-Fi 5 GHz ou utilise le câble USB."
	elif rtt_ms >= 0:
		net_hint.text = "Liaison correcte."
	else:
		net_hint.text = ""


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
	var g := Color("3b4252")
	_pz("LT", "LT", g, 0.12, 0.26, 150, 64)
	_pz("LB", "LB", g, 0.12, 0.40, 150, 54)
	_pz("RT", "RT", g, 0.88, 0.26, 150, 64)
	_pz("RB", "RB", g, 0.88, 0.40, 150, 54)
	_pz("Select", "Regarder", g, 0.43, 0.42, 110, 44, 16)
	_pz("Start", "Menu", g, 0.57, 0.42, 80, 44, 16)
	_pz("DUp", "▲", g, 0.37, 0.60, 62, 62)
	_pz("DDown", "▼", g, 0.37, 0.88, 62, 62)
	_pz("DLeft", "◀", g, 0.30, 0.74, 62, 62)
	_pz("DRight", "▶", g, 0.44, 0.74, 62, 62)
	_pz("Y", "Y", Color("d4a017"), 0.87, 0.52, 74, 74, 28)
	_pz("A", "A", Color("27ae60"), 0.87, 0.86, 74, 74, 28)
	_pz("X", "X", Color("2e86de"), 0.80, 0.69, 74, 74, 28)
	_pz("B", "B", Color("c0392b"), 0.94, 0.69, 74, 74, 28)
	lstick = Stick.new()
	rstick = Stick.new()
	for pair in [[lstick, 0.16], [rstick, 0.62]]:
		var st: Stick = pair[0]
		st.anchor_left = pair[1]
		st.anchor_right = pair[1]
		st.anchor_top = 0.72
		st.anchor_bottom = 0.72
		st.offset_left = -95.0
		st.offset_right = 95.0
		st.offset_top = -95.0
		st.offset_bottom = 95.0
		st.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pad_ui.add_child(st)
	var back := _pbtn("← Retour", 0.10, 130)
	back.pressed.connect(func(): _open_pad(false))
	gyro_btn = _pbtn("Gyroscope : OFF", 0.32, 200)
	gyro_btn.toggle_mode = true
	gyro_btn.toggled.connect(func(on):
		gyro_on = on
		gyro_btn.text = "Gyroscope : " + ("ON" if on else "OFF")
		if on:
			cal_t = 2.0)
	var rc := _pbtn("Recentrer", 0.55, 140)
	rc.pressed.connect(func(): cal_t = 2.0)
	inv_btn = _pbtn("Inverser", 0.72, 120)
	inv_btn.toggle_mode = true
	pad_ui.add_child(shot_frame)
	pad_hint = Label.new()
	pad_hint.anchor_left = 0.3
	pad_hint.anchor_right = 0.7
	pad_hint.anchor_top = 0.15
	pad_hint.anchor_bottom = 0.15
	pad_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pad_hint.modulate = Color(1, 1, 1, 0.7)
	pad_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad_ui.add_child(pad_hint)


func _open_pad(on: bool) -> void:
	pad_ui.visible = on
	pad_open = on
	touches.clear()
	owned.clear()
	lstick.release()
	rstick.release()
	DisplayServer.screen_set_orientation(
		DisplayServer.SCREEN_SENSOR_LANDSCAPE if on else DisplayServer.SCREEN_PORTRAIT)


func _set_status(t: String, s := "") -> void:
	status.text = t
	sub.text = s


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
				shot_view.texture = tx
				shot_prev.texture = tx
				shot_until = Time.get_ticks_msec() + int(shot_sl[4].value) * 1000
		return
	if t == T_SHOTREQ and not is_phone and pl.size() >= 4:
		_pc_shot(pl)
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
		l.text = "Aucun PC trouvé. Sur le PC : Connexion → Mode hôte."
		l.modulate = Color(1, 1, 1, 0.6)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		host_box.add_child(l)
	for ip in hosts:
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, 56)
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
		_set_status("Connexion impossible", "Vérifie que le mode hôte est actif sur le PC.\n" + _my_ips())


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
			bt.custom_minimum_size = Vector2(0, 56)
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
		_set_status("Mode hôte actif", "Sur le téléphone : onglet Connexion → choisis « %s »." % _pc_name())
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
			upd_status.text = "Impossible de vérifier (pas d'internet ?)."
		return
	new_tag = str(d.get("tag_name", "")).trim_prefix("v")
	if new_tag == "" or not _newer(new_tag, APP_VERSION):
		if upd_status != null:
			upd_status.text = "À jour (version %s)." % APP_VERSION
		return
	for a in d.get("assets", []):
		if a["name"] == "usb-speaker.apk":
			url_apk = a["browser_download_url"]
		elif a["name"] == "UsbSpeaker-linux.zip":
			url_zip = a["browser_download_url"]
	if is_phone and url_apk != "":
		upd_btn.text = "Mise à jour %s disponible : télécharger" % new_tag
		upd_btn.visible = true
		upd_status.text = "Mise à jour %s disponible (tu as la %s). Appuie sur le bouton en haut pour la télécharger." % [new_tag, APP_VERSION]
	elif not is_phone and url_zip != "" and OS.get_executable_path().ends_with(".x86_64"):
		upd_btn.text = "Mettre à jour vers %s" % new_tag
		upd_btn.visible = true
		upd_status.text = "Mise à jour %s disponible (tu as la %s)." % [new_tag, APP_VERSION]
		if auto_upd.button_pressed and not linked and not auto_tried:
			auto_tried = true
			upd_status.text = "Mise à jour %s : installation automatique…" % new_tag
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
				if st.idx == -1 and st.get_global_rect().has_point(ev.position):
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
	for z in pad_zones:
		z.modulate = Color(1.6, 1.6, 1.6) if pr.has(z.name) else Color.WHITE
	var sel := pr.has("Select")
	if sel and (not sel_prev or Time.get_ticks_msec() - shot_req_t > 1200):
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


func _request_shot(show_prev: bool) -> void:
	shot_req_t = Time.get_ticks_msec()
	var b := PackedByteArray()
	for sl in shot_sl:
		b.append(int(sl.value))
	b.resize(4)
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
	if now - shot_last_t < 300:
		return
	shot_last_t = now
	var im := _grab(pl[0] / 100.0, pl[1] / 100.0, pl[2] / 100.0, pl[3] / 100.0)
	if im == null:
		if shot_info != null:
			shot_info.text = "Capture impossible."
		return
	if im.get_width() > 800:
		im.resize(800, int(im.get_height() * 800.0 / im.get_width()), Image.INTERPOLATE_BILINEAR)
	im.convert(Image.FORMAT_RGB8)
	var jpg := im.save_jpg_to_buffer(0.7)
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
	drive_info.text = "Manette virtuelle « USB Speaker Volant » active. Dans le jeu, choisis-la comme manette."


func _pad_tick() -> void:
	if pad_pid <= 0:
		return
	if not OS.is_process_running(pad_pid):
		var msg := pad_err.get_as_text().strip_edges() if pad_err != null else ""
		drive_info.text = "Manette virtuelle impossible (accès à /dev/uinput ?)\n" + msg.get_slice("\n", msg.get_slice_count("\n") - 1)
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


func _pad_stop() -> void:
	if pad_pid > 0:
		OS.kill(pad_pid)
	pad_pid = -1
	pad_io = null
