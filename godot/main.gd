extends Node2D
## Genie Buddy: a desktop companion that lives in a lamp on the taskbar and comes out
## when an agent finishes something or needs you. Agents talk to it over HTTP on
## 127.0.0.1:8777 (client: ../client/genie.py, MCP: ../client/genie_mcp.py).
##
## The window covers the work area, is transparent, and lets clicks pass through
## everywhere except over the lamp, the genie and its speech bubble.

const Chime := preload("res://chime.gd")
const GenieArt := preload("res://genie_art.gd")
const LampArt := preload("res://lamp_art.gd")

const PORT := 8777
const AWAY_AFTER := 120.0          # seconds without mouse movement before you count as away
const ESCALATE_TO_CURSOR := 45.0   # an unanswered blocker/question/done flies to your cursor
const TAP_GLASS_AFTER := 180.0     # then a blocker/question starts tapping the glass
const TAP_GLASS_EVERY := 20.0
const INFO_SHOWN_FOR := 20.0
const SNOOZE := 600.0
const TIP := Vector2(58, 120)      # tail tip in genie pixels; it sits on the lamp spout
const KIND_RANK := {"blocker": 0, "question": 0, "done": 1, "info": 2, "progress": 2}
const KIND_COLOR := {"blocker": "b3261e", "question": "6a3fb5", "done": "2e7d32", "info": "1f5fa8",
		"progress": "1f5fa8", "greeting": "8a5a00", "genie": "8a5a00"}
const BUBBLE_BG := Color("fff6dc")
const BUBBLE_EDGE := Color("c8961e")

var px := 3
var sc := 1.0
var screen: Rect2i

var genie_art: Node2D
var genie_tex: TextureRect
var lamp_tex: TextureRect
var fx: Node2D
var overlay: Node2D
var bubble: PanelContainer
var head_lbl: Label
var title_lbl: Label
var body_lbl: Label
var btn_row: HBoxContainer
var player: AudioStreamPlayer
var sounds := {}
var tray: StatusIndicator
var server := TCPServer.new()
var conns := []

var items := []        # pokes: id, kind, title, body, agent, options, status, answer, created, snoozed_until
var next_id := 1
var jobs := {}         # heartbeat watch list: job -> {agent, detail, every, last, quiet}
var current = null     # what the bubble shows: a poke, or a transient dict (greeting, watch list, menu)
var shown_at := 0.0
var last_tap := 0.0
var last_bolt := 0.0
var stage := 0
var out := false
var emerge := 0.0
var genie_pos := Vector2.ZERO
var genie_target := Vector2.ZERO
var lamp_pos := Vector2.ZERO
var facing_left := true
var away := false
var last_mouse := Vector2i.ZERO
var last_move := 0.0
var muted := false
var now := 0.0
var shake := 0.0
var shake_off := Vector2.ZERO
var lamp_shake := 0.0
var smoke := []
var bolts := []
var dragging := false
var drag_from := Vector2.ZERO
var drag_off := Vector2.ZERO
var drag_moved := false
var celebrate_until := 0.0
var last_region := Rect2()
var next_job_check := 0.0


func _ready() -> void:
	var scr := DisplayServer.window_get_current_screen()
	screen = DisplayServer.screen_get_usable_rect(scr)
	px = maxi(2, roundi(DisplayServer.screen_get_dpi(scr) / 96.0 * 2.5))
	sc = DisplayServer.screen_get_dpi(scr) / 96.0
	var win := get_window()
	win.position = screen.position
	win.size = screen.size

	fx = Node2D.new()
	fx.draw.connect(_draw_fx)
	add_child(fx)
	genie_tex = _pixel_layer(GenieArt, GenieArt.W, GenieArt.H)
	genie_art = genie_tex.get_meta("art")
	lamp_tex = _pixel_layer(LampArt, LampArt.W, LampArt.H)
	overlay = Node2D.new()
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)
	_build_bubble()
	_build_tray()
	player = AudioStreamPlayer.new()
	add_child(player)
	sounds = {"sparkle": Chime.sparkle(), "alarm": Chime.alarm(), "soft": Chime.soft()}

	lamp_pos = Vector2(screen.size.x - LampArt.W * px - 260 * sc, screen.size.y - LampArt.H * px)
	genie_pos = _home_genie_pos()
	genie_target = genie_pos
	last_mouse = DisplayServer.mouse_get_position()

	var err := server.listen(PORT, "127.0.0.1")
	if err == OK:
		_show_transient({"kind": "genie", "title": "At your service.",
				"body": "Listening for agents on 127.0.0.1:%d. Rub the lamp to call me." % PORT,
				"options": ["Thanks"], "ttl": 20.0, "pose": "summon", "mood": "happy"})
	else:
		_show_transient({"kind": "blocker", "title": "I cannot hear the agents.",
				"body": "Port %d is taken (error %d). Is another genie running?" % [PORT, err],
				"options": ["Quit"], "pose": "worried", "mood": "worried"})


