extends Control
## USB Speaker : le téléphone devient enceinte + micro du PC, par le câble USB.
## PC : pilote adb (installe/lance l'app, `adb forward`), capture la sortie son et l'envoie en TCP.
## Téléphone : écoute sur le port 5005, joue le son, renvoie son micro.

const PORT := 5005
const RATE := 48000
const PKG := "fr.goodview.usbspeaker"
const VERSION := 7  # versionCode de l'APK
const APP_VERSION := "1.5.0"
const REPO := "goodview-soft/usb-speaker"
const T_AUDIO := 1  # PC -> téléphone : PCM s16 stéréo 48 kHz
const T_MIC := 2  # téléphone -> PC : PCM s16 mono
const T_HELLO := 3  # téléphone -> PC : u32 fréquence du micro (= connexion acceptée)
const T_CTRL := 5  # téléphone -> PC : [son du PC voulu, micro envoyé]
const T_DRIVE := 6  # téléphone -> PC : s16 volant, u8 gaz, u8 frein, u8 boutons (A B X Y)
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
var gas_z: Panel
var brake_z: Panel
var btn_z: Array = []
var range_slider: HSlider
var invert_check: CheckButton
var calib_btn: Button
var touches := {}
var ang_off := 0.0
var cal_t := 0.0
var steer_s := 0.0
var drive_was := false
var pad_pid := -1
var pad_io: FileAccess
var pad_err: FileAccess
var pad_last := ""
var drive_t := 0
var drive_v := [0, 0, 0, 0]
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


func _exit_tree() -> void:
	if not is_phone:
		_pc_shutdown()


# ------------------------------------------------------------------ UI

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
	_build_drive_tab()


func _zone(id: String, txt: String, col: Color, h: int) -> Panel:
	var p := Panel.new()
	p.name = id
	p.custom_minimum_size = Vector2(0, h)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(16)
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = txt
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 26)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(l)
	return p


func _build_drive_tab() -> void:
	var p := VBoxContainer.new()
	p.name = "Conduite"
	p.add_theme_constant_override("separation", 12)
	tabs.add_child(p)
	wheel = Wheel.new()
	wheel.custom_minimum_size = Vector2(0, 170)
	wheel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(wheel)
	drive_info = Label.new()
	drive_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	drive_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p.add_child(drive_info)
	if is_phone:
		drive_info.text = "Tiens le téléphone comme un volant."
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		brake_z = _zone("brake", "FREIN", Color("c0392b"), 150)
		gas_z = _zone("gas", "GAZ", Color("27ae60"), 150)
		row.add_child(brake_z)
		row.add_child(gas_z)
		p.add_child(row)
		var row2 := HBoxContainer.new()
		row2.add_theme_constant_override("separation", 10)
		for k in ["A", "B", "X", "Y"]:
			var z := _zone(k, k, Color("3b4252"), 64)
			btn_z.append(z)
			row2.add_child(z)
		p.add_child(row2)
		calib_btn = Button.new()
		calib_btn.text = "Recentrer le volant (3 s)"
		calib_btn.custom_minimum_size = Vector2(0, 52)
		calib_btn.pressed.connect(func(): cal_t = 3.0)
		p.add_child(calib_btn)
		var l := Label.new()
		l.text = "Angle pour braquer à fond"
		p.add_child(l)
		range_slider = HSlider.new()
		range_slider.min_value = 20.0
		range_slider.max_value = 90.0
		range_slider.value = 45.0
		range_slider.custom_minimum_size = Vector2(0, 40)
		p.add_child(range_slider)
		invert_check = CheckButton.new()
		invert_check.text = "Inverser le sens"
		p.add_child(invert_check)
	else:
		drive_info.text = "Sur le téléphone, ouvre l'onglet Conduite. Dans le jeu, choisis la manette « USB Speaker Volant »."
		drive_check = CheckButton.new()
		drive_check.text = "Manette virtuelle active"
		drive_check.button_pressed = true
		p.add_child(drive_check)


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
	if is_phone and t == T_AUDIO:
		_phone_audio(pl)
	elif not is_phone and t == T_MIC:
		if mic_io != null and mic_check.button_pressed:
			mic_io.store_buffer(pl)
		var p := 0
		for i in range(0, pl.size() - 1, 16):
			p = maxi(p, absi(pl.decode_s16(i)))
		peak = maxf(peak, p / 32768.0)
	elif not is_phone and t == T_DRIVE and pl.size() >= 5:
		drive_v = [pl.decode_s16(0), pl[2], pl[3], pl[4]]
		drive_t = Time.get_ticks_msec()
		wheel.steer = drive_v[0] / 32767.0
		if drive_check.button_pressed:
			_pad_start()
	elif not is_phone and t == T_CTRL and pl.size() >= 2:
		phone_sound = pl[0] == 1
		phone_mic = pl[1] == 1
		_pc_route()
	elif not is_phone and t == T_HELLO and pl.size() >= 4:
		mic_rate = pl.decode_u32(0)
		_pc_link()


func _process(delta: float) -> void:
	peak = move_toward(peak, 0.0, delta * 1.5)
	bar.value = peak
	if is_phone:
		_drive_tick(delta)
		_phone_process()
	else:
		_pc_process(delta)
		_pad_tick()


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
	beacon.set_broadcast_enabled(true)
	beacon.set_dest_address("255.255.255.255", PORT + 1)
	_set_status("En attente du PC", "Lance USB Speaker sur le PC (même réseau Wi-Fi, ou câble USB).\n" + _my_ips())


func _phone_process() -> void:
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
			if peer == null and p["name"] == last_pc:
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
	for c in [OS.get_environment("USBSPK_ADB"), OS.get_executable_path().get_base_dir() + "/adb",
			OS.get_environment("HOME") + "/.local/opt/android-sdk/platform-tools/adb"]:
		if c != "" and FileAccess.file_exists(c):
			adb_bin = c
			break
	lan.bind(PORT + 1)
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
	var host := "127.0.0.1"
	if lan_ip != "":
		host = lan_ip
		_set_status("Téléphone trouvé…", "Connexion à " + lan_ip)
	elif st != "ready":
		_set_status("Branche ton téléphone", msg + "\nOu active le partage de connexion USB sur le téléphone.")
		var c := _candidates()
		host = c[cand_i % c.size()]
		cand_i += 1
	else:
		_set_status("Téléphone détecté…", "Démarrage de l'app sur le téléphone.")
	try_t -= delta
	if try_t <= 0.0:
		try_t = 0.8
		peer = StreamPeerTCP.new()
		rxbuf.clear()
		wait_t = 0.0
		name_sent = false
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
	if linked:
		linked = false
		_pc_teardown()
	if th_adb != null:
		th_adb.wait_to_finish()
		th_adb = null


# ------------------------------------------------------------------ Mise à jour (GitHub releases)

func _check_update() -> void:
	http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_release)
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
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var d = JSON.parse_string(body.get_string_from_utf8())
	if typeof(d) != TYPE_DICTIONARY:
		return
	new_tag = str(d.get("tag_name", "")).trim_prefix("v")
	if new_tag == "" or not _newer(new_tag, APP_VERSION):
		return
	for a in d.get("assets", []):
		if a["name"] == "usb-speaker.apk":
			url_apk = a["browser_download_url"]
		elif a["name"] == "UsbSpeaker-linux.zip":
			url_zip = a["browser_download_url"]
	if is_phone and url_apk != "":
		upd_btn.text = "Mise à jour %s disponible : télécharger" % new_tag
		upd_btn.visible = true
	elif not is_phone and url_zip != "" and OS.get_executable_path().ends_with(".x86_64"):
		upd_btn.text = "Mettre à jour vers %s" % new_tag
		upd_btn.visible = true


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