func _pixel_layer(art_script: Script, w: int, h: int) -> TextureRect:
	var vp := SubViewport.new()
	vp.size = Vector2i(w, h)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	var art: Node2D = art_script.new()
	vp.add_child(art)
	add_child(vp)
	var tex := TextureRect.new()
	tex.texture = vp.get_texture()
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tex.size = Vector2(w, h) * px
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tex.set_meta("art", art)
	add_child(tex)
	return tex


func _build_bubble() -> void:
	bubble = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = BUBBLE_BG
	sb.border_color = BUBBLE_EDGE
	sb.set_border_width_all(roundi(3 * sc))
	sb.set_corner_radius_all(roundi(14 * sc))
	sb.set_content_margin_all(14 * sc)
	sb.shadow_color = Color(0, 0, 0, 0.25)
	sb.shadow_size = roundi(6 * sc)
	bubble.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", roundi(6 * sc))
	bubble.add_child(vb)
	head_lbl = _label(12, true)
	title_lbl = _label(18, true)
	body_lbl = _label(14, false)
	body_lbl.max_lines_visible = 8
	for l in [head_lbl, title_lbl, body_lbl]:
		vb.add_child(l)
	btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", roundi(8 * sc))
	vb.add_child(btn_row)
	bubble.visible = false
	add_child(bubble)


func _label(size: int, bold: bool) -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 320 * sc
	l.add_theme_font_size_override("font_size", roundi(size * sc))
	l.add_theme_color_override("font_color", Color("2a1f3d"))
	if bold:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Segoe UI Semibold", "Segoe UI", "sans-serif"])
		l.add_theme_font_override("font", f)
	return l


func _build_tray() -> void:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var d := Vector2(x - 16, y - 18).length()
			if d < 11:
				img.set_pixel(x, y, Color("3a5fd0"))
			if y >= 5 and y < 13 and absi(x - 16) < 11 - (13 - y):
				img.set_pixel(x, y, Color("c0392b") if y % 3 else Color("e8b531"))
	img.set_pixel(13, 18, Color.WHITE)
	img.set_pixel(19, 18, Color.WHITE)
	tray = StatusIndicator.new()
	tray.icon = ImageTexture.create_from_image(img)
	tray.tooltip = "Genie Buddy — left click: rub the lamp, right click: menu"
	tray.pressed.connect(_on_tray)
	add_child(tray)


func _on_tray(button: int, _pos: Vector2i) -> void:
	if button == MOUSE_BUTTON_RIGHT:
		_show_menu()
	else:
		_rub()


# --- frame loop -------------------------------------------------------------

func _process(delta: float) -> void:
	now += delta
	_poll_http()
	_watch_presence()
	if now >= next_job_check:
		next_job_check = now + 1.0
		_check_jobs()
	_update_flow()
	_animate(delta)
	_update_passthrough()
	fx.queue_redraw()
	overlay.queue_redraw()


func _watch_presence() -> void:
	var m := DisplayServer.mouse_get_position()
	if m != last_mouse:
		last_mouse = m
		last_move = now
		if away:
			away = false
			_on_return()
	elif not away and now - last_move > AWAY_AFTER:
		away = true
		if current != null:
			current = null
			_retreat()


func _on_return() -> void:
	var pending := _pending()
	if pending.is_empty():
		return
	var counts := {}
	for it in pending:
		counts[it.kind] = counts.get(it.kind, 0) + 1
	var parts := []
	for k in ["blocker", "question", "done", "info", "progress"]:
		if counts.has(k):
			parts.append("%d %s" % [counts[k], k if counts[k] == 1 or k == "progress" else k + "s"])
	_show_transient({"kind": "greeting", "title": "Welcome back, master!",
			"body": "While you were away: " + ", ".join(parts) + ".", "options": ["Show me"],
			"pose": "summon", "mood": "happy", "sound": "sparkle"})


func _update_flow() -> void:
	if away or dragging:
		return
	if current == null:
		var nxt = _next_item()
		if nxt != null:
			_show(nxt)
		elif out:
			_retreat()
		return
	var age := now - shown_at
	if current.get("transient", false):
		if current.has("ttl") and age > current.ttl:
			_close_bubble()
		return
	var kind: String = current.kind
	if kind == "info" or kind == "progress":
		if age > INFO_SHOWN_FOR:
			_resolve(current, "seen")
		return
	if stage == 0 and age > ESCALATE_TO_CURSOR:
		stage = 1
		_play("alarm" if kind != "done" else "sparkle")
		genie_art.target_pose = "point"
	if stage >= 1:
		genie_target = _near_cursor()
	if kind != "done" and age > TAP_GLASS_AFTER and now - last_tap > TAP_GLASS_EVERY:
		stage = 2
		last_tap = now
		shake = 0.7
		_play("alarm")
		_bolt()
	if kind == "blocker" and now - last_bolt > 3.5:
		_bolt()


func _animate(delta: float) -> void:
	var home := _home_genie_pos()
	if not out and stage == 0:
		genie_target = home
	genie_pos = genie_pos.lerp(genie_target, 1.0 - exp(-delta * 3.0))
	var near_home := genie_pos.distance_to(home) < 40.0 * sc
	if out:
		emerge = move_toward(emerge, 1.0, delta * 1.6)
	elif near_home:
		emerge = move_toward(emerge, 0.0, delta * 2.0)
	if not out and emerge == 0.0:
		stage = 0

	shake = maxf(0.0, shake - delta)
	shake_off = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake * 16.0 * sc
	genie_art.scale.x = -1.0 if facing_left else 1.0
	genie_art.position.x = GenieArt.W if facing_left else 0.0
	var tip := Vector2(GenieArt.W - TIP.x if facing_left else TIP.x, TIP.y) * px
	genie_tex.pivot_offset = tip
	genie_tex.position = genie_pos + shake_off
	genie_tex.scale = Vector2.ONE * (0.1 + 0.9 * ease(emerge, 0.4))
	genie_tex.modulate.a = clampf(emerge * 1.6, 0.0, 1.0)
	genie_tex.visible = emerge > 0.01
	if genie_art.target_pose == "celebrate" and now > celebrate_until:
		genie_art.target_pose = "point"

	var spout := _spout()
	if emerge > 0.0 and emerge < 1.0:
		var to := genie_tex.position + tip
		for i in 2:
			_puff(spout.lerp(to, randf()), 1, 1.2)
	elif not out and randf() < delta * (1.2 if not jobs.is_empty() else 0.4):
		_puff(spout, 1, 0.5)

	lamp_shake = maxf(0.0, lamp_shake - delta)
	var wobble := 0.0
	if not out and not _pending().is_empty() and fmod(now, 3.0) < 0.6:
		wobble = sin(now * 40.0) * 3.0 * sc
	lamp_tex.position = lamp_pos + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * lamp_shake * 8.0 * sc + Vector2(wobble, 0)

	for s in smoke:
		s.p += s.v * delta
		s.v.y -= 12.0 * delta
		s.r += 6.0 * sc * delta
		s.life -= delta
	smoke = smoke.filter(func(s): return s.life > 0.0)
	for b in bolts:
		b.life -= delta
	bolts = bolts.filter(func(b): return b.life > 0.0)

	bubble.visible = current != null and out and emerge > 0.9
	if bubble.visible:
		_place_bubble()


func _place_bubble() -> void:
	var g := _genie_rect()
	facing_left = g.get_center().x > screen.size.x * 0.5
	var bs := bubble.size
	var bp := Vector2(g.position.x - bs.x - 4 * sc, g.position.y + 10 * sc) if facing_left \
			else Vector2(g.end.x + 4 * sc, g.position.y + 10 * sc)
	bp.x = clampf(bp.x, 4.0, screen.size.x - bs.x - 4.0)
	bp.y = clampf(bp.y, 4.0, screen.size.y - bs.y - 4.0)
	bubble.position = bp + shake_off