# ------------------------------------------------------------------ Conduite

func _input(ev: InputEvent) -> void:
	if not is_phone:
		return
	if ev is InputEventScreenTouch:
		if ev.pressed:
			touches[ev.index] = ev.position
		else:
			touches.erase(ev.index)
	elif ev is InputEventScreenDrag:
		touches[ev.index] = ev.position


## Téléphone : angle du volant (gravité) + boutons tactiles -> trame T_DRIVE.
func _drive_tick(delta: float) -> void:
	if tabs.current_tab != 1:
		if drive_was:
			drive_was = false
			_send(T_DRIVE, PackedByteArray([0, 0, 0, 0, 0]))
		return
	drive_was = true
	var g := Input.get_gravity()
	if g.length() < 0.1:
		g = Input.get_accelerometer()
	var ang := rad_to_deg(atan2(g.x, g.y))
	if cal_t > 0.0:
		cal_t -= delta
		calib_btn.text = "Recentrage dans %d s…" % ceili(maxf(cal_t, 0.0))
		if cal_t <= 0.0:
			ang_off = ang
			calib_btn.text = "Recentrer le volant (3 s)"
	var d := wrapf(ang - ang_off, -180.0, 180.0)
	var tgt := clampf(d / range_slider.value, -1.0, 1.0) * (-1.0 if invert_check.button_pressed else 1.0)
	steer_s = lerpf(steer_s, tgt, clampf(delta * 25.0, 0.0, 1.0))
	wheel.steer = steer_s
	var pr := {}
	for pos in touches.values():
		for z in [gas_z, brake_z] + btn_z:
			if z.get_global_rect().has_point(pos):
				pr[z.name] = true
	for z in [gas_z, brake_z] + btn_z:
		z.modulate = Color(1.5, 1.5, 1.5) if pr.has(z.name) else Color.WHITE
	var mask := 0
	for i in 4:
		if pr.has(["A", "B", "X", "Y"][i]):
			mask |= 1 << i
	var b := PackedByteArray()
	b.resize(5)
	b.encode_s16(0, int(steer_s * 32767.0))
	b[2] = 255 if pr.has("gas") else 0
	b[3] = 255 if pr.has("brake") else 0
	b[4] = mask
	_send(T_DRIVE, b)


const PAD_PY := """import os, struct, fcntl, sys, time
fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
def io(req, arg=0):
    fcntl.ioctl(fd, req, arg)
SET_EV, SET_KEY, SET_ABS = 0x40045564, 0x40045565, 0x40045567
DEV_SETUP, ABS_SETUP, CREATE, DESTROY = 0x405c5503, 0x401c5504, 0x5501, 0x5502
io(SET_EV, 1); io(SET_EV, 3)
BTN = [0x130, 0x131, 0x133, 0x134]
for c in BTN + [0x136, 0x137, 0x13a, 0x13b, 0x13c, 0x13d, 0x13e]:
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
state = {}
try:
    for line in sys.stdin:
        try:
            s, g, b, k = [int(x) for x in line.split()]
        except Exception:
            continue
        for code, v in ((0, max(-32767, min(32767, s))), (5, g), (2, b)):
            if state.get(code) != v:
                state[code] = v
                ev(3, code, v)
        for i, code in enumerate(BTN):
            on = (k >> i) & 1
            if state.get(code) != on:
                state[code] = on
                ev(1, code, on)
        ev(0, 0, 0)
finally:
    try:
        io(DESTROY)
    except Exception:
        pass
"""


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
	if Time.get_ticks_msec() - drive_t > 1000:
		v = [0, 0, 0, 0]
		wheel.steer = 0.0
	var line := "%d %d %d %d" % v
	if line != pad_last:
		pad_last = line
		pad_io.store_line(line)
		pad_io.flush()


func _pad_stop() -> void:
	if pad_pid > 0:
		OS.kill(pad_pid)
	pad_pid = -1
	pad_io = null