func _update_passthrough() -> void:
	var r: Rect2
	if dragging:
		r = Rect2(Vector2.ZERO, screen.size)
	elif emerge > 0.05:
		r = _genie_rect()
		if bubble.visible:
			r = r.merge(Rect2(bubble.position, bubble.size))
		if genie_pos.distance_to(_home_genie_pos()) < 60.0 * sc:
			r = r.merge(_lamp_rect())
	else:
		r = _lamp_rect()
	r = r.grow(4).abs()
	if r.is_equal_approx(last_region):
		return
	last_region = r
	DisplayServer.window_set_mouse_passthrough(PackedVector2Array([r.position,
			Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]))


# --- what the genie says ----------------------------------------------------

func _pending() -> Array:
	return items.filter(func(it): return it.status == "pending")


func _next_item():
	var due := items.filter(func(it): return it.status == "pending" and it.snoozed_until <= now)
	if due.is_empty():
		return null
	due.sort_custom(func(a, b): return KIND_RANK[a.kind] < KIND_RANK[b.kind] \
			or (KIND_RANK[a.kind] == KIND_RANK[b.kind] and a.created < b.created))
	return due[0]


func _show(it: Dictionary) -> void:
	current = it
	shown_at = now
	stage = 0
	last_tap = now
	var opts: Array = it.options.duplicate()
	if opts.is_empty():
		opts = ["Got it"]
	if it.kind != "info" and it.kind != "progress":
		opts.append("Later")
	var waiting := _pending().size() - 1
	var head := "%s  ·  %s" % [it.kind.to_upper(), it.agent]
	if waiting > 0:
		head += "   (+%d more)" % waiting
	_fill_bubble(it.kind, head, it.title, it.body, opts)
	match it.kind:
		"blocker":
			_pose("worried", "worried")
			_play("alarm")
			_bolt()
		"question":
			_pose("point", "curious")
			_play("sparkle")
		"done":
			_pose("celebrate", "happy")
			celebrate_until = now + 2.5
			_play("sparkle")
		_:
			_pose("point", "neutral")
			_play("soft")
	if not out:
		_emerge()


func _show_transient(d: Dictionary) -> void:
	d["transient"] = true
	current = d
	shown_at = now
	stage = 0
	_fill_bubble(d.kind, "GENIE" if d.kind == "genie" else d.kind.to_upper(), d.title, d.get("body", ""), d.options)
	_pose(d.get("pose", "summon"), d.get("mood", "neutral"))
	if d.has("sound"):
		_play(d.sound)
	if not out:
		_emerge()


func _show_watch_list() -> void:
	var lines := []
	for job in jobs:
		var j: Dictionary = jobs[job]
		lines.append("• %s — %s · %s ago%s" % [job, j.agent, _ago(now - j.last),
				("\n   " + j.detail) if j.detail != "" else ""])
	if lines.is_empty():
		_show_transient({"kind": "genie", "title": "All quiet, master.", "body": "No jobs are reporting to me.",
				"options": ["Thanks"], "ttl": 20.0, "mood": "happy"})
	else:
		_show_transient({"kind": "genie", "title": "Watching %d job%s" % [lines.size(), "" if lines.size() == 1 else "s"],
				"body": "\n".join(lines), "options": ["Thanks"], "ttl": 30.0})


func _show_menu() -> void:
	_show_transient({"kind": "genie", "title": "Your wish?", "body": "",
			"options": ["Test poke", "Unmute" if muted else "Mute", "Dismiss all", "Quit"],
			"ttl": 20.0, "mood": "curious"})


func _fill_bubble(kind: String, head: String, title: String, body: String, options: Array) -> void:
	head_lbl.text = head
	head_lbl.add_theme_color_override("font_color", Color(KIND_COLOR.get(kind, "8a5a00")))
	title_lbl.text = title
	body_lbl.text = body
	body_lbl.visible = body != ""
	for c in btn_row.get_children():
		c.queue_free()
	for i in options.size():
		var choice: String = options[i]
		var b := Button.new()
		b.text = choice
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", roundi(13 * sc))
		b.add_theme_color_override("font_color", Color("2a1f3d"))
		b.add_theme_color_override("font_hover_color", Color("2a1f3d"))
		b.add_theme_color_override("font_pressed_color", Color("2a1f3d"))
		var base := Color("f2c94c") if i == 0 else Color("efe3c2")
		b.add_theme_stylebox_override("normal", _btn_style(base))
		b.add_theme_stylebox_override("hover", _btn_style(base.lightened(0.25)))
		b.add_theme_stylebox_override("pressed", _btn_style(base.darkened(0.15)))
		b.pressed.connect(_on_choice.bind(choice))
		btn_row.add_child(b)
	bubble.reset_size()


func _btn_style(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = BUBBLE_EDGE
	s.set_border_width_all(roundi(1 * sc) + 1)
	s.set_corner_radius_all(roundi(8 * sc))
	s.content_margin_left = 12 * sc
	s.content_margin_right = 12 * sc
	s.content_margin_top = 5 * sc
	s.content_margin_bottom = 5 * sc
	return s


func _on_choice(choice: String) -> void:
	var c = current
	if c == null:
		return
	if c.get("transient", false):
		_close_bubble()
		match choice:
			"Test poke":
				_add_item({"kind": "question", "agent": "Genie (test)", "title": "Integration tests failed on the nightly build. Retry them?",
						"body": "Every other job passed. The failure looks like a flaky timeout.",
						"options": ["Retry", "Leave it"]})
			"Mute":
				muted = true
			"Unmute":
				muted = false
			"Dismiss all":
				for it in _pending():
					it.status = "seen"
			"Quit":
				get_tree().quit()
		return
	if choice == "Later":
		c.snoozed_until = now + SNOOZE
		_close_bubble()
		return
	_resolve(c, choice)


func _resolve(it: Dictionary, answer: String) -> void:
	it.status = "seen" if answer == "seen" or answer == "Got it" else "answered"
	it.answer = null if it.status == "seen" else answer
	_close_bubble()
	_pose("summon", "happy")
	_puff(genie_tex.position + genie_tex.pivot_offset, 6, 1.0)


func _close_bubble() -> void:
	current = null
	bubble.visible = false


func _emerge() -> void:
	out = true
	lamp_shake = 0.4
	_puff(_spout(), 16, 1.2)


func _retreat() -> void:
	out = false
	stage = 0
	bubble.visible = false


func _rub() -> void:
	lamp_shake = 0.5
	_puff(_spout(), 10, 1.0)
	if current != null:
		if not out:
			_emerge()
		return
	if _next_item() == null:
		var snoozed := _pending()
		if not snoozed.is_empty():
			snoozed[0].snoozed_until = 0.0
		else:
			_show_watch_list()


func _pose(pose: String, mood: String) -> void:
	genie_art.target_pose = pose
	genie_art.mood = mood


func _play(key: String) -> void:
	if muted:
		return
	player.stream = sounds[key]
	player.play()


func _add_item(b: Dictionary) -> Dictionary:
	var kind := str(b.get("kind", "info"))
	if not KIND_RANK.has(kind):
		kind = "info"
	var opts = b.get("options", [])
	if typeof(opts) != TYPE_ARRAY:
		opts = []
	var it := {"id": next_id, "kind": kind, "title": str(b.get("title", "")).strip_edges().left(200),
			"body": str(b.get("body", "")).strip_edges().left(700), "agent": str(b.get("agent", "an agent")),
			"options": opts.map(func(o): return str(o)), "status": "pending", "answer": null,
			"created": now, "snoozed_until": 0.0}
	next_id += 1
	items.append(it)
	# Something more urgent pre-empts what is on the bubble; the old one stays pending.
	if current != null and not away and (current.get("transient", false) and current.kind != "greeting" \
			or not current.get("transient", false) and KIND_RANK[kind] < KIND_RANK[current.kind]):
		_close_bubble()
	if away:
		lamp_shake = 0.6
	return it


func _check_jobs() -> void:
	for job in jobs:
		var j: Dictionary = jobs[job]
		if not j.quiet and now - j.last > j.every * 2.0 + 30.0:
			j.quiet = true
			_add_item({"kind": "blocker", "agent": j.agent, "title": "%s has gone quiet" % job,
					"body": "No heartbeat for %s; it promised one every %s.%s" % [_ago(now - j.last), _ago(j.every),
					("\nLast word: " + j.detail) if j.detail != "" else ""]})


func _ago(sec: float) -> String:
	var s := int(sec)
	if s < 60:
		return "%ds" % s
	if s < 3600:
		return "%dm" % (s / 60)
	return "%dh %dm" % [s / 3600, (s % 3600) / 60]


# --- geometry -----------------------------------------------------------------

func _spout() -> Vector2:
	return lamp_pos + LampArt.SPOUT * px


func _lamp_rect() -> Rect2:
	return Rect2(lamp_pos, Vector2(LampArt.W, LampArt.H) * px)


func _genie_rect() -> Rect2:
	return Rect2(genie_tex.position + Vector2(14, 4) * px, Vector2(68, 122) * px)


func _clamp_genie(p: Vector2) -> Vector2:
	var size := Vector2(GenieArt.W, GenieArt.H) * px
	return Vector2(clampf(p.x, -size.x * 0.15, screen.size.x - size.x * 0.85), clampf(p.y, -size.y * 0.02, screen.size.y - size.y))


func _home_genie_pos() -> Vector2:
	var tip := Vector2(GenieArt.W - TIP.x if facing_left else TIP.x, TIP.y) * px
	return _clamp_genie(_spout() - tip + Vector2(0, 2 * px))


func _near_cursor() -> Vector2:
	var m := Vector2(DisplayServer.mouse_get_position() - screen.position)
	var size := Vector2(GenieArt.W, GenieArt.H) * px
	var side := -1.0 if m.x > screen.size.x * 0.5 else 1.0
	return _clamp_genie(Vector2(m.x + side * size.x * 0.55 - size.x * 0.5, m.y - size.y * 0.3))


# --- effects ------------------------------------------------------------------

func _puff(at: Vector2, n: int, size: float) -> void:
	for i in n:
		smoke.append({"p": at + Vector2(randf_range(-4, 4), randf_range(-4, 4)) * sc,
				"v": Vector2(randf_range(-25, 25), randf_range(-70, -20)) * sc,
				"r": randf_range(3.0, 7.0) * sc * size, "life": 1.3, "max": 1.3})


func _bolt() -> void:
	last_bolt = now
	var g := _genie_rect()
	for k in 2:
		var p := Vector2(randf_range(g.position.x - 40 * sc, g.end.x + 40 * sc), g.position.y + randf_range(0, 30) * sc)
		var pts := PackedVector2Array([p])
		for i in 7:
			p += Vector2(randf_range(-22, 22), randf_range(18, 38)) * sc
			pts.append(p)
		bolts.append({"pts": pts, "life": 0.25})


func _draw_fx() -> void:
	if not out and not _pending().is_empty():
		var c := _lamp_rect().get_center()
		var pulse := 1.0 + 0.12 * sin(now * 4.0)
		for k in 3:
			fx.draw_circle(c, (34.0 + k * 16.0) * sc * pulse, Color(1.0, 0.82, 0.3, 0.08))
	for s in smoke:
		var a: float = s.life / s.max
		fx.draw_circle(s.p, s.r, Color(0.55, 0.6, 1.0, 0.32 * a))
		fx.draw_circle(s.p, s.r * 0.55, Color(0.8, 0.82, 1.0, 0.25 * a))


func _draw_overlay() -> void:
	for b in bolts:
		var a: float = b.life / 0.25
		overlay.draw_polyline(b.pts, Color(0.75, 0.65, 1.0, 0.35 * a), 7.0 * sc)
		overlay.draw_polyline(b.pts, Color(1, 1, 1, a), 2.0 * sc)
	var pending := _pending().size()
	if not out and emerge == 0.0 and pending > 0:
		var c := lamp_pos + Vector2(LampArt.W * px - 6 * sc, 4 * sc)
		overlay.draw_circle(c, 11 * sc, Color("b3261e"))
		var font := ThemeDB.fallback_font
		var fs := roundi(14 * sc)
		overlay.draw_string(font, c + Vector2(-11 * sc, fs * 0.35), str(pending), HORIZONTAL_ALIGNMENT_CENTER, 22 * sc, fs, Color.WHITE)
	if bubble.visible:
		# Speech tail from the bubble edge to the genie's head.
		var head := genie_tex.position + Vector2(GenieArt.W - 50 if facing_left else 50, 36) * px
		var edge_x := bubble.position.x + bubble.size.x if facing_left else bubble.position.x
		var y := clampf(head.y, bubble.position.y + 20 * sc, bubble.position.y + bubble.size.y - 20 * sc)
		var tip := head.lerp(Vector2(edge_x, y), 0.45)
		var tri := PackedVector2Array([Vector2(edge_x, y - 12 * sc), Vector2(edge_x, y + 12 * sc), tip])
		overlay.draw_colored_polygon(tri, BUBBLE_BG)
		overlay.draw_polyline(PackedVector2Array([tri[0], tip, tri[1]]), BUBBLE_EDGE, 3 * sc)


# --- input ----------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var p: Vector2 = event.position
		var on_lamp := _lamp_rect().has_point(p)
		var on_genie := emerge > 0.5 and _genie_rect().has_point(p)
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and (on_lamp or on_genie):
			_show_menu()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and on_lamp:
				dragging = true
				drag_moved = false
				drag_from = p
				drag_off = lamp_pos - p
			elif event.pressed and on_genie:
				_rub()
			elif not event.pressed and dragging:
				dragging = false
				if not drag_moved:
					_rub()
	elif event is InputEventMouseMotion and dragging:
		if event.position.distance_to(drag_from) > 5.0 * sc:
			drag_moved = true
		if drag_moved:
			var size := Vector2(LampArt.W, LampArt.H) * px
			lamp_pos = (event.position + drag_off).clamp(Vector2.ZERO, Vector2(screen.size) - size)


# --- HTTP inbox -------------------------------------------------------------------

func _poll_http() -> void:
	while server.is_listening() and server.is_connection_available():
		conns.append({"peer": server.take_connection(), "buf": PackedByteArray(), "t": now})
	for c in conns.duplicate():
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or now - c.t > 5.0:
			conns.erase(c)
			continue
		var n := peer.get_available_bytes()
		if n > 0:
			var got: Array = peer.get_partial_data(n)
			if got[0] == OK:
				var buf: PackedByteArray = c.buf
				buf.append_array(got[1])
				c.buf = buf
		var req = _parse_request(c.buf)
		if req == null:
			continue
		var res: Array = _route(req)
		_respond(peer, res[0], res[1])
		conns.erase(c)


func _parse_request(buf: PackedByteArray):
	var sep := -1
	for i in range(buf.size() - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			sep = i
			break
	if sep < 0:
		return null
	var lines := buf.slice(0, sep).get_string_from_utf8().split("\r\n")
	var first := lines[0].split(" ")
	var length := 0
	for i in range(1, lines.size()):
		var kv := lines[i].split(":", true, 1)
		if kv.size() == 2 and kv[0].strip_edges().to_lower() == "content-length":
			length = kv[1].strip_edges().to_int()
	var body_bytes := buf.slice(sep + 4)
	if body_bytes.size() < length:
		return null
	var body = JSON.parse_string(body_bytes.slice(0, length).get_string_from_utf8()) if length > 0 else null
	return {"method": first[0], "path": first[1] if first.size() > 1 else "", "body": body}


func _route(req: Dictionary) -> Array:
	var path: String = req.path.split("?")[0]
	var b = req.body
	if req.method == "GET" and path == "/status":
		var watching := {}
		for job in jobs:
			watching[job] = {"agent": jobs[job].agent, "detail": jobs[job].detail, "seconds_since": int(now - jobs[job].last)}
		return [200, {"pending": _pending().size(), "away": away, "watching": watching}]
	if req.method == "POST" and path == "/poke":
		if typeof(b) != TYPE_DICTIONARY or str(b.get("title", "")).strip_edges() == "":
			return [400, {"error": "title is required"}]
		return [200, {"id": _add_item(b).id}]
	if req.method == "POST" and path == "/heartbeat":
		if typeof(b) != TYPE_DICTIONARY or str(b.get("job", "")).strip_edges() == "":
			return [400, {"error": "job is required"}]
		var job := str(b.job).strip_edges()
		if str(b.get("state", "running")) != "running":
			jobs.erase(job)
		else:
			jobs[job] = {"agent": str(b.get("agent", "an agent")), "detail": str(b.get("detail", "")).left(200),
					"every": maxf(10.0, float(b.get("every_s", 300))), "last": now, "quiet": false}
		return [200, {"ok": true, "watching": jobs.size()}]
	if req.method == "GET" and path.begins_with("/answer/"):
		var id := path.get_slice("/", 2).to_int()
		for it in items:
			if it.id == id:
				return [200, {"id": id, "status": it.status, "answer": it.answer}]
		return [404, {"error": "no such poke"}]
	return [404, {"error": "not found"}]


func _respond(peer: StreamPeerTCP, code: int, data: Dictionary) -> void:
	var body := JSON.stringify(data).to_utf8_buffer()
	var reason: String = {200: "OK", 400: "Bad Request", 404: "Not Found"}.get(code, "OK")
	var head := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [code, reason, body.size()]
	peer.put_data(head.to_utf8_buffer())
	peer.put_data(body)
	peer.disconnect_from_host()
